import Foundation

public enum CoffeeMenuBarState: Equatable {
    case off
    case starting
    case active(remaining: TimeInterval?)
    case stopping
    case error(String)
}

public struct CoffeeMenuBarPresentation: Equatable {
    public let symbolName: String
    public let title: String
    public let accessibilityLabel: String

    private init(symbolName: String, title: String, accessibilityLabel: String) {
        self.symbolName = symbolName
        self.title = title
        self.accessibilityLabel = accessibilityLabel
    }

    public static func make(for state: CoffeeMenuBarState, keepsScreenOn: Bool) -> Self {
        switch state {
        case .off:
            return Self(
                symbolName: "cup.and.saucer",
                title: "OFF",
                accessibilityLabel: "Mac Coffee is off. Your Mac can sleep normally."
            )
        case .starting:
            return Self(
                symbolName: "hourglass",
                title: "Starting",
                accessibilityLabel: "Mac Coffee is starting the awake session."
            )
        case .active(let remaining):
            let time = remaining.map(timerText) ?? (compact: "ON", spoken: "until stopped")
            let displayMessage = keepsScreenOn ? " The display is also being kept awake." : ""
            return Self(
                symbolName: "cup.and.saucer.fill",
                title: time.compact,
                accessibilityLabel: "Mac Coffee is on, \(time.spoken).\(displayMessage)"
            )
        case .stopping:
            return Self(
                symbolName: "arrow.uturn.backward.circle",
                title: "Stopping",
                accessibilityLabel: "Mac Coffee is stopping and restoring normal sleep behavior."
            )
        case .error(let detail):
            return Self(
                symbolName: "exclamationmark.triangle.fill",
                title: "Fix",
                accessibilityLabel: "Mac Coffee needs attention. \(detail)"
            )
        }
    }

    private static func timerText(_ remaining: TimeInterval) -> (compact: String, spoken: String) {
        let totalSeconds = max(0, Int(ceil(max(0, remaining))))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let compact = String(format: "%02d:%02d", minutes, seconds)
        let spokenHours = minutes / 60
        let spokenMinutes = minutes % 60
        var parts: [String] = []
        if spokenHours > 0 {
            parts.append("\(spokenHours) \(spokenHours == 1 ? "hour" : "hours")")
        }
        if spokenMinutes > 0 {
            parts.append("\(spokenMinutes) \(spokenMinutes == 1 ? "minute" : "minutes")")
        }
        if parts.isEmpty {
            parts.append("less than one minute")
        }
        let remainingText = parts.joined(separator: " and ")
        return (compact, "\(remainingText) remaining")
    }
}
