import AppKit
import Combine
import Foundation
import MacCoffeeCore

enum CoffeeSessionStatus: Equatable {
    case off
    case starting
    case active
    case stopping
    case error(String)

    var title: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .active: "Keeping awake"
        case .stopping: "Stopping"
        case .error: "Needs attention"
        }
    }

    var detail: String {
        switch self {
        case .off: "Your Mac can sleep normally."
        case .starting: "Setting up the awake session."
        case .active: "Your Mac will stay awake for the selected time."
        case .stopping: "Restoring normal sleep behavior."
        case .error(let message): message
        }
    }
}

@MainActor
final class CoffeeState: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var sessionStatus: CoffeeSessionStatus = .off
    @Published private(set) var remaining: TimeInterval?
    @Published private(set) var deadline: Date?
    @Published private(set) var isBusy = false
    @Published var keepsScreenOn: Bool {
        didSet {
            guard keepsScreenOn != oldValue else { return }
            defaults.set(keepsScreenOn, forKey: Self.keepsScreenOnKey)
            guard isEnabled else { return }
            restartCaffeinatePreservingDeadline()
        }
    }

    let lidAwakeController: LidAwakeController
    let isPreview: Bool
    let lidStateAvailable: Bool

    private static let keepsScreenOnKey = "MacCoffee.keepScreenOn"
    private let defaults: UserDefaults
    private var caffeinateProcess: Process?
    private var sessionTask: Task<Void, Never>?
    private var operationID: UUID?

    init(isPreview: Bool = false, defaults: UserDefaults = .standard) {
        self.isPreview = isPreview
        self.defaults = defaults
        self.keepsScreenOn = defaults.bool(forKey: Self.keepsScreenOnKey)
        self.lidStateAvailable = LidAwakeCapability.clamshellStateAvailable()
        self.lidAwakeController = LidAwakeController(isPreview: isPreview)
    }

    var timerDuration: LidAwakeDuration { lidAwakeController.duration }

    func start() {
        guard !isPreview else { return }
        if lidStateAvailable {
            Task { await lidAwakeController.refreshStatusAndWait() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isPreview, !isBusy, enabled != isEnabled else { return }
        if enabled {
            Task { await beginSession() }
        } else {
            Task { await endSession() }
        }
    }

    func setKeepsScreenOn(_ enabled: Bool) {
        guard keepsScreenOn != enabled else { return }
        keepsScreenOn = enabled
    }

    func registerHelper() {
        guard !isPreview, lidStateAvailable, !isBusy else { return }
        lidAwakeController.registerHelper()
    }

    func repairHelper() {
        guard !isPreview, lidStateAvailable, !isBusy else { return }
        isBusy = true
        Task {
            _ = await lidAwakeController.repairHelper()
            isBusy = false
        }
    }

    func openLoginItemsSettings() {
        guard !isPreview else { return }
        lidAwakeController.openLoginItemsSettings()
    }

    func refreshHelperStatus() {
        guard !isPreview, lidStateAvailable else { return }
        Task { await lidAwakeController.refreshStatusAndWait() }
    }

    func applicationWillTerminate() {
        sessionTask?.cancel()
        sessionTask = nil
        isEnabled = false
        stopOwnedCaffeinate()
        if !isPreview { lidAwakeController.stopForApplicationShutdown() }
    }

    private func beginSession() async {
        guard !isPreview, !isBusy, !isEnabled else { return }
        isBusy = true
        sessionStatus = .starting
        operationID = UUID()
        let requestedID = operationID
        defer { if operationID == requestedID { isBusy = false } }

        var helperStarted = false
        if lidStateAvailable {
            await lidAwakeController.refreshStatusAndWait()
            guard operationID == requestedID else { return }
            guard lidAwakeController.setupStatus == .enabled else {
                let detail = lidAwakeController.setupStatus.detail
                sessionStatus = .error("Set up lid-closed sleep support first: \(detail)")
                return
            }
            guard case .off = lidAwakeController.status else {
                let detail = lidAwakeController.status.detail
                sessionStatus = .error("The lid-awake helper is not ready: \(detail)")
                return
            }
            guard await lidAwakeController.startAndWait() else {
                guard operationID == requestedID else { return }
                sessionStatus = .error("Could not start the lid-awake helper. Check its setup status and try again.")
                return
            }
            helperStarted = true
            deadline = lidAwakeController.deadline
                ?? AwakeDeadline.make(startedAt: Date(), duration: lidAwakeController.duration)
        } else {
            deadline = AwakeDeadline.make(startedAt: Date(), duration: lidAwakeController.duration)
        }

        guard operationID == requestedID else {
            if helperStarted { _ = await lidAwakeController.stopAndWait() }
            return
        }
        if let launchError = launchCaffeinate(until: deadline) {
            if helperStarted { _ = await lidAwakeController.stopAndWait() }
            deadline = nil
            remaining = nil
            sessionStatus = .error(launchError)
            return
        }

        isEnabled = true
        sessionStatus = .active
        updateRemaining()
        startSessionMonitor()
    }

    private func endSession() async {
        guard !isPreview, !isBusy else { return }
        isBusy = true
        operationID = UUID()
        sessionTask?.cancel()
        sessionTask = nil
        isEnabled = false
        sessionStatus = .stopping
        stopOwnedCaffeinate()

        var helperStopped = true
        if lidStateAvailable {
            switch lidAwakeController.status {
            case .active, .starting, .stopping:
                helperStopped = await lidAwakeController.stopAndWait()
            case .off:
                break
            case .unavailable, .error:
                helperStopped = false
            }
        }
        deadline = nil
        remaining = nil
        isBusy = false
        if helperStopped {
            sessionStatus = .off
        } else {
            sessionStatus = .error("Mac Coffee could not confirm that normal sleep behavior was restored. Check lid support status.")
        }
    }

    private func launchCaffeinate(until deadline: Date?) -> String? {
        if let deadline, deadline <= Date() {
            return "The timer expired before the awake assertion could start. Choose a new timer and try again."
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CaffeinateCommand.executablePath)
        let timeout = deadline.map { AwakeDeadline.timeoutSeconds(until: $0) }
        task.arguments = CaffeinateCommand.arguments(
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            keepsDisplayOn: keepsScreenOn,
            timeoutSeconds: timeout
        )
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.processDidTerminate(terminated) }
        }
        do {
            try task.run()
            guard task.isRunning else {
                return "caffeinate exited before Mac Coffee could confirm the awake assertion."
            }
            caffeinateProcess = task
            return nil
        } catch {
            return "Could not start /usr/bin/caffeinate: \(error.localizedDescription)"
        }
    }

    private func restartCaffeinatePreservingDeadline() {
        guard isEnabled else { return }
        if let deadline, deadline <= Date() {
            Task { await expireSession() }
            return
        }
        stopOwnedCaffeinate()
        if let error = launchCaffeinate(until: deadline) {
            Task { await failSession(error) }
        }
    }

    private func stopOwnedCaffeinate() {
        guard let process = caffeinateProcess else { return }
        caffeinateProcess = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func processDidTerminate(_ terminated: Process) {
        guard caffeinateProcess === terminated else { return }
        caffeinateProcess = nil
        guard isEnabled else { return }
        if let deadline, deadline <= Date() {
            Task { await expireSession() }
        } else {
            Task {
                await failSession("The caffeinate assertion ended unexpectedly. Turn Keep awake off, check the error, then try again.")
            }
        }
    }

    private func startSessionMonitor() {
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isEnabled {
                self.updateRemaining()
                if let deadline = self.deadline, deadline <= Date() {
                    self.sessionTask = nil
                    Task { @MainActor [weak self] in await self?.expireSession() }
                    return
                }
                if self.lidStateAvailable {
                    switch self.lidAwakeController.status {
                    case .error(let detail), .unavailable(let detail):
                        self.sessionTask = nil
                        Task { @MainActor [weak self] in
                            await self?.failSession("The lid-awake helper stopped: \(detail)")
                        }
                        return
                    case .off:
                        self.sessionTask = nil
                        Task { @MainActor [weak self] in
                            await self?.failSession("The lid-awake helper stopped before the timer expired.")
                        }
                        return
                    case .starting, .active, .stopping:
                        break
                    }
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }

    private func updateRemaining() {
        guard let deadline else {
            remaining = nil
            return
        }
        remaining = AwakeDeadline.remaining(until: deadline)
    }

    /// The helper owns its deadline and closed-lid sleep transition. At expiry
    /// the app stops caffeinate, then lets the helper finish its own recovery.
    private func expireSession() async {
        guard isEnabled else { return }
        sessionTask?.cancel()
        sessionTask = nil
        isEnabled = false
        isBusy = true
        sessionStatus = .stopping
        stopOwnedCaffeinate()

        if lidStateAvailable {
            let finishBy = Date().addingTimeInterval(12)
            while Date() < finishBy {
                switch lidAwakeController.status {
                case .off:
                    deadline = nil
                    remaining = nil
                    isBusy = false
                    sessionStatus = .off
                    return
                case .error(let detail), .unavailable(let detail):
                    deadline = nil
                    remaining = nil
                    isBusy = false
                    sessionStatus = .error("The timer expired, but the helper reported a restore problem: \(detail)")
                    return
                case .starting, .active, .stopping:
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            deadline = nil
            remaining = nil
            isBusy = false
            sessionStatus = .error("The timer expired, but Mac Coffee did not receive confirmation that normal sleep behavior was restored. Check lid support status.")
            return
        }

        deadline = nil
        remaining = nil
        isBusy = false
        sessionStatus = .off
    }

    private func failSession(_ message: String) async {
        guard isEnabled else { return }
        operationID = UUID()
        sessionTask?.cancel()
        sessionTask = nil
        isBusy = true
        isEnabled = false
        sessionStatus = .stopping
        stopOwnedCaffeinate()
        if lidStateAvailable {
            if case .active = lidAwakeController.status {
                _ = await lidAwakeController.stopAndWait()
            }
        }
        deadline = nil
        remaining = nil
        isBusy = false
        sessionStatus = .error(message)
    }
}
