import Combine
import Foundation

@MainActor
final class CoffeePreferences: ObservableObject {
    static let shared = CoffeePreferences()

    @Published var startAtLogin: Bool {
        didSet { persist(startAtLogin, key: Keys.startAtLogin) }
    }

    @Published var shortcutEnabled: Bool {
        didSet { persist(shortcutEnabled, key: Keys.shortcutEnabled) }
    }

    @Published var stopOnBattery: Bool {
        didSet { persist(stopOnBattery, key: Keys.stopOnBattery) }
    }

    @Published var notifyOnTimerEnd: Bool {
        didSet { persist(notifyOnTimerEnd, key: Keys.notifyOnTimerEnd) }
    }

    @Published var keepsDisksAwake: Bool {
        didSet { persist(keepsDisksAwake, key: Keys.keepsDisksAwake) }
    }

    @Published var preventsSystemSleepOnAC: Bool {
        didSet { persist(preventsSystemSleepOnAC, key: Keys.preventsSystemSleepOnAC) }
    }

    @Published var wakeScreenOnStart: Bool {
        didSet { persist(wakeScreenOnStart, key: Keys.wakeScreenOnStart) }
    }

    @Published var timerStartsOnLidClose: Bool {
        didSet { persist(timerStartsOnLidClose, key: Keys.timerStartsOnLidClose) }
    }

    private enum Keys {
        static let startAtLogin = "com.moey823.MacCoffee.startAtLogin"
        static let shortcutEnabled = "com.moey823.MacCoffee.shortcutEnabled"
        static let stopOnBattery = "com.moey823.MacCoffee.stopOnBattery"
        static let notifyOnTimerEnd = "com.moey823.MacCoffee.notifyOnTimerEnd"
        static let keepsDisksAwake = "com.moey823.MacCoffee.keepsDisksAwake"
        static let preventsSystemSleepOnAC = "com.moey823.MacCoffee.preventsSystemSleepOnAC"
        static let wakeScreenOnStart = "com.moey823.MacCoffee.wakeScreenOnStart"
        static let timerStartsOnLidClose = "com.moey823.MacCoffee.timerStartsOnLidClose"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.startAtLogin = defaults.bool(forKey: Keys.startAtLogin)
        self.shortcutEnabled = defaults.bool(forKey: Keys.shortcutEnabled)
        self.stopOnBattery = defaults.bool(forKey: Keys.stopOnBattery)
        self.notifyOnTimerEnd = defaults.bool(forKey: Keys.notifyOnTimerEnd)
        self.keepsDisksAwake = defaults.bool(forKey: Keys.keepsDisksAwake)
        self.preventsSystemSleepOnAC = defaults.bool(forKey: Keys.preventsSystemSleepOnAC)
        self.wakeScreenOnStart = defaults.bool(forKey: Keys.wakeScreenOnStart)
        self.timerStartsOnLidClose = defaults.bool(forKey: Keys.timerStartsOnLidClose)
    }

    private func persist(_ value: Bool, key: String) {
        defaults.set(value, forKey: key)
    }
}
