import Foundation

@MainActor
extension LidAwakeController {
    func refreshStatusAndWait() async {
        await refreshStatusAndWaitForDecision()
    }

    func startAndWait(timeout: TimeInterval = 8) async -> Bool {
        guard setupStatus == .enabled else { return false }
        start()
        let finishBy = Date().addingTimeInterval(timeout)
        while Date() < finishBy {
            switch status {
            case .active:
                return isEnabled
            case .unavailable, .error, .off, .stopping:
                return false
            case .starting:
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func stopAndWait(timeout: TimeInterval = 8) async -> Bool {
        stop()
        let finishBy = Date().addingTimeInterval(timeout)
        while Date() < finishBy {
            switch status {
            case .off:
                return true
            case .error, .unavailable:
                return false
            case .starting, .active, .stopping:
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
