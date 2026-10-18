import ColorSync
import CoreGraphics
import Darwin
import Foundation
import MacCoffeeCore

struct MacCoffeeDisplayBrightnessDiagnostic {
    let support: String
    let builtInBrightness: String
    let pendingRecovery: String
}

/// Runtime bridge to the private DisplayServices symbols and an atomic
/// Application Support recovery record. Only the built-in display is targeted.
final class MacCoffeeDisplayBrightness {
    static let shared = MacCoffeeDisplayBrightness()

    private let api = DisplayServicesBrightnessAPI()
    private let journal = DisplayBrightnessRecoveryJournal()

    var controller: DisplayBrightnessController {
        let api = self.api
        let journal = self.journal
        return DisplayBrightnessController(
            readCurrent: { try api.readBuiltInBrightness() },
            setBrightness: { uuid, value in try api.setBuiltInBrightness(value, displayUUID: uuid) },
            loadRecord: { try journal.load() },
            saveRecord: { try journal.save($0) }
        )
    }

    func diagnostic() -> MacCoffeeDisplayBrightnessDiagnostic {
        let support: String
        let brightness: String
        do {
            let snapshot = try api.readBuiltInBrightness()
            if let canChange = api.canSetBrightness(snapshot: snapshot), !canChange {
                support = "not supported by the built-in display"
            } else {
                support = "available"
            }
            brightness = String(format: "%.3f", snapshot.brightness)
        } catch {
            support = api.supportDescription(error: error)
            brightness = "unavailable"
        }

        let pending: String
        do {
            pending = try journal.load() == nil ? "no" : "yes"
        } catch {
            pending = "unavailable"
        }
        return MacCoffeeDisplayBrightnessDiagnostic(
            support: support,
            builtInBrightness: brightness,
            pendingRecovery: pending
        )
    }
}

private enum DisplayBrightnessAPIError: LocalizedError {
    case privateAPIUnavailable
    case builtInDisplayUnavailable
    case displayIdentityUnavailable
    case brightnessUnsupported
    case apiFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            "Display brightness control is unavailable on this Mac."
        case .builtInDisplayUnavailable:
            "The built-in display is unavailable. Any brightness recovery record was kept."
        case .displayIdentityUnavailable:
            "Mac Coffee could not identify the built-in display safely."
        case .brightnessUnsupported:
            "The built-in display does not support brightness control through DisplayServices."
        case .apiFailed(let status):
            "DisplayServices returned error \(status)."
        }
    }
}

private final class DisplayServicesBrightnessAPI {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias CreateDisplayUUID = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?

    private let library: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    private let canChangeBrightness: CanChangeBrightness?
    private let colorSyncLibrary: UnsafeMutableRawPointer?
    private let createDisplayUUID: CreateDisplayUUID?

    init() {
        library = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        colorSyncLibrary = dlopen("/System/Library/Frameworks/ColorSync.framework/ColorSync", RTLD_LAZY)
        if let colorSyncLibrary {
            createDisplayUUID = dlsym(colorSyncLibrary, "CGDisplayCreateUUIDFromDisplayID")
                .map { unsafeBitCast($0, to: CreateDisplayUUID.self) }
        } else {
            createDisplayUUID = nil
        }
        if let library {
            getBrightness = dlsym(library, "DisplayServicesGetBrightness")
                .map { unsafeBitCast($0, to: GetBrightness.self) }
            setBrightness = dlsym(library, "DisplayServicesSetBrightness")
                .map { unsafeBitCast($0, to: SetBrightness.self) }
            canChangeBrightness = dlsym(library, "DisplayServicesCanChangeBrightness")
                .map { unsafeBitCast($0, to: CanChangeBrightness.self) }
        } else {
            getBrightness = nil
            setBrightness = nil
            canChangeBrightness = nil
        }
    }

    func supportDescription(error: Error) -> String {
        if getBrightness == nil || setBrightness == nil {
            return "unavailable (DisplayServices symbols not found)"
        }
        if error is DisplayBrightnessAPIError {
            return "unavailable (\(error.localizedDescription))"
        }
        return "unavailable"
    }

