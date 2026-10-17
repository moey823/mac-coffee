import Darwin
import Dispatch
import Foundation
import OSLog
import MacCoffeeCore

@main
enum MacCoffeeLidAwakeHelperMain {
    private static let logger = LidAwakeHelperLogging.logger

    static func main() {
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "--bootstrap-diagnostic" {
            let diagnostic = LidAwakeBootstrapDiagnostic.current()
            print(diagnostic.json)
            if !diagnostic.isReady { Darwin.exit(2) }
            return
        }

        logger.info("Helper startup entered. argv0=\(CommandLine.arguments.first ?? "", privacy: .public)")
        guard geteuid() == 0 else {
            logger.error("Startup refused because the helper is not running as root.")
            Darwin.exit(77)
        }

        let coordinator = LidAwakeSessionCoordinator()
        // Recovery must complete before the app's signing identity is read or XPC is authorized.
        logger.info("Beginning recovery pass before XPC authorization.")
        coordinator.recoverBeforeAuthorization()
        logger.info("Recovery pass returned; starting recovery maintenance.")
        coordinator.startPeriodicMaintenance()
        var server: LidAwakeXPCServer?

        do {
            let helperURL = try LidAwakeProcessPath.executableURL(for: getpid())
            let applicationBundleURL = LidAwakeServiceConfiguration
                .applicationBundleURL(containingHelperAt: helperURL)
            let expectedHelperURL = LidAwakeServiceConfiguration
                .helperExecutableURL(in: applicationBundleURL)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            logger.info("Resolved helper executable path=\(helperURL.path, privacy: .public)")
            logger.info("Derived app bundle path=\(applicationBundleURL.path, privacy: .public)")
            guard helperURL.path == expectedHelperURL.path else {
                throw HelperStartupError.helperPathMismatch
            }

            let applicationIdentity = try LidAwakeCodeIdentityReader.read(
                executableURL: LidAwakeServiceConfiguration.applicationExecutableURL(in: applicationBundleURL)
            )
            logger.info("Validated app code identity id=\(applicationIdentity.identifier, privacy: .public) cdhash=\(applicationIdentity.codeHash, privacy: .public)")
            guard applicationIdentity.identifier == LidAwakeServiceConfiguration.applicationIdentifier else {
                throw HelperStartupError.applicationIdentifierMismatch
            }
            let listener = LidAwakeXPCServer(
                coordinator: coordinator,
                applicationBundleURL: applicationBundleURL,
                applicationIdentity: applicationIdentity
            )
            server = listener
            logger.info("Starting XPC listener service=\(LidAwakeServiceConfiguration.machServiceName, privacy: .public)")
            listener.start()
            logger.info("XPC listener start returned.")
        } catch {
            // Keep running the recovery timer even if app identity is unavailable.
            logger.error("XPC service startup failed; recovery monitoring remains active: \(error.localizedDescription, privacy: .public)")
        }
        withExtendedLifetime((coordinator, server)) {
            dispatchMain()
        }
    }
}

enum HelperStartupError: Error, LocalizedError {
    case helperPathMismatch
    case applicationIdentifierMismatch

    var errorDescription: String? {
        switch self {
        case .helperPathMismatch: "The helper is not running from its expected app-bundle path."
        case .applicationIdentifierMismatch: "The containing app has an unexpected signing identifier."
        }
    }
}
