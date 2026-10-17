import OSLog
import MacCoffeeCore

enum LidAwakeHelperLogging {
    static let logger = Logger(
        subsystem: LidAwakeServiceConfiguration.applicationIdentifier,
        category: "LidAwakeHelper"
    )
}
