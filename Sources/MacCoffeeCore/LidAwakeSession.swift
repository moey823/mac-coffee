import Foundation

public enum LidAwakeDuration: Int, CaseIterable, Identifiable, Sendable {
    case minutes1 = 60
    case minutes15 = 900
    case minutes30 = 1800
    case minutes60 = 3600
    case minutes120 = 7200
    case unlimited = 0

    public var id: Int { rawValue }

    public var seconds: TimeInterval? {
        self == .unlimited ? nil : TimeInterval(rawValue)
    }

    public var title: String {
        switch self {
        case .minutes1: "1 minute"
        case .minutes15: "15 minutes"
        case .minutes30: "30 minutes"
        case .minutes60: "60 minutes"
        case .minutes120: "120 minutes"
        case .unlimited: "Until stopped"
        }
    }
}

public enum LidAwakeSessionPhase: String, Codable, Sendable {
    case applying
    case active
    case restoring
}

public struct LidAwakeSessionRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let durationSeconds: TimeInterval?
    public let startedEpoch: TimeInterval
    public let startedMonotonic: TimeInterval
    public let deadlineEpoch: TimeInterval?
    public let deadlineMonotonic: TimeInterval?
    public var lastHeartbeatEpoch: TimeInterval
    public var lastHeartbeatMonotonic: TimeInterval
    public let bootIdentifier: String
    public let auditSessionIdentifier: UInt32
    public let ownerUserIdentifier: UInt32
    public let ownerConnectionIdentifier: String
    public let applicationCodeHash: String
    public var phase: LidAwakeSessionPhase
    public var sleepNowOnRestore: Bool
    public var sleepNowIssued: Bool

    public init(
        sessionID: String = UUID().uuidString,
        durationSeconds: TimeInterval?,
        startedEpoch: TimeInterval,
        startedMonotonic: TimeInterval,
        bootIdentifier: String,
        auditSessionIdentifier: UInt32,
        ownerUserIdentifier: UInt32,
        ownerConnectionIdentifier: String = UUID().uuidString,
        applicationCodeHash: String,
        phase: LidAwakeSessionPhase = .applying,
        sleepNowOnRestore: Bool = false,
        sleepNowIssued: Bool = false
    ) {
        self.sessionID = sessionID
        self.durationSeconds = durationSeconds
        self.startedEpoch = startedEpoch
        self.startedMonotonic = startedMonotonic
        self.deadlineEpoch = durationSeconds.map { startedEpoch + $0 }
        self.deadlineMonotonic = durationSeconds.map { startedMonotonic + $0 }
        self.lastHeartbeatEpoch = startedEpoch
        self.lastHeartbeatMonotonic = startedMonotonic
        self.bootIdentifier = bootIdentifier
        self.auditSessionIdentifier = auditSessionIdentifier
        self.ownerUserIdentifier = ownerUserIdentifier
        self.ownerConnectionIdentifier = ownerConnectionIdentifier
        self.applicationCodeHash = applicationCodeHash
        self.phase = phase
        self.sleepNowOnRestore = sleepNowOnRestore
        self.sleepNowIssued = sleepNowIssued
    }
}

public enum LidAwakeRestoreReason: String, Equatable, Sendable {
    case activationIncomplete
    case userStopped
    case durationExpired
    case heartbeatExpired
    case lidStateUnknown
    case lowBattery
    case criticalThermalState
    case helperRestart
    case rebooted
    case loginSessionChanged
}

public enum LidAwakeStartDecision: Equatable, Sendable {
    case begin
    case sleepPolicyUnknown
    case sleepAlreadyDisabled
    case sessionAlreadyOwned
    case clamshellStateUnknown
}

public enum LidAwakeRecoveryAction: Equatable, Sendable {
    case continueSession
    case clearJournal
    case restore(reason: LidAwakeRestoreReason, sleepNowIfLidClosed: Bool)
    case finishRestore(sleepNowIfLidClosed: Bool)
    case waitForReadableSleepPolicy
}

public enum LidAwakeSessionPolicy {
    public static let minimumDuration: TimeInterval = 60
    public static let maximumDuration: TimeInterval = 24 * 60 * 60
    public static let heartbeatTimeout: TimeInterval = 30

    public static func accepts(duration: TimeInterval?) -> Bool {
        guard let duration else { return true }
        return duration.isFinite && duration >= minimumDuration && duration <= maximumDuration
    }

    public static func startDecision(
        sleepDisabled: Bool?,
        hasJournal: Bool,
        clamshellStateAvailable: Bool = true
    ) -> LidAwakeStartDecision {
        guard clamshellStateAvailable else { return .clamshellStateUnknown }
        guard let sleepDisabled else { return .sleepPolicyUnknown }
        guard !hasJournal else { return .sessionAlreadyOwned }
        return sleepDisabled ? .sleepAlreadyDisabled : .begin
    }

