import Foundation

public enum LidAwakeActivationResult: Equatable, Sendable {
    case active(LidAwakeSessionRecord)
    case notApplied
    case stateUnknown
    case journalFailure
    case activeJournalFailure
}

public enum LidAwakeRestoreResult: Equatable, Sendable {
    case restored
    case pending
}

public enum LidAwakePolicyTransitions {
    /// Persists ownership before changing system policy and acknowledges only verified, journaled activation.
    public static func activate(
        record: LidAwakeSessionRecord,
        persist: (LidAwakeSessionRecord) -> Bool,
        applySleepPolicy: (Bool) throws -> Void,
        verifySleepPolicy: () -> Bool?,
        removeJournal: () -> Void
    ) -> LidAwakeActivationResult {
        guard persist(record) else { return .journalFailure }
        try? applySleepPolicy(true)
        guard let applied = verifySleepPolicy() else { return .stateUnknown }
        guard applied else {
            removeJournal()
            return .notApplied
        }
        var active = record
        active.phase = .active
        guard persist(active) else { return .activeJournalFailure }
        return .active(active)
    }

    /// Attempts the fixed restore even when persisting the restoring phase fails; uncertain policy keeps the journal.
    public static func restore(
        record: LidAwakeSessionRecord,
        sleepNowIfLidClosed: Bool,
        persist: (LidAwakeSessionRecord) -> Bool,
        readSleepPolicy: () -> Bool?,
        applySleepPolicy: (Bool) throws -> Void,
        verifySleepPolicy: () -> Bool?,
        lidIsClosed: () -> Bool?,
        requestSleepNow: () throws -> Void,
        removeJournal: () -> Bool
    ) -> LidAwakeRestoreResult {
        var restoring = record
        restoring.phase = .restoring
        restoring.sleepNowOnRestore = record.phase == .restoring
            ? (record.sleepNowOnRestore || sleepNowIfLidClosed)
            : sleepNowIfLidClosed
        let intentPersisted = persist(restoring)

        guard let current = readSleepPolicy() else { return .pending }
        if current { try? applySleepPolicy(false) }
        guard verifySleepPolicy() == false else { return .pending }

        let shouldRequestSleep = restoring.sleepNowOnRestore && !restoring.sleepNowIssued
        if shouldRequestSleep, lidIsClosed() == true {
            do { try requestSleepNow() }
            catch { return .pending }
            restoring.sleepNowIssued = true
            guard persist(restoring) else { return .pending }
        }
        // If the intent write failed but the system policy is confirmed restored, removal is still safe.
        // A requested closed-lid sleep must also have succeeded before removing the last recovery record.
        _ = intentPersisted
        guard removeJournal() else { return .pending }
        return .restored
    }

    public static func ownsSession(_ record: LidAwakeSessionRecord, connectionIdentifier: String) -> Bool {
        record.ownerConnectionIdentifier == connectionIdentifier
    }
}
