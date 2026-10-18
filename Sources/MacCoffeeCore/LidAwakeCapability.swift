import CoreFoundation
import Foundation
import IOKit

public enum LidAwakeCapability {
    /// A missing or unrecognized AppleClamshellState means this Mac cannot
    /// safely use the closed-lid sleep override.
    public static func clamshellIsClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    public static func clamshellStateAvailable() -> Bool {
        clamshellIsClosed() != nil
    }
}
