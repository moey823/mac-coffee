import SwiftUI
import MacCoffeeCore

struct MacCoffeeMenuView: View {
    @ObservedObject var state: CoffeeState
    @ObservedObject var lidController: LidAwakeController
    @ObservedObject var preferences: CoffeePreferences
    @ObservedObject var loginItem: CoffeeLoginItem
    @ObservedObject var shortcut: CoffeeShortcut
    @ObservedObject var notifications: CoffeeNotifications
    @State private var showingSettings = false
    @State private var showingAdvanced = false
    @State private var requestingNotifications = false

    init(state: CoffeeState, loginItem: CoffeeLoginItem, shortcut: CoffeeShortcut) {
        self.state = state
        self.lidController = state.lidAwakeController
        self.preferences = state.preferences
        self.notifications = state.notifications
        self.loginItem = loginItem
        self.shortcut = shortcut
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                header
                if showingSettings { settingsPage } else { mainPage }
            }
            .padding(15)
        }
        .frame(width: 336)
        .frame(maxHeight: 500)
        .onAppear(perform: prepareSettings)
    }

    private var header: some View {
        HStack(spacing: 9) {
            if showingSettings {
                Button { showingSettings = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Mac Coffee")
            } else {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(red: 0.48, green: 0.27, blue: 0.15))
                    .accessibilityHidden(true)
            }
            Text(showingSettings ? "Settings" : "Mac Coffee").font(.title3.weight(.semibold))
            Spacer()
            if showingSettings {
                Button("Done") { showingSettings = false }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help("Mac Coffee settings")
                .accessibilityLabel("Mac Coffee settings")
            }
        }
        .padding(.bottom, 2)
    }

    private var mainPage: some View {
        Group {
            awakeCard
            controlsCard
            if state.lidStateAvailable { lidSupportSection }
            Divider()
            HStack {
                Spacer()
                Button("Quit Mac Coffee") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Optional behavior").font(.caption).foregroundStyle(.secondary)
            settingsToggle("Open at login", detail: "The awake session always starts off.",
                           isOn: loginItem.isEnabled, disabled: false) { enabled in
                loginItem.setEnabled(enabled)
                preferences.startAtLogin = loginItem.isEnabled
            }
            if let message = loginItem.errorMessage {
                settingsError(message)
                if loginItem.needsApproval {
                    Button("Open Login Items settings") { state.openLoginItemsSettings() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Divider()
            settingsToggle("Global shortcut", detail: "Command-Option-C toggles Keep awake.",
                           isOn: preferences.shortcutEnabled, disabled: false) { enabled in
                if enabled {
                    if shortcut.register(action: { state.setEnabled(!state.isEnabled) }) {
                        preferences.shortcutEnabled = true
                    }
                } else if shortcut.unregister() {
                    preferences.shortcutEnabled = false
                }
            }
            if let message = shortcut.errorMessage { settingsError(message) }

            settingsToggle("Stop on battery", detail: "End the session when this Mac is unplugged.",
                           isOn: preferences.stopOnBattery, disabled: sessionSettingsLocked) {
                preferences.stopOnBattery = $0
            }
            settingsToggle("Notify when timer ends", detail: "Requires notification permission.",
                           isOn: preferences.notifyOnTimerEnd,
                           disabled: sessionSettingsLocked || requestingNotifications) { enabled in
                guard !requestingNotifications else { return }
                if enabled {
                    requestingNotifications = true
                    Task {
                        let granted = await notifications.requestAuthorizationAfterUserOptIn()
                        preferences.notifyOnTimerEnd = granted
                        requestingNotifications = false
                    }
                } else {
                    preferences.notifyOnTimerEnd = false
                }
            }
            if let message = notifications.errorMessage { settingsError(message) }

            DisclosureGroup("Advanced", isExpanded: $showingAdvanced) {
                VStack(alignment: .leading, spacing: 11) {
                    settingsToggle("Keep disks awake", detail: "Prevent idle disk sleep during a session.",
                                   isOn: preferences.keepsDisksAwake, disabled: sessionSettingsLocked) {
                        preferences.keepsDisksAwake = $0
                    }
                    settingsToggle("Prevent system sleep on AC", detail: "Prevent sleep while connected to power.",
                                   isOn: preferences.preventsSystemSleepOnAC, disabled: sessionSettingsLocked) {
                        preferences.preventsSystemSleepOnAC = $0
                    }
                    settingsToggle("Wake display when starting", detail: "Briefly wake the display when a session starts.",
                                   isOn: preferences.wakeScreenOnStart, disabled: sessionSettingsLocked) {
                        preferences.wakeScreenOnStart = $0
                    }
                    settingsToggle("Start timer when lid closes",
                                   detail: state.lidStateAvailable
                                       ? "The awake session starts now; its timer starts at the first lid close."
                                       : "Available on Macs with lid-closed support.",
                                   isOn: preferences.timerStartsOnLidClose,
                                   disabled: !state.lidStateAvailable || sessionSettingsLocked) {
                        preferences.timerStartsOnLidClose = $0
                    }
                }
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.medium))
            .disabled(sessionSettingsLocked)
            if sessionSettingsLocked {
                Text("Stop the awake session to change session settings.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit Mac Coffee") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }

    private var sessionSettingsLocked: Bool { state.isEnabled || state.isBusy }

    private var awakeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep awake").font(.headline)
                    Text("Keep this Mac awake").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("Keep awake", isOn: Binding(get: { state.isEnabled }, set: { state.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).accessibilityLabel("Keep awake")
                    .disabled(state.isBusy)
            }
            Divider()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: statusSymbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor).frame(width: 18).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.subheadline.weight(.semibold))
                    Text(statusDescription).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if let remaining = state.remaining {
                    Text(Self.formatRemaining(remaining)).monospacedDigit()
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .frame(width: 58, alignment: .trailing)
                        .accessibilityLabel("\(Self.spokenRemaining(remaining)) remaining")
                } else if state.isEnabled && !state.isWaitingForLidClose {
                    Text("Until stopped").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep screen on").font(.subheadline.weight(.medium))
                    Text("Only while Keep awake is on").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("Keep screen on", isOn: Binding(get: { state.keepsScreenOn },
                                                      set: { state.setKeepsScreenOn($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel("Keep screen on")
                    .help("Keep the display awake only during an active session.")
                    .disabled(state.isBusy)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timer").font(.subheadline.weight(.medium))
                    Text(timerCaption)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Timer", selection: timerSelection) {
                    ForEach(LidAwakeDuration.allCases) { duration in
                        Text(duration.title).tag(TimerSelection.preset(duration))
                    }
                    Text("Custom...").tag(TimerSelection.custom)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                .disabled(state.isEnabled || state.isBusy)
                .help(state.isEnabled ? "Stop the session before changing its timer." : "Choose how long to stay awake.")
            }
            if state.isCustomTimerSelected {
                HStack {
                    Text("Minutes").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("1-1,440", text: Binding(get: { state.customTimerMinutesText },
                                                       set: { state.updateCustomTimerMinutes($0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 92)
                        .multilineTextAlignment(.trailing)
                        .disabled(state.isEnabled || state.isBusy)
                        .accessibilityLabel("Custom timer in minutes")
                }
                if let error = state.customTimerInputError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private var lidSupportSection: some View {
        switch lidController.setupStatus {
        case .enabled:
            switch lidController.status {
            case .error(let detail), .unavailable(let detail):
                helperAttention(title: "Lid support needs attention", detail: detail,
                                symbol: "exclamationmark.triangle.fill",
                                buttons: [
                                    HelperAction(title: "Repair", action: state.repairHelper),
                                    HelperAction(title: "Login Items", action: state.openLoginItemsSettings)
                                ])
            case .off, .starting, .active, .stopping:
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text("Lid-closed support ready").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { state.refreshHelperStatus() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).controlSize(.small).help("Refresh lid-support status")
                        .accessibilityLabel("Refresh lid-support status").disabled(state.isBusy)
                }
                .padding(.horizontal, 2)
            }
        case .notRegistered:
            helperAttention(title: "Set up lid-closed support",
                            detail: "Register the helper, then approve it in System Settings.",
                            symbol: "laptopcomputer",
                            buttons: [HelperAction(title: "Register helper", action: state.registerHelper)])
        case .requiresApproval:
            helperAttention(title: "Approval needed", detail: lidController.setupStatus.detail,
                            symbol: "lock.fill",
                            buttons: [HelperAction(title: "Open Login Items", action: state.openLoginItemsSettings)])
        case .error(let detail):
            helperAttention(title: "Lid support needs attention", detail: detail,
                            symbol: "exclamationmark.triangle.fill",
                            buttons: [
                                HelperAction(title: "Repair", action: state.repairHelper),
                                HelperAction(title: "Login Items", action: state.openLoginItemsSettings)
                            ])
        }
    }

    private func helperAttention(title: String, detail: String, symbol: String, buttons: [HelperAction]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(symbol == "exclamationmark.triangle.fill" ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(title).font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(buttons) { item in
                    Button(item.title, action: item.action).buttonStyle(.bordered).controlSize(.small)
                        .disabled(state.isBusy)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private func settingsToggle(_ title: String, detail: String, isOn: Bool, disabled: Bool,
                                action: @escaping (Bool) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer(minLength: 12)
                Toggle(title, isOn: Binding(get: { isOn }, set: action))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(title).disabled(disabled)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func prepareSettings() {
        loginItem.refreshStatus()
        preferences.startAtLogin = loginItem.isEnabled
        Task { await notifications.refreshAuthorizationStatus() }
    }

    private var timerSelection: Binding<TimerSelection> {
        Binding(get: {
            state.isCustomTimerSelected ? .custom : .preset(lidController.duration)
        }, set: {
            switch $0 {
            case .preset(let duration): state.selectTimerPreset(duration)
            case .custom: state.selectCustomTimer()
            }
        })
    }

    private var timerCaption: String {
        if state.isEnabled { return "Stop the session to change it" }
        if state.lidStateAvailable, preferences.timerStartsOnLidClose, lidController.duration.seconds != nil {
            return "Starts when lid closes"
        }
        return "Session length"
    }

    private var statusTitle: String {
        state.isWaitingForLidClose ? "Waiting for lid to close" : state.sessionStatus.title
    }

    private var statusSymbol: String {
        if state.isWaitingForLidClose { return "hourglass" }
        return switch state.sessionStatus {
        case .off: "moon.zzz"
        case .starting: "hourglass"
        case .active: "cup.and.saucer.fill"
        case .stopping: "arrow.uturn.backward.circle"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        if state.isWaitingForLidClose { return .orange }
        return switch state.sessionStatus {
        case .off, .starting, .stopping: .secondary
        case .active: Color(red: 0.29, green: 0.53, blue: 0.37)
        case .error: .orange
        }
    }

    private var statusDescription: String {
        if state.isWaitingForLidClose { return "Timer starts when the lid closes." }
        return switch state.sessionStatus {
        case .active:
            state.remaining == nil ? "Awake until stopped." : "Normal sleep resumes when the timer ends."
        default:
            state.sessionStatus.detail
        }
    }

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func spokenRemaining(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(ceil(seconds / 60)))
        let hours = minutes / 60
        let extraMinutes = minutes % 60
        if hours == 0 { return "\(minutes) \(minutes == 1 ? "minute" : "minutes")" }
        if extraMinutes == 0 { return "\(hours) \(hours == 1 ? "hour" : "hours")" }
        return "\(hours) \(hours == 1 ? "hour" : "hours") and \(extraMinutes) \(extraMinutes == 1 ? "minute" : "minutes")"
    }
}

private enum TimerSelection: Hashable {
    case preset(LidAwakeDuration)
    case custom
}

private struct HelperAction: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}
