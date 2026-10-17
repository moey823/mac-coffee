import CoreFoundation
import Foundation
import IOKit

public enum LidAwakeCapability {
    /// A missing AppleClamshellState means this Mac cannot safely use the
    /// closed-lid sleep override, so the app uses ordinary caffeinate.
    public static func clamshellStateAvailable() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return false }
        let value = unmanaged.takeRetainedValue()
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return true }
        if value is String || value is NSNumber { return true }
        return false
    }
}