    func canSetBrightness(snapshot: DisplayBrightnessSnapshot) -> Bool? {
        guard let canChangeBrightness else { return nil }
        guard let displayID = builtInDisplayID(matching: snapshot.displayUUID) else { return false }
        return canChangeBrightness(displayID)
    }

    func readBuiltInBrightness() throws -> DisplayBrightnessSnapshot {
        guard let getBrightness, setBrightness != nil else {
            throw DisplayBrightnessAPIError.privateAPIUnavailable
        }
        guard let displayID = builtInDisplayID() else {
            throw DisplayBrightnessAPIError.builtInDisplayUnavailable
        }
        guard let displayUUID = uuid(for: displayID) else {
            throw DisplayBrightnessAPIError.displayIdentityUnavailable
        }
        if let canChangeBrightness, !canChangeBrightness(displayID) {
            throw DisplayBrightnessAPIError.brightnessUnsupported
        }
        var brightness: Float = -1
        let status = getBrightness(displayID, &brightness)
        guard status == 0 else { throw DisplayBrightnessAPIError.apiFailed(status) }
        return DisplayBrightnessSnapshot(displayUUID: displayUUID, brightness: brightness)
    }

    func setBuiltInBrightness(_ brightness: Float, displayUUID: String) throws {
        guard let setBrightness else { throw DisplayBrightnessAPIError.privateAPIUnavailable }
        guard let displayID = builtInDisplayID(matching: displayUUID) else {
            throw DisplayBrightnessAPIError.builtInDisplayUnavailable
        }
        if let canChangeBrightness, !canChangeBrightness(displayID) {
            throw DisplayBrightnessAPIError.brightnessUnsupported
        }
        let status = setBrightness(displayID, brightness)
        guard status == 0 else { throw DisplayBrightnessAPIError.apiFailed(status) }
    }

    private func builtInDisplayID(matching expectedUUID: String? = nil) -> CGDirectDisplayID? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        let status = CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount)
        guard status == .success else { return nil }
        for displayID in displayIDs.prefix(Int(displayCount)) {
            guard CGDisplayIsBuiltin(displayID) != 0, CGDisplayIsOnline(displayID) != 0 else { continue }
            guard let expectedUUID else { return displayID }
            if uuid(for: displayID) == expectedUUID { return displayID }
        }
        return nil
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let createDisplayUUID, let unmanagedUUID = createDisplayUUID(displayID) else { return nil }
        let uuid = unmanagedUUID.takeRetainedValue()
        guard let uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuid) else { return nil }
        return uuidString as String
    }
}

private struct DisplayBrightnessRecoveryJournal {
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        fileURL = supportURL
            .appendingPathComponent("com.moey823.MacCoffee", isDirectory: true)
            .appendingPathComponent("DisplayBrightnessRecovery.plist")
    }

    func load() throws -> DisplayBrightnessRecoveryRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try PropertyListDecoder().decode(DisplayBrightnessRecoveryRecord.self, from: data)
        } catch {
            throw JournalError.readFailed(error.localizedDescription)
        }
    }

    func save(_ record: DisplayBrightnessRecoveryRecord?) throws {
        do {
            if let record {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                try encoder.encode(record).write(to: fileURL, options: .atomic)
                try synchronize(fileURL)
                try synchronize(fileURL.deletingLastPathComponent())
            } else {
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
                try FileManager.default.removeItem(at: fileURL)
                try synchronize(fileURL.deletingLastPathComponent())
            }
        } catch {
            throw JournalError.writeFailed(error.localizedDescription)
        }
    }

    private func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw JournalError.writeFailed("Could not open the recovery record for synchronization.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw JournalError.writeFailed("Could not flush the recovery record to disk.")
        }
    }

    private enum JournalError: LocalizedError {
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .readFailed(let detail): "Could not read the display brightness recovery record: \(detail)"
            case .writeFailed(let detail): "Could not safely update the display brightness recovery record: \(detail)"
            }
        }
    }
}
