import Foundation

/// Timer values are stored in seconds to keep existing preferences and helper callers stable.
public struct LidAwakeDuration: RawRepresentable, CaseIterable, Identifiable, Hashable, Sendable {
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard rawValue == 0 || (rawValue >= 60 && rawValue <= 24 * 60 * 60 && rawValue.isMultiple(of: 60)) else {
            return nil
        }
        self.rawValue = rawValue
    }

    /// Makes a timer duration from whole minutes. Zero means Until stopped.
    public init?(minutes: Int) {
        guard (0...24 * 60).contains(minutes) else { return nil }
        self.init(rawValue: minutes * 60)
    }

    public static let minutes1 = Self(rawValue: 60)!
    public static let minutes15 = Self(rawValue: 900)!
    public static let minutes30 = Self(rawValue: 1_800)!
    public static let minutes60 = Self(rawValue: 3_600)!
    public static let minutes120 = Self(rawValue: 7_200)!
    public static let unlimited = Self(rawValue: 0)!

    /// The original presets remain the available quick choices. Custom minutes use init(minutes:).
    public static let allCases: [Self] = [
        .minutes1, .minutes15, .minutes30, .minutes60, .minutes120, .unlimited
    ]

    public var id: Int { rawValue }

    public var seconds: TimeInterval? {
        rawValue == 0 ? nil : TimeInterval(rawValue)
    }

    public var minutes: Int? {
        rawValue == 0 ? nil : rawValue / 60
    }

    public var title: String {
        switch rawValue {
        case 60: "1 minute"
        case 900: "15 minutes"
        case 1_800: "30 minutes"
        case 3_600: "60 minutes"
        case 7_200: "120 minutes"
        case 0: "Until stopped"
        default: "\(rawValue / 60) minutes"
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
    public var deadlineEpoch: TimeInterval?
    public var deadlineMonotonic: TimeInterval?
    public var lastHeartbeatEpoch: TimeInterval
    public var lastHeartbeatMonotonic: TimeInterval
    public let bootIdentifier: String
    public let auditSessionIdentifier: UInt32
    public let ownerUserIdentifier: UInt32
    public let ownerConnectionIdentifier: String
    public let applicationCodeHash: String
    /// Optional for backwards-compatible decoding of journals written before lid-close timers.
    public var startOnLidClose: Bool?
    /// Optional for backwards-compatible decoding of journals written before unplug stopping.
    public var stopOnBattery: Bool?
    /// False while waiting; set once when the first confirmed lid-close starts the timer.
    public var lidCloseTriggered: Bool?
    public var phase: LidAwakeSessionPhase
    public var sleepNowOnRestore: Bool
    public var sleepNowIssued: Bool

    public var isWaitingForLidClose: Bool {
        startOnLidClose == true && durationSeconds != nil && lidCloseTriggered != true
    }

    public var shouldStopOnBattery: Bool {
        stopOnBattery == true
    }

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
        sleepNowIssued: Bool = false,
        startOnLidClose: Bool = false,
        stopOnBattery: Bool = false,
        lidIsClosed: Bool? = true
    ) {
        let startsTimerOnLidClose = startOnLidClose && durationSeconds != nil
        let waitingForLidClose = startsTimerOnLidClose && lidIsClosed != true
        self.sessionID = sessionID
        self.durationSeconds = durationSeconds
        self.startedEpoch = startedEpoch
        self.startedMonotonic = startedMonotonic
        self.deadlineEpoch = waitingForLidClose ? nil : durationSeconds.map { startedEpoch + $0 }
        self.deadlineMonotonic = waitingForLidClose ? nil : durationSeconds.map { startedMonotonic + $0 }
        self.lastHeartbeatEpoch = startedEpoch
        self.lastHeartbeatMonotonic = startedMonotonic
        self.bootIdentifier = bootIdentifier
        self.auditSessionIdentifier = auditSessionIdentifier
        self.ownerUserIdentifier = ownerUserIdentifier
        self.ownerConnectionIdentifier = ownerConnectionIdentifier
        self.applicationCodeHash = applicationCodeHash
        self.startOnLidClose = startsTimerOnLidClose
        self.stopOnBattery = stopOnBattery
        self.lidCloseTriggered = !waitingForLidClose
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
    case unplugged
    case powerSourceUnknown
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
        return duration.isFinite
            && duration >= minimumDuration
            && duration <= maximumDuration
            && duration.truncatingRemainder(dividingBy: 60) == 0
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

    /// Starts the timer on the first confirmed lid close. Subsequent observations never move its deadline.
    @discardableResult
    public static func observeLidClose(
        _ record: inout LidAwakeSessionRecord,
        lidIsClosed: Bool?,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval
    ) -> Bool {
        guard record.phase == .active,
              record.isWaitingForLidClose,
              lidIsClosed == true,
              let duration = record.durationSeconds,
              accepts(duration: duration) else {
            return false
        }
        record.lidCloseTriggered = true
        record.deadlineEpoch = nowEpoch + duration
        record.deadlineMonotonic = nowMonotonic + duration
        return true
    }

    public static func deadlineHasPassed(
        _ record: LidAwakeSessionRecord,
        nowEpoch: TimeInterval,
        nowMonotonic: TimeInterval,
        bootIdentifier: String
    ) -> Bool {
        guard let duration = record.durationSeconds else { return false }
        guard accepts(duration: duration) else { return true }
        // An armed session has no countdown yet, regardless of how long it has been active.
        guard !record.isWaitingForLidClose else { return false }

        if bootIdentifier == record.bootIdentifier {
            let monotonicDeadline: TimeInterval
            if let savedDeadline = record.deadlineMonotonic {
                monotonicDeadline = savedDeadline
            } else if record.startOnLidClose == true {
                // A triggered close timer without its persisted deadline is malformed; fail closed.
                return true
            } else {
                monotonicDeadline = record.startedMonotonic + duration
            }
            if nowMonotonic >= monotonicDeadline { return true }
        }

        let wallDeadline: TimeInterval
        if let savedDeadline = record.deadlineEpoch {
            wallDeadline = savedDeadline
        } else if record.startOnLidClose == true {
            return true
        } else {
            wallDeadline = record.startedEpoch + duration
        }
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
        criticalThermalState: Bool,
        lidIsClosed: Bool? = nil
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
        if record.shouldStopOnBattery {
            guard let isOnBattery else {
                return .restore(reason: .powerSourceUnknown, sleepNowIfLidClosed: true)
            }
            if isOnBattery {
                return .restore(reason: .unplugged, sleepNowIfLidClosed: true)
            }
        }
        if isOnBattery == true, let batteryPercent, batteryPercent <= 15 {
            return .restore(reason: .lowBattery, sleepNowIfLidClosed: true)
        }
        if record.isWaitingForLidClose, lidIsClosed == nil {
            return .restore(reason: .lidStateUnknown, sleepNowIfLidClosed: false)
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
