import AppKit
import Foundation
import MacCoffeeCore
import Darwin

@main
enum MacCoffeeMain {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--diagnostic") {
            let code = await runDiagnostic()
            exit(code)
        }
        if arguments.contains("--register-lid-helper") {
            exit(registerLidHelper())
        }
        if arguments.contains("--repair-lid-helper") {
            exit(await repairLidHelper())
        }
        if arguments.contains("--show") {
            // Opening the normal menu bar app presents the popover on user click.
            // Keep this switch harmless for launcher workflows and diagnostics.
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = MacCoffeeAppDelegate(showPopoverOnLaunch: arguments.contains("--show"))
        app.delegate = delegate
        app.run()
    }

    @MainActor
    private static func runDiagnostic() async -> Int32 {
        let controller = LidAwakeController()
        let snapshot = await controller.readOnlyDiagnostic()
        print("Mac Coffee diagnostic")
        print("Bundle: \(Bundle.main.bundleURL.path)")
        print("Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"))")
        print("Lid state available: \(LidAwakeCapability.clamshellStateAvailable() ? "yes" : "no")")
        print("Helper setup: \(snapshot.setupStatus.title)")
        print("Helper detail: \(snapshot.detail ?? snapshot.setupStatus.detail)")
        if let active = snapshot.observedSessionActive {
            print("Helper session active: \(active ? "yes" : "no")")
        } else {
            print("Helper session active: unknown")
        }
        return 0
    }

    @MainActor
    private static func registerLidHelper() -> Int32 {
        guard LidAwakeCapability.clamshellStateAvailable() else {
            fputs("This Mac does not report clamshell state; no helper was registered.\n", stderr)
            return 2
        }
        let controller = LidAwakeController()
        controller.registerHelper()
        print("Helper setup: \(controller.setupStatus.title)")
        print(controller.setupStatus.detail)
        if controller.setupStatus == .enabled || controller.setupStatus == .requiresApproval { return 0 }
        return 1
    }

    @MainActor
    private static func repairLidHelper() async -> Int32 {
        guard LidAwakeCapability.clamshellStateAvailable() else {
            fputs("This Mac does not report clamshell state; no helper repair was attempted.\n", stderr)
            return 2
        }
        let controller = LidAwakeController()
        let outcome = await controller.repairHelper()
        switch outcome {
        case .ready:
            print("Lid-closed sleep support is ready.")
            return 0
        case .approvalRequired:
            print("The helper is registered. Approve Mac Coffee in System Settings > General > Login Items.")
            return 0
        case .registeredButUnavailable(let detail), .blocked(let detail), .failed(let detail):
            fputs("\(detail)\n", stderr)
            return 1
        }
    }
}
