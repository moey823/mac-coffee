import Combine
import UserNotifications

@MainActor
final class CoffeeNotifications: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var errorMessage: String?

    private let center: UNUserNotificationCenter
    private let foregroundDelegate: CoffeeNotificationForegroundDelegate

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        self.foregroundDelegate = CoffeeNotificationForegroundDelegate()
        center.delegate = foregroundDelegate
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        updatePermissionMessage()
    }

    /// Call only in response to the user enabling timer-end notifications.
    /// Refreshing status or constructing this service never prompts.
    func requestAuthorizationAfterUserOptIn() async -> Bool {
        await refreshAuthorizationStatus()

        if authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                let requestError = "Could not request notification permission: \(error.localizedDescription)"
                await refreshAuthorizationStatus()
                errorMessage = requestError
                return false
            }
            await refreshAuthorizationStatus()
        }

        switch authorizationStatus {
        case .authorized, .provisional:
            errorMessage = nil
            return true
        case .denied:
            errorMessage = "Notifications are off for Mac Coffee. Enable them in System Settings > Notifications."
            return false
        case .notDetermined:
            errorMessage = "Mac Coffee could not confirm notification permission."
            return false
        @unknown default:
            errorMessage = "Mac Coffee could not confirm notification permission."
            return false
        }
    }

    /// Call only after a normal finite timer expires, never for a manual stop or failed session.
    /// This method checks existing permission and never prompts.
    func timerFinished() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
            updatePermissionMessage()
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Mac Coffee timer finished"
        content.body = "Your keep-awake session has ended."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.moey823.MacCoffee.timerFinished.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            errorMessage = nil
        } catch {
            errorMessage = "Could not deliver the timer notification: \(error.localizedDescription)"
        }
    }

    private func updatePermissionMessage() {
        if authorizationStatus == .denied {
            errorMessage = "Notifications are off for Mac Coffee. Enable them in System Settings > Notifications."
        } else {
            errorMessage = nil
        }
    }
}

private final class CoffeeNotificationForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
