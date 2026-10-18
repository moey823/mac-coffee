import Foundation

public struct DisplayBrightnessSnapshot: Equatable {
    public let displayUUID: String
    public let brightness: Float

    public init(displayUUID: String, brightness: Float) {
        self.displayUUID = displayUUID
        self.brightness = brightness
    }
}

public struct DisplayBrightnessRecoveryRecord: Codable, Equatable {
    public let displayUUID: String
    public let originalBrightness: Float

    public init(displayUUID: String, originalBrightness: Float) {
        self.displayUUID = displayUUID
        self.originalBrightness = originalBrightness
    }
}

public enum DisplayBrightnessRestoreOutcome: Equatable {
    case restored
    case userOverride
    case noRecord
}

public enum DisplayBrightnessControllerError: LocalizedError {
    case invalidBrightness
    case displayUnavailable
    case anotherDisplayNeedsRecovery
    case dimDidNotApply
    case restoreDidNotApply

    public var errorDescription: String? {
        switch self {
        case .invalidBrightness:
            "The built-in display returned an invalid brightness value."
        case .displayUnavailable:
            "The built-in display is unavailable. Its brightness recovery record was kept for a later retry."
        case .anotherDisplayNeedsRecovery:
            "A different built-in display still has a pending brightness recovery record."
        case .dimDidNotApply:
            "The display did not reach zero brightness. Its original brightness was saved for recovery."
        case .restoreDidNotApply:
            "The original display brightness could not be verified. The recovery record was kept."
        }
    }
}

/// Coordinates a single built-in display and its crash-recovery record. The
/// injected closures keep private display APIs and persistent storage outside
/// the policy, so failures and user changes can be tested deterministically.
public struct DisplayBrightnessController {
    public static let zeroEpsilon: Float = 0.01
    public static let verificationTolerance: Float = 0.02

    private let readCurrent: () throws -> DisplayBrightnessSnapshot
    private let setBrightness: (String, Float) throws -> Void
    private let loadRecord: () throws -> DisplayBrightnessRecoveryRecord?
    private let saveRecord: (DisplayBrightnessRecoveryRecord?) throws -> Void

    public init(
        readCurrent: @escaping () throws -> DisplayBrightnessSnapshot,
        setBrightness: @escaping (String, Float) throws -> Void,
        loadRecord: @escaping () throws -> DisplayBrightnessRecoveryRecord?,
        saveRecord: @escaping (DisplayBrightnessRecoveryRecord?) throws -> Void
    ) {
        self.readCurrent = readCurrent
        self.setBrightness = setBrightness
        self.loadRecord = loadRecord
        self.saveRecord = saveRecord
    }

    public func dim() throws {
        let current = try readCurrent()
        try Self.validate(current.brightness)

        if let pending = try loadRecord() {
            guard pending.displayUUID == current.displayUUID else {
                throw DisplayBrightnessControllerError.anotherDisplayNeedsRecovery
            }
            if current.brightness <= Self.zeroEpsilon {
                return
            }
            // A nonzero reading means the user changed brightness or a prior
            // dim attempt never applied; use that current value as the new base.
            try saveRecord(nil)
        }

        let record = DisplayBrightnessRecoveryRecord(
            displayUUID: current.displayUUID,
            originalBrightness: current.brightness
        )
        try saveRecord(record)
        try setBrightness(current.displayUUID, 0)

        let dimmed = try readCurrent()
        try Self.validate(dimmed.brightness)
        guard dimmed.displayUUID == current.displayUUID else {
            throw DisplayBrightnessControllerError.displayUnavailable
        }
        guard dimmed.brightness <= Self.zeroEpsilon else {
            throw DisplayBrightnessControllerError.dimDidNotApply
        }
    }

    @discardableResult
    public func restorePending() throws -> DisplayBrightnessRestoreOutcome {
        guard let record = try loadRecord() else { return .noRecord }
        try Self.validate(record.originalBrightness)

        let current = try readCurrent()
        try Self.validate(current.brightness)
        guard current.displayUUID == record.displayUUID else {
            throw DisplayBrightnessControllerError.displayUnavailable
        }

        if current.brightness > Self.zeroEpsilon {
            // The user raised brightness manually. Never overwrite that value.
            try saveRecord(nil)
            return .userOverride
        }

        try setBrightness(record.displayUUID, record.originalBrightness)
        let restored = try readCurrent()
        try Self.validate(restored.brightness)
        guard restored.displayUUID == record.displayUUID else {
            throw DisplayBrightnessControllerError.displayUnavailable
        }
        guard abs(restored.brightness - record.originalBrightness) <= Self.verificationTolerance else {
            throw DisplayBrightnessControllerError.restoreDidNotApply
        }
        try saveRecord(nil)
        return .restored
    }

    /// Returns true when the user raised brightness and dark mode should end.
    /// A missing or unavailable display leaves its journal untouched.
    public func userRaisedBrightness() throws -> Bool {
        guard let record = try loadRecord() else { return false }
        let current = try readCurrent()
        try Self.validate(current.brightness)
        guard current.displayUUID == record.displayUUID else { return false }
        guard current.brightness > Self.zeroEpsilon else { return false }
        try saveRecord(nil)
        return true
    }

    public func hasPendingRecord() throws -> Bool {
        try loadRecord() != nil
    }

    private static func validate(_ brightness: Float) throws {
        guard brightness.isFinite, (0...1).contains(brightness) else {
            throw DisplayBrightnessControllerError.invalidBrightness
        }
    }
}
