import Foundation

public enum CoffeeMenuBarState: Equatable {
    case off
    case starting
    case waitingForLidClose
    case active(remaining: TimeInterval?)
    case stopping
    case error(String)
}

public enum CoffeeMenuBarTint: Equatable { case red, green, amber }

public struct CoffeeMenuBarPresentation: Equatable {
    public let symbolName: String
    public let tint: CoffeeMenuBarTint
    public let accessibilityLabel: String

    private init(symbolName: String, tint: CoffeeMenuBarTint, accessibilityLabel: String) {
        self.symbolName = symbolName
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
    }

    public static func make(for state: CoffeeMenuBarState, keepsScreenOn: Bool) -> Self {
        switch state {
        case .off:
            return Self(symbolName: "cup.and.saucer", tint: .red,
                        accessibilityLabel: "Mac Coffee is off. Your Mac can sleep normally.")
        case .starting:
            return Self(symbolName: "hourglass", tint: .amber,
                        accessibilityLabel: "Mac Coffee is starting the awake session.")
        case .waitingForLidClose:
            return Self(symbolName: "cup.and.saucer.fill", tint: .green,
                        accessibilityLabel: "Mac Coffee is on. The timer starts when the lid closes.")
        case .active(let remaining):
            let time = remaining.map(spokenRemaining) ?? "until stopped"
            let displayMessage = keepsScreenOn ? " The display is also being kept awake." : ""
            return Self(symbolName: "cup.and.saucer.fill", tint: .green,
                        accessibilityLabel: "Mac Coffee is on, \(time).\(displayMessage)")
        case .stopping:
            return Self(symbolName: "arrow.uturn.backward.circle", tint: .amber,
                        accessibilityLabel: "Mac Coffee is stopping and restoring normal sleep behavior.")
        case .error(let detail):
            return Self(symbolName: "exclamationmark.triangle.fill", tint: .red,
                        accessibilityLabel: "Mac Coffee needs attention. \(detail)")
        }
    }

    private static func spokenRemaining(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(max(0, remaining))))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let extraSeconds = seconds % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if extraSeconds > 0 { parts.append("\(extraSeconds) \(extraSeconds == 1 ? "second" : "seconds")") }
        if parts.isEmpty { parts.append("less than one second") }
        return "\(parts.joined(separator: " and ")) remaining"
    }
}