    public static func heartbeatIsCurrent(
        _ record: LidAwakeSessionRecord,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval,
        bootIdentifier: String
    ) -> Bool {
        guard bootIdentifier == record.bootIdentifier else { return false }
        let elapsed = nowMonotonic - record.lastHeartbeatMonotonic
        let wallElapsed = nowEpoch - record.lastHeartbeatEpoch
        return elapsed >= 0 && wallElapsed >= 0 && elapsed < heartbeatTimeout && wallElapsed < heartbeatTimeout
    }

    public static func deadlineHasPassed(
        _ record: LidAwakeSessionRecord,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval,
        bootIdentifier: String
    ) -> Bool {
        guard let duration = record.durationSeconds else { return false }
        guard accepts(duration: duration) else { return true }
        if bootIdentifier == record.bootIdentifier {
            let monotonicDeadline = record.deadlineMonotonic ?? (record.startedMonotonic + duration)
            if nowMonotonic >= monotonicDeadline { return true }
        }
        let wallDeadline = record.deadlineEpoch ?? (record.startedEpoch + duration)
        return nowEpoch >= wallDeadline
    }

    public static func startupRecoveryAction(
        for record: LidAwakeSessionRecord,
        sleepDisabled: Bool?,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval,
        bootIdentifier: String
    ) -> LidAwakeRecoveryAction {
        guard let sleepDisabled else { return .waitForReadableSleepPolicy }
        if !sleepDisabled {
            if record.phase == .restoring {
                return .finishRestore(sleepNowIfLidClosed: record.sleepNowOnRestore && !record.sleepNowIssued)
            }
            return .clearJournal
        }
        if record.phase == .restoring {
            return .restore(
                reason: .helperRestart,
                sleepNowIfLidClosed: record.sleepNowOnRestore && !record.sleepNowIssued
            )
        }
        guard record.phase == .active else {
            return .restore(reason: .activationIncomplete, sleepNowIfLidClosed: false)
        }
        let rebooted = record.bootIdentifier != bootIdentifier
        return .restore(
            reason: rebooted ? .rebooted : .helperRestart,
            sleepNowIfLidClosed: !rebooted
        )
    }

    public static func recoveryAction(
        for record: LidAwakeSessionRecord,
        sleepDisabled: Bool?,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval,
        bootIdentifier: String,
        auditSessionIdentifier: UInt32?,
        isOnBattery: Bool?,
        batteryPercent: Double?,
        criticalThermalState: Bool
    ) -> LidAwakeRecoveryAction {
        guard let sleepDisabled else { return .waitForReadableSleepPolicy }

        if record.phase == .restoring {
            if sleepDisabled {
                return .restore(
                    reason: .userStopped,
                    sleepNowIfLidClosed: record.sleepNowOnRestore && !record.sleepNowIssued
                )
            }
            return .finishRestore(sleepNowIfLidClosed: record.sleepNowOnRestore && !record.sleepNowIssued)
        }

        guard sleepDisabled else { return .clearJournal }
        guard record.phase == .active else {
            return .restore(reason: .activationIncomplete, sleepNowIfLidClosed: false)
        }
        guard bootIdentifier == record.bootIdentifier else {
            return .restore(reason: .rebooted, sleepNowIfLidClosed: false)
        }
        if let auditSessionIdentifier, auditSessionIdentifier != record.auditSessionIdentifier {
            return .restore(reason: .loginSessionChanged, sleepNowIfLidClosed: true)
        }
        guard accepts(duration: record.durationSeconds) else {
            return .restore(reason: .activationIncomplete, sleepNowIfLidClosed: false)
        }
        if criticalThermalState {
            return .restore(reason: .criticalThermalState, sleepNowIfLidClosed: true)
        }
        if isOnBattery == true, let batteryPercent, batteryPercent <= 15 {
            return .restore(reason: .lowBattery, sleepNowIfLidClosed: true)
        }
        if deadlineHasPassed(record, nowEpoch: nowEpoch, nowMonotonic: nowMonotonic, bootIdentifier: bootIdentifier) {
            return .restore(reason: .durationExpired, sleepNowIfLidClosed: true)
        }
        if !heartbeatIsCurrent(record, nowEpoch: nowEpoch, nowMonotonic: nowMonotonic, bootIdentifier: bootIdentifier) {
            return .restore(reason: .heartbeatExpired, sleepNowIfLidClosed: true)
        }
        return .continueSession
    }

    public static func heartbeat(
        _ record: inout LidAwakeSessionRecord,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval,
        bootIdentifier: String,
        auditSessionIdentifier: UInt32
    ) -> Bool {
        guard record.phase == .active,
              auditSessionIdentifier == record.auditSessionIdentifier,
              heartbeatIsCurrent(record, nowEpoch: nowEpoch, nowMonotonic: nowMonotonic, bootIdentifier: bootIdentifier),
              !deadlineHasPassed(record, nowEpoch: nowEpoch, nowMonotonic: nowMonotonic, bootIdentifier: bootIdentifier) else {
            return false
        }
        record.lastHeartbeatEpoch = nowEpoch
        record.lastHeartbeatMonotonic = nowMonotonic
        return true
    }
}
