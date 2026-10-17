import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import MacCoffeeCore

struct LidAwakePlatform {
    enum BatteryState {
        case notOnBattery
        case onBattery(percent: Double?)
        case unknown

        var isOnBattery: Bool? {
            switch self {
            case .notOnBattery: false
            case .onBattery: true
            case .unknown: nil
            }
        }

        var percent: Double? {
            if case .onBattery(let value) = self { return value }
            return nil
        }

        var isLow: Bool {
            isOnBattery == true && (percent ?? 100) <= 15
        }
    }

    static func sleepDisabled() -> Bool? { registryBoolean("SleepDisabled") }
    static func lidIsClosed() -> Bool? { registryBoolean("AppleClamshellState") }
    static func clamshellStateAvailable() -> Bool { lidIsClosed() != nil }
    static var isCriticalThermalState: Bool { ProcessInfo.processInfo.thermalState == .critical }

    static func setSleepDisabled(_ disabled: Bool) throws {
        try runPMSet(arguments: LidAwakeCommandPlan.setSleepDisabled(disabled))
    }

    static func sleepNow() throws { try runPMSet(arguments: LidAwakeCommandPlan.sleepNow) }

    static func batteryState() -> BatteryState {
        guard let sourcesInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceList = IOPSCopyPowerSourcesList(sourcesInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unknown
        }
        guard !sourceList.isEmpty else { return .notOnBattery }

        let descriptions: [[String: Any]] = sourceList.compactMap { source in
            guard let unmanaged = IOPSGetPowerSourceDescription(sourcesInfo, source) else { return nil }
            return unmanaged.takeUnretainedValue() as? [String: Any]
        }
        let internalBatteries = descriptions.filter {
            ($0[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String)
        }
        // Prefer the Mac's own battery if present; external UPS devices can be listed first.
        let candidates = internalBatteries.isEmpty ? descriptions : internalBatteries
        var sawBattery = false
        var sawAC = false
        var batteryPercent: Double?
        for description in candidates {
            guard let state = description[kIOPSPowerSourceStateKey as String] as? String else { continue }
            if state == kIOPSBatteryPowerValue as String {
                sawBattery = true
                if batteryPercent == nil,
                   let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue,
                   let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue,
                   maximum > 0 {
                    batteryPercent = min(100, max(0, current / maximum * 100))
                }
            } else if state == kIOPSACPowerValue as String {
                sawAC = true
            }
        }
        if sawBattery { return .onBattery(percent: batteryPercent) }
        if sawAC { return .notOnBattery }
        return .unknown
    }

    static func bootIdentifier() -> String? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else { return nil }
        return "\(bootTime.tv_sec):\(bootTime.tv_usec)"
    }

    static func monotonicTime() -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let nanos = Double(mach_continuous_time()) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000
    }

    static func consoleUserIdentifier() -> UInt32? {
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
              !username.isEmpty, username != "loginwindow", uid != 0 else { return nil }
        return UInt32(uid)
    }

    private static func registryBoolean(_ key: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
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

    private static func runPMSet(arguments: [String]) throws {
        let process = Process()
        let termination = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: LidAwakeCommandPlan.executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in termination.signal() }
        try process.run()

        if termination.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 1) == .timedOut {
                let pid = process.processIdentifier
                if pid > 0 { _ = kill(pid, SIGKILL) }
                guard termination.wait(timeout: .now() + 1) == .success else {
                    throw PlatformError.pmsetTimedOut
                }
            }
            throw PlatformError.pmsetTimedOut
        }
        guard process.terminationStatus == 0 else { throw PlatformError.pmsetFailed(process.terminationStatus) }
    }

}

enum PlatformError: Error, LocalizedError {
    case pmsetFailed(Int32)
    case pmsetTimedOut

    var errorDescription: String? {
        switch self {
        case .pmsetFailed(let status): "pmset exited with status \(status)."
        case .pmsetTimedOut: "pmset did not exit within the safety timeout."
        }
    }
}
