import Dispatch
import Foundation
import MacCoffeeCore

struct LidAwakeStatusSnapshot {
    let isActive: Bool
    let deadlineEpoch: TimeInterval?
    let detail: String?
}

final class LidAwakeSessionCoordinator {
    private let journal = LidAwakeJournalStore()
    private let queue = DispatchQueue(label: "com.moey823.MacCoffee.LidAwake.state")
    private var startupRecoveryPending = true
    private var maintenanceTimer: DispatchSourceTimer?

    func recoverBeforeAuthorization() {
        queue.sync { maintainLocked() }
    }

    func startPeriodicMaintenance() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(150))
        timer.setEventHandler { [weak self] in self?.maintain() }
        maintenanceTimer = timer
        timer.resume()
    }

    func maintain() {
        queue.sync { maintainLocked() }
    }

    func status() -> LidAwakeStatusSnapshot {
        queue.sync {
            _ = maintainLocked()
            do {
                guard let record = try journal.read() else {
                    return LidAwakeStatusSnapshot(isActive: false, deadlineEpoch: nil, detail: "No lid-awake session is active.")
                }
                guard record.phase == .active else {
                    return LidAwakeStatusSnapshot(isActive: false, deadlineEpoch: nil, detail: "The lid-awake session is restoring system sleep.")
                }
                guard let sleepDisabled = LidAwakePlatform.sleepDisabled() else {
                    return LidAwakeStatusSnapshot(isActive: false, deadlineEpoch: record.deadlineEpoch, detail: "Could not verify the system sleep policy.")
                }
                guard sleepDisabled else {
                    return LidAwakeStatusSnapshot(isActive: false, deadlineEpoch: nil, detail: "System sleep is enabled.")
                }
                return LidAwakeStatusSnapshot(
                    isActive: true,
                    deadlineEpoch: record.deadlineEpoch,
                    detail: record.isWaitingForLidClose ? Self.timerWaitingDetail : "Lid-awake session active."
                )
            } catch {
                return LidAwakeStatusSnapshot(isActive: false, deadlineEpoch: nil, detail: error.localizedDescription)
            }
        }
    }

    func startSession(
        durationSeconds: TimeInterval?,
        startOnLidClose: Bool,
        stopOnBattery: Bool,
        ownerConnectionIdentifier: String,
        auditSessionIdentifier: UInt32,
        ownerUserIdentifier: UInt32,
        applicationCodeHash: String
    ) -> (Bool, TimeInterval?, String?) {
        queue.sync {
            _ = maintainLocked()
            guard LidAwakeSessionPolicy.accepts(duration: durationSeconds) else {
                return (false, nil, "Choose a whole-minute duration from 1 minute through 24 hours, or Until stopped.")
            }
            guard !LidAwakePlatform.isCriticalThermalState else {
                return (false, nil, "Lid-awake is unavailable while the Mac is critically hot.")
            }
            let battery = LidAwakePlatform.batteryState()
            guard !battery.isLow else {
                return (false, nil, "Lid-awake is unavailable below 15% battery while on battery power.")
            }
            guard !stopOnBattery || battery.isOnBattery == false else {
                return (false, nil, "Connect the Mac to power before starting this session.")
            }
            guard LidAwakePlatform.consoleUserIdentifier() == ownerUserIdentifier else {
                return (false, nil, "The requesting app is not owned by the current console user.")
            }
            guard let bootIdentifier = LidAwakePlatform.bootIdentifier() else {
                return (false, nil, "Could not identify the current boot session.")
            }

            do {
                let existingRecord = try journal.read()
                let lidIsClosed = LidAwakePlatform.lidIsClosed()
                let decision = LidAwakeSessionPolicy.startDecision(
                    sleepDisabled: LidAwakePlatform.sleepDisabled(),
                    hasJournal: existingRecord != nil,
                    clamshellStateAvailable: lidIsClosed != nil
                )
                guard decision == .begin else { return (false, nil, Self.message(for: decision)) }

                let nowEpoch = Date().timeIntervalSince1970
                let nowMonotonic = LidAwakePlatform.monotonicTime()
                let applying = LidAwakeSessionRecord(
                    durationSeconds: durationSeconds,
                    startedEpoch: nowEpoch,
                    startedMonotonic: nowMonotonic,
                    bootIdentifier: bootIdentifier,
                    auditSessionIdentifier: auditSessionIdentifier,
                    ownerUserIdentifier: ownerUserIdentifier,
                    ownerConnectionIdentifier: ownerConnectionIdentifier,
                    applicationCodeHash: applicationCodeHash,
                    startOnLidClose: startOnLidClose,
                    stopOnBattery: stopOnBattery,
                    lidIsClosed: lidIsClosed
                )
                let outcome = LidAwakePolicyTransitions.activate(
                    record: applying,
                    persist: { record in (try? journal.write(record)) != nil },
                    applySleepPolicy: { disabled in try LidAwakePlatform.setSleepDisabled(disabled) },
                    verifySleepPolicy: { waitForSleepPolicy(true) },
                    removeJournal: { try? journal.remove() }
                )
                switch outcome {
                case .active(let active):
                    startupRecoveryPending = false
                    return (
                        true,
                        active.deadlineEpoch,
                        active.isWaitingForLidClose ? Self.timerWaitingDetail : nil
                    )
                case .notApplied:
                    startupRecoveryPending = false
                    return (false, nil, "The system did not confirm the sleep override.")
                case .stateUnknown:
                    return (false, nil, "The helper could not verify that the sleep override was applied; recovery remains journaled.")
                case .journalFailure:
                    return (false, nil, "Could not persist the recovery journal; the sleep override was not enabled.")
                case .activeJournalFailure:
                    _ = restoreLocked(applying, sleepNowIfLidClosed: false)
                    return (false, nil, "Could not persist the active session; the helper is restoring sleep policy.")
                }
            } catch {
                return (false, nil, error.localizedDescription)
            }
        }
    }

    func stopSession(ownerConnectionIdentifier: String) -> (Bool, String?) {
        queue.sync {
            do {
                guard let record = try journal.read() else { return (true, nil) }
                guard LidAwakePolicyTransitions.ownsSession(record, connectionIdentifier: ownerConnectionIdentifier) else {
                    return (false, "This XPC connection does not own the active lid-awake session.")
                }
                let restored = restoreLocked(record, sleepNowIfLidClosed: true)
                return restored ? (true, nil) : (false, "Could not verify that normal sleep policy was restored; recovery remains active.")
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }

    func heartbeat(
        ownerConnectionIdentifier: String,
        auditSessionIdentifier: UInt32
    ) -> (Bool, TimeInterval?, String?) {
        queue.sync {
            let maintenanceReason = maintainLocked()
            if let maintenanceReason {
                return (false, nil, Self.message(for: maintenanceReason))
            }
            do {
                guard let record = try journal.read() else { return (false, nil, "No lid-awake session is active.") }
                guard LidAwakePolicyTransitions.ownsSession(record, connectionIdentifier: ownerConnectionIdentifier) else {
                    return (false, nil, "This XPC connection does not own the active lid-awake session.")
                }
                guard record.auditSessionIdentifier == auditSessionIdentifier else {
                    _ = restoreLocked(record, sleepNowIfLidClosed: true)
                    return (false, nil, "The app's login session changed; normal sleep policy is being restored.")
                }
                guard !LidAwakePlatform.isCriticalThermalState else {
                    _ = restoreLocked(record, sleepNowIfLidClosed: true)
                    return (false, nil, "The Mac is critically hot; normal sleep policy is being restored.")
                }
                let battery = LidAwakePlatform.batteryState()
                guard !battery.isLow else {
                    _ = restoreLocked(record, sleepNowIfLidClosed: true)
                    return (false, nil, "Battery fell to 15% while unplugged; normal sleep policy is being restored.")
                }
                let nowEpoch = Date().timeIntervalSince1970
                let nowMonotonic = LidAwakePlatform.monotonicTime()
                var updated = record
                guard LidAwakeSessionPolicy.heartbeat(
                    &updated,
                    nowEpoch: nowEpoch,
                    nowMonotonic: nowMonotonic,
                    bootIdentifier: LidAwakePlatform.bootIdentifier() ?? "unknown",
                    auditSessionIdentifier: auditSessionIdentifier
                ) else {
                    _ = maintainLocked()
                    return (false, nil, "The lid-awake session expired or stopped receiving heartbeats.")
                }
                try journal.write(updated)
                return (
                    true,
                    updated.deadlineEpoch,
                    updated.isWaitingForLidClose ? Self.timerWaitingDetail : nil
                )
            } catch {
                return (false, nil, error.localizedDescription)
            }
        }
    }

    func connectionInvalidated(identifier: String) {
        _ = stopSession(ownerConnectionIdentifier: identifier)
    }

    @discardableResult
    private func maintainLocked() -> LidAwakeRestoreReason? {
        var record: LidAwakeSessionRecord
        do {
            guard let found = try journal.read() else {
                startupRecoveryPending = false
                return nil
            }
            record = found
        } catch {
            LidAwakeHelperLogging.logger.error("Recovery journal read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let nowEpoch = Date().timeIntervalSince1970
        let nowMonotonic = LidAwakePlatform.monotonicTime()
        let bootIdentifier = LidAwakePlatform.bootIdentifier() ?? "unknown"
        let lidIsClosed = LidAwakePlatform.lidIsClosed()

        // Startup recovery never resumes a prior session or begins its timer after daemon restart.
        if !startupRecoveryPending,
           LidAwakeSessionPolicy.observeLidClose(
               &record,
               lidIsClosed: lidIsClosed,
               nowEpoch: nowEpoch,
               nowMonotonic: nowMonotonic
           ) {
            do {
                try journal.write(record)
            } catch {
                LidAwakeHelperLogging.logger.error("Could not persist lid-close timer start: \(error.localizedDescription, privacy: .public)")
                _ = restoreLocked(record, sleepNowIfLidClosed: false)
                startupRecoveryPending = false
                return .activationIncomplete
            }
        }

        let sleepDisabled = LidAwakePlatform.sleepDisabled()
        let action: LidAwakeRecoveryAction
        if startupRecoveryPending {
            action = LidAwakeSessionPolicy.startupRecoveryAction(
                for: record,
                sleepDisabled: sleepDisabled,
                nowEpoch: nowEpoch,
                nowMonotonic: nowMonotonic,
                bootIdentifier: bootIdentifier
            )
        } else {
            let battery = LidAwakePlatform.batteryState()
            action = LidAwakeSessionPolicy.recoveryAction(
                for: record,
                sleepDisabled: sleepDisabled,
                nowEpoch: nowEpoch,
                nowMonotonic: nowMonotonic,
                bootIdentifier: bootIdentifier,
                auditSessionIdentifier: nil,
                isOnBattery: battery.isOnBattery,
                batteryPercent: battery.percent,
                criticalThermalState: LidAwakePlatform.isCriticalThermalState,
                lidIsClosed: lidIsClosed
            )
        }
        let reason = apply(action, record: record)
        do {
            if try journal.read() == nil { startupRecoveryPending = false }
        } catch {
            // A journal read failure is not evidence that ownership state is absent.
        }
        return reason
    }

    private func apply(_ action: LidAwakeRecoveryAction, record: LidAwakeSessionRecord) -> LidAwakeRestoreReason? {
        switch action {
        case .continueSession, .waitForReadableSleepPolicy:
            return nil
        case .clearJournal:
            do {
                try journal.remove()
                startupRecoveryPending = false
            } catch {
                LidAwakeHelperLogging.logger.error("Journal cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        case .restore(let reason, let sleepNowIfLidClosed):
            LidAwakeHelperLogging.logger.notice("Restoring session after \(reason.rawValue, privacy: .public).")
            _ = restoreLocked(record, sleepNowIfLidClosed: sleepNowIfLidClosed)
            return reason
        case .finishRestore(let sleepNowIfLidClosed):
            _ = finishRestoreLocked(record, sleepNowIfLidClosed: sleepNowIfLidClosed)
            return nil
        }
    }

    @discardableResult
    private func restoreLocked(_ record: LidAwakeSessionRecord, sleepNowIfLidClosed: Bool) -> Bool {
        let outcome = LidAwakePolicyTransitions.restore(
            record: record,
            sleepNowIfLidClosed: sleepNowIfLidClosed,
            persist: { record in
                do { try journal.write(record); return true }
                catch {
                    LidAwakeHelperLogging.logger.error("Could not persist restoration state: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            },
            readSleepPolicy: { LidAwakePlatform.sleepDisabled() },
            applySleepPolicy: { disabled in try LidAwakePlatform.setSleepDisabled(disabled) },
            verifySleepPolicy: { waitForSleepPolicy(false) },
            lidIsClosed: { LidAwakePlatform.lidIsClosed() },
            requestSleepNow: { try LidAwakePlatform.sleepNow() },
            removeJournal: {
                do { try journal.remove(); return true }
                catch {
                    LidAwakeHelperLogging.logger.error("Could not remove the restored journal: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        )
        if outcome == .restored { startupRecoveryPending = false }
        return outcome == .restored
    }

    @discardableResult
    private func finishRestoreLocked(_ record: LidAwakeSessionRecord, sleepNowIfLidClosed: Bool) -> Bool {
        restoreLocked(record, sleepNowIfLidClosed: sleepNowIfLidClosed)
    }

    private func waitForSleepPolicy(_ expected: Bool) -> Bool? {
        let until = LidAwakePlatform.monotonicTime() + 2
        repeat {
            if let value = LidAwakePlatform.sleepDisabled(), value == expected { return value }
            Thread.sleep(forTimeInterval: 0.1)
        } while LidAwakePlatform.monotonicTime() < until
        return LidAwakePlatform.sleepDisabled()
    }

    private static let timerWaitingDetail = "Timer starts when lid closes."

    private static func message(for reason: LidAwakeRestoreReason) -> String {
        switch reason {
        case .unplugged: "Power disconnected; restoring normal sleep policy."
        case .powerSourceUnknown: "Power source could not be verified; restoring normal sleep policy."
        case .durationExpired: "Lid-awake timer expired; restoring normal sleep policy."
        case .heartbeatExpired: "The lid-awake session stopped receiving heartbeats; restoring normal sleep policy."
        case .lowBattery: "Battery fell to 15% while unplugged; restoring normal sleep policy."
        case .criticalThermalState: "The Mac is critically hot; restoring normal sleep policy."
        case .lidStateUnknown: "The lid state could not be verified; restoring normal sleep policy."
        case .loginSessionChanged: "The app's login session changed; restoring normal sleep policy."
        case .rebooted: "The Mac restarted; restoring normal sleep policy."
        case .helperRestart: "The helper restarted; restoring normal sleep policy."
        case .userStopped: "The lid-awake session was stopped."
        case .activationIncomplete: "The sleep override could not be verified; restoring normal sleep policy."
        }
    }

    private static func message(for decision: LidAwakeStartDecision) -> String {
        switch decision {
        case .begin: ""
        case .sleepPolicyUnknown: "Could not read the current system sleep policy."
        case .sleepAlreadyDisabled: "System sleep is already disabled by another owner; MacCoffee will not take it over."
        case .sessionAlreadyOwned: "A lid-awake session is already owned or still recovering."
        case .clamshellStateUnknown: "This Mac does not report a reliable clamshell state."
        }
    }
}
