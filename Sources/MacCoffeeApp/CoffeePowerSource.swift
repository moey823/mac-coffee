import IOKit.ps

enum CoffeePowerSource: Equatable, Sendable {
    case ac
    case battery
    case unknown

    static func current() -> CoffeePowerSource {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let unmanagedSourceType = IOPSGetProvidingPowerSourceType(snapshot) else { return .unknown }
        let sourceType = unmanagedSourceType.takeUnretainedValue() as String

        switch sourceType {
        case "AC Power", "UPS Power":
            return .ac
        case "Battery Power":
            return .battery
        default:
            return .unknown
        }
    }
}
