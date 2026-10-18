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
    @Published private(set) var isWaitingForLidClose = false
    @Published private(set) var isCustomTimerSelected: Bool
    @Published private(set) var customTimerMinutesText: String
    @Published private(set) var customTimerInputError: String?
    @Published private(set) var isDisplaySleepActionInProgress = false
    @Published private(set) var displaySleepError: String?
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
    let preferences: CoffeePreferences
    let notifications: CoffeeNotifications

    private static let keepsScreenOnKey = "MacCoffee.keepScreenOn"
    private let defaults: UserDefaults
    private var caffeinateProcess: Process?
    private var wakeScreenProcess: Process?
    private var displaySleepProcess: Process?
    private var displaySleepRequestID: UUID?
    private var displaySleepContinuation: CheckedContinuation<String?, Never>?
    private var sessionTask: Task<Void, Never>?
    private var operationID: UUID?
    private var sessionStartsTimerOnLidClose = false
    private var sessionStopsOnBattery = false
    private var sessionKeepsDisksAwake = false
    private var sessionPreventsSystemSleepOnAC = false
    private var timerNotificationSent = false
    private var sessionNotifyOnTimerEnd = false
    private var lastPowerSource: CoffeePowerSource = .unknown

    init(
        isPreview: Bool = false,
        defaults: UserDefaults = .standard,
        preferences: CoffeePreferences? = nil,
        notifications: CoffeeNotifications? = nil
    ) {
        self.isPreview = isPreview
        self.defaults = defaults
        self.preferences = preferences ?? .shared
        self.notifications = notifications ?? CoffeeNotifications()
        self.keepsScreenOn = defaults.bool(forKey: Self.keepsScreenOnKey)
        self.lidStateAvailable = LidAwakeCapability.clamshellStateAvailable()
        self.lidAwakeController = LidAwakeController(isPreview: isPreview)
        let loadedDuration = lidAwakeController.duration
        self.isCustomTimerSelected = !LidAwakeDuration.allCases.contains(loadedDuration)
        self.customTimerMinutesText = String(loadedDuration.minutes ?? 60)
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
            guard !isDisplaySleepActionInProgress else { return }
            if isCustomTimerSelected, customTimerInputError != nil {
                sessionStatus = .error(customTimerInputError ?? "Enter a valid timer from 1 to 1,440 minutes.")
                return
            }
            Task { _ = await beginSession() }
        } else {
            Task { await endSession() }
        }
    }

    func setKeepsScreenOn(_ enabled: Bool) {
        guard keepsScreenOn != enabled, !isDisplaySleepActionInProgress else { return }
        keepsScreenOn = enabled
    }

    /// Starts or preserves the selected awake session, removes its display
    /// assertion, then requests sleep for the display only.
    @discardableResult
    func keepAwakeScreenOffNow() async -> Bool {
        guard !isPreview, !isBusy, !isDisplaySleepActionInProgress else { return false }
        if !isEnabled, isCustomTimerSelected, customTimerInputError != nil {
            sessionStatus = .error(customTimerInputError ?? "Enter a valid timer from 1 to 1,440 minutes.")
            return false
        }

        isDisplaySleepActionInProgress = true
        displaySleepError = nil
        defer { isDisplaySleepActionInProgress = false }
        stopOwnedWakeScreenPulse()

        if isEnabled {
            guard hasConfirmedAwakeSession else { return false }
            if keepsScreenOn { keepsScreenOn = false }
        } else {
            guard await beginSession(wakeScreenOnExplicitStart: false, keepsScreenOnOverride: false) else {
                return false
            }
        }

        guard hasConfirmedAwakeSession,
              deadline.map({ $0 > Date() }) ?? true else {
            return false
        }

        let error = await requestDisplaySleep()
        guard hasConfirmedAwakeSession else { return false }
        displaySleepError = error
        return error == nil
    }

    private var hasConfirmedAwakeSession: Bool {
        guard isEnabled, case .active = sessionStatus, caffeinateProcess?.isRunning == true else { return false }
        if lidStateAvailable {
            guard case .active = lidAwakeController.status else { return false }
        }
        return true
    }

    func selectTimerPreset(_ duration: LidAwakeDuration) {
        guard !isEnabled, !isBusy, LidAwakeDuration.allCases.contains(duration) else { return }
        isCustomTimerSelected = false
        customTimerInputError = nil
        customTimerMinutesText = String(duration.minutes ?? 60)
        lidAwakeController.duration = duration
    }

    func selectCustomTimer() {
        guard !isEnabled, !isBusy else { return }
        isCustomTimerSelected = true
        validateCustomTimer()
    }

    func updateCustomTimerMinutes(_ text: String) {
        guard !isEnabled, !isBusy else { return }
        customTimerMinutesText = text
        isCustomTimerSelected = true
        validateCustomTimer()
    }

    private func validateCustomTimer() {
        guard
            let minutes = Int(customTimerMinutesText),
            (1...1_440).contains(minutes),
            let duration = LidAwakeDuration(minutes: minutes)
        else {
            customTimerInputError = "Enter a whole number from 1 to 1,440 minutes."
            return
        }
        customTimerInputError = nil
        lidAwakeController.duration = duration
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
        cancelDisplaySleepRequest()
        displaySleepError = nil
        stopOwnedCaffeinate()
        stopOwnedWakeScreenPulse()
        if !isPreview { lidAwakeController.stopForApplicationShutdown() }
    }

    private func beginSession(
        wakeScreenOnExplicitStart: Bool = true,
        keepsScreenOnOverride: Bool? = nil
    ) async -> Bool {
        guard !isPreview, !isBusy, !isEnabled else { return false }
        isBusy = true
        displaySleepError = nil
        sessionStatus = .starting
        let requestedID = UUID()
        operationID = requestedID
        defer { if operationID == requestedID { isBusy = false } }

        sessionStopsOnBattery = preferences.stopOnBattery
        sessionStartsTimerOnLidClose = lidStateAvailable
            && preferences.timerStartsOnLidClose
            && timerDuration.seconds != nil
        sessionKeepsDisksAwake = preferences.keepsDisksAwake
        sessionPreventsSystemSleepOnAC = preferences.preventsSystemSleepOnAC
        timerNotificationSent = false
        sessionNotifyOnTimerEnd = preferences.notifyOnTimerEnd
        lastPowerSource = CoffeePowerSource.current()
        if sessionStopsOnBattery, lastPowerSource == .battery {
            sessionStatus = .error("Mac Coffee is set to stop on battery. Connect power before starting an awake session.")
            clearSessionOptions()
            return false
        }

        var helperStarted = false
        if lidStateAvailable {
            await lidAwakeController.refreshStatusAndWait()
            guard operationID == requestedID else { return false }
            guard lidAwakeController.setupStatus == .enabled else {
                let detail = lidAwakeController.setupStatus.detail
                sessionStatus = .error("Set up lid-closed sleep support first: \(detail)")
                clearSessionOptions()
                return false
            }
            guard case .off = lidAwakeController.status else {
                let detail = lidAwakeController.status.detail
                sessionStatus = .error("The lid-awake helper is not ready: \(detail)")
                clearSessionOptions()
                return false
            }
            guard await lidAwakeController.startAndWait(
                startOnLidClose: sessionStartsTimerOnLidClose,
                stopOnBattery: sessionStopsOnBattery
            ) else {
                guard operationID == requestedID else { return false }
                sessionStatus = .error("Could not start the lid-awake helper. Check its setup status and try again.")
                clearSessionOptions()
                return false
            }
            helperStarted = true
            if sessionStartsTimerOnLidClose {
                deadline = lidAwakeController.deadline
            } else {
                deadline = lidAwakeController.deadline
                    ?? AwakeDeadline.make(startedAt: Date(), duration: timerDuration)
            }
        } else {
            deadline = AwakeDeadline.make(startedAt: Date(), duration: timerDuration)
        }

        guard operationID == requestedID else {
            if helperStarted { _ = await lidAwakeController.stopAndWait() }
            clearSessionOptions()
            return false
        }

        if let launchError = launchCaffeinate(
            until: deadline,
            wakeScreenOnExplicitStart: wakeScreenOnExplicitStart,
            keepsDisplayOn: keepsScreenOnOverride ?? keepsScreenOn
        ) {
            if helperStarted { _ = await lidAwakeController.stopAndWait() }
            deadline = nil
            remaining = nil
            sessionStatus = .error(launchError)
            clearSessionOptions()
            return false
        }

        if let keepsScreenOnOverride { keepsScreenOn = keepsScreenOnOverride }
        isEnabled = true
        sessionStatus = .active
        updateWaitingForLidClose()
        updateRemaining()
        startSessionMonitor()
        return true
    }

    private func endSession() async {
        guard !isPreview, !isBusy else { return }
        cancelDisplaySleepRequest()
        displaySleepError = nil
        isBusy = true
        operationID = UUID()
        sessionTask?.cancel()
        sessionTask = nil
        isEnabled = false
        isWaitingForLidClose = false
        sessionStatus = .stopping
        stopOwnedCaffeinate()
        stopOwnedWakeScreenPulse()

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
        clearSessionOptions()
    }

    private func launchCaffeinate(
        until deadline: Date?,
        wakeScreenOnExplicitStart: Bool,
        keepsDisplayOn: Bool? = nil
    ) -> String? {
        if let deadline, deadline <= Date() {
            return "The timer expired before the awake assertion could start. Choose a new timer and try again."
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CaffeinateCommand.executablePath)
        let timeout = deadline.map { AwakeDeadline.timeoutSeconds(until: $0) }
        task.arguments = CaffeinateCommand.arguments(
            ownerPID: ProcessInfo.processInfo.processIdentifier,
            keepsDisplayOn: keepsDisplayOn ?? keepsScreenOn,
            timeoutSeconds: timeout,
            keepsDisksAwake: sessionKeepsDisksAwake,
            preventsSystemSleepOnAC: sessionPreventsSystemSleepOnAC
                && CoffeePowerSource.current() == .ac
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
            if wakeScreenOnExplicitStart {
                startWakeScreenPulseIfAllowed()
            }
            return nil
        } catch {
            return "Could not start /usr/bin/caffeinate: \(error.localizedDescription)"
        }
    }

    private func startWakeScreenPulseIfAllowed() {
        let lidIsOpenOrUnavailable = !lidStateAvailable
            || LidAwakeCapability.clamshellIsClosed() == false
        guard preferences.wakeScreenOnStart, lidIsOpenOrUnavailable else { return }
        stopOwnedWakeScreenPulse()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CaffeinateCommand.executablePath)
        process.arguments = CaffeinateCommand.wakeScreenPulseArguments(
            ownerPID: ProcessInfo.processInfo.processIdentifier
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            wakeScreenProcess = process
        } catch {
            // The user-activity pulse is optional; the keep-awake session remains active.
        }
    }

    private func restartCaffeinatePreservingDeadline() {
        guard isEnabled else { return }
        if let deadline, deadline <= Date() {
            Task { await expireSession() }
            return
        }
        stopOwnedCaffeinate()
        if let error = launchCaffeinate(until: deadline, wakeScreenOnExplicitStart: false) {
            Task { await failSession(error) }
        }
    }

    private func requestDisplaySleep() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DisplaySleepCommand.executablePath)
        process.arguments = DisplaySleepCommand.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            displaySleepRequestID = requestID
            displaySleepContinuation = continuation
            process.terminationHandler = { [weak self] terminated in
                let status = terminated.terminationStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let error = status == 0
                        ? nil
                        : "The display could not be turned off (pmset exited with status \(status)). Your awake session is still on."
                    self.finishDisplaySleepRequest(requestID, error: error)
                }
            }
            do {
                try process.run()
                displaySleepProcess = process
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                    catch { return }
                    self?.finishDisplaySleepRequest(
                        requestID,
                        error: "The display sleep request timed out. Your awake session is still on.",
                        terminateProcess: true
                    )
                }
            } catch {
                finishDisplaySleepRequest(
                    requestID,
                    error: "The display could not be turned off: \(error.localizedDescription). Your awake session is still on."
                )
            }
        }
    }

    private func finishDisplaySleepRequest(
        _ requestID: UUID,
        error: String?,
        terminateProcess: Bool = false
    ) {
        guard displaySleepRequestID == requestID else { return }
        displaySleepRequestID = nil
        let process = displaySleepProcess
        displaySleepProcess = nil
        if terminateProcess, let process, process.isRunning {
            process.terminate()
        }
        let continuation = displaySleepContinuation
        displaySleepContinuation = nil
        continuation?.resume(returning: error)
    }

    private func cancelDisplaySleepRequest() {
        guard let requestID = displaySleepRequestID else { return }
        finishDisplaySleepRequest(requestID, error: nil, terminateProcess: true)
    }

    private func stopOwnedCaffeinate() {
        guard let process = caffeinateProcess else { return }
        caffeinateProcess = nil
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    private func stopOwnedWakeScreenPulse() {
        guard let process = wakeScreenProcess else { return }
        wakeScreenProcess = nil
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
                self.synchronizeHelperDeadline()
                self.updateRemaining()
                if let deadline = self.deadline, deadline <= Date() {
                    self.sessionTask = nil
                    await self.expireSession()
                    return
                }

                let currentPower = CoffeePowerSource.current()
                if self.sessionStopsOnBattery && currentPower == .battery {
                    self.sessionTask = nil
                    await self.endSession()
                    return
                }
                if currentPower != self.lastPowerSource {
                    let previousPower = self.lastPowerSource
                    self.lastPowerSource = currentPower
                    if self.sessionPreventsSystemSleepOnAC,
                       previousPower == .ac || currentPower == .ac {
                        self.restartCaffeinatePreservingDeadline()
                    }
                }

                if self.lidStateAvailable {
                    switch self.lidAwakeController.status {
                    case .error(let detail), .unavailable(let detail):
                        self.sessionTask = nil
                        await self.failSession("The lid-awake helper stopped: \(detail)")
                        return
                    case .off:
                        if self.sessionStopsOnBattery && CoffeePowerSource.current() == .battery {
                            self.sessionTask = nil
                            await self.endSession()
                        } else {
                            self.sessionTask = nil
                            await self.failSession("The lid-awake helper stopped before the timer expired.")
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

    private func synchronizeHelperDeadline() {
        guard sessionStartsTimerOnLidClose,
              deadline == nil,
              let helperDeadline = lidAwakeController.deadline else {
            updateWaitingForLidClose()
            return
        }
        deadline = helperDeadline
        updateWaitingForLidClose()
        updateRemaining()
        restartCaffeinatePreservingDeadline()
    }

    private func updateWaitingForLidClose() {
        isWaitingForLidClose = isEnabled && sessionStartsTimerOnLidClose && deadline == nil
    }

    private func updateRemaining() {
        guard let deadline else {
            remaining = nil
            return
        }
        remaining = AwakeDeadline.remaining(until: deadline)
    }

    /// The helper owns its deadline and closed-lid sleep transition. At expiry
    /// the app stops caffeinate and lets the helper finish its own recovery.
    private func expireSession() async {
        guard isEnabled else { return }
        cancelDisplaySleepRequest()
        displaySleepError = nil
        if sessionStopsOnBattery && CoffeePowerSource.current() == .battery {
            await endSession()
            return
        }
        let shouldNotify = deadline != nil
        sessionTask?.cancel()
        sessionTask = nil
        isEnabled = false
        isWaitingForLidClose = false
        isBusy = true
        sessionStatus = .stopping
        stopOwnedCaffeinate()
        stopOwnedWakeScreenPulse()

        if lidStateAvailable {
            let finishBy = Date().addingTimeInterval(12)
            while Date() < finishBy {
                switch lidAwakeController.status {
                case .off:
                    deadline = nil
                    remaining = nil
                    isBusy = false
                    sessionStatus = .off
                    clearSessionOptions()
                    await notifyTimerFinishedIfNeeded(shouldNotify)
                    return
                case .error(let detail), .unavailable(let detail):
                    deadline = nil
                    remaining = nil
                    isBusy = false
                    sessionStatus = .error("The timer expired, but the helper reported a restore problem: \(detail)")
                    clearSessionOptions()
                    return
                case .starting, .active, .stopping:
                    break
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { break }
            }
            deadline = nil
            remaining = nil
            isBusy = false
            sessionStatus = .error("The timer expired, but Mac Coffee did not receive confirmation that normal sleep behavior was restored. Check lid support status.")
            clearSessionOptions()
            return
        }

        deadline = nil
        remaining = nil
        isBusy = false
        sessionStatus = .off
        clearSessionOptions()
        await notifyTimerFinishedIfNeeded(shouldNotify)
    }

    private func notifyTimerFinishedIfNeeded(_ shouldNotify: Bool) async {
        guard shouldNotify,
              sessionNotifyOnTimerEnd,
              !timerNotificationSent else { return }
        timerNotificationSent = true
        await notifications.timerFinished()
    }

    private func failSession(_ message: String) async {
        guard isEnabled else { return }
        cancelDisplaySleepRequest()
        displaySleepError = nil
        operationID = UUID()
        sessionTask?.cancel()
        sessionTask = nil
        isBusy = true
        isEnabled = false
        isWaitingForLidClose = false
        sessionStatus = .stopping
        stopOwnedCaffeinate()
        stopOwnedWakeScreenPulse()
        if lidStateAvailable {
            if case .active = lidAwakeController.status {
                _ = await lidAwakeController.stopAndWait()
            }
        }
        deadline = nil
        remaining = nil
        isBusy = false
        sessionStatus = .error(message)
        clearSessionOptions()
    }

    private func clearSessionOptions() {
        sessionStartsTimerOnLidClose = false
        sessionStopsOnBattery = false
        sessionKeepsDisksAwake = false
        sessionPreventsSystemSleepOnAC = false
        sessionNotifyOnTimerEnd = false
        lastPowerSource = .unknown
    }
}
