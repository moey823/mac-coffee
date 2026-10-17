import SwiftUI
import MacCoffeeCore

struct MacCoffeeMenuView: View {
    @ObservedObject var state: CoffeeState
    @ObservedObject var lidController: LidAwakeController

    init(state: CoffeeState) {
        self.state = state
        self.lidController = state.lidAwakeController
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            awakeCard
            controlsCard

            if state.lidStateAvailable {
                lidSupportSection
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit Mac Coffee") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(15)
        .frame(width: 336, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(red: 0.48, green: 0.27, blue: 0.15))
                .accessibilityHidden(true)
            Text("Mac Coffee")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var awakeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep awake")
                        .font(.headline)
                    Text("Keep this Mac awake")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("Keep awake", isOn: Binding(
                    get: { state.isEnabled },
                    set: { state.setEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Keep awake")
                .disabled(state.isBusy)
            }

            Divider()

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 18, alignment: .center)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.sessionStatus.title)
                        .font(.subheadline.weight(.semibold))
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                if let remaining = state.remaining {
                    Text(Self.formatRemaining(remaining))
                        .monospacedDigit()
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .frame(width: 58, alignment: .trailing)
                        .accessibilityLabel("\(Self.spokenRemaining(remaining)) remaining")
                } else if state.isEnabled {
                    Text("Until stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep screen on")
                        .font(.subheadline.weight(.medium))
                    Text("Only while Keep awake is on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle("Keep screen on", isOn: Binding(
                    get: { state.keepsScreenOn },
                    set: { state.setKeepsScreenOn($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Keep the display awake only during an active session.")
                .disabled(state.isBusy)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Timer")
                        .font(.subheadline.weight(.medium))
                    Text(state.isEnabled ? "Stop the session to change it" : "Session length")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker("Timer", selection: Binding(
                    get: { lidController.duration },
                    set: { lidController.duration = $0 }
                )) {
                    ForEach(LidAwakeDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(state.isEnabled || state.isBusy)
                .help(state.isEnabled ? "Stop the session before changing its timer." : "Choose how long to stay awake.")
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
                helperAttention(
                    title: "Lid support needs attention",
                    detail: detail,
                    symbol: "exclamationmark.triangle.fill",
                    buttons: [
                        HelperAction(title: "Repair", action: state.repairHelper),
                        HelperAction(title: "Login Items", action: state.openLoginItemsSettings)
                    ]
                )
            case .off, .starting, .active, .stopping:
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Lid-closed support ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        state.refreshHelperStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Refresh lid-support status")
                    .accessibilityLabel("Refresh lid-support status")
                    .disabled(state.isBusy)
                }
                .padding(.horizontal, 2)
            }
        case .notRegistered:
            helperAttention(
                title: "Set up lid-closed support",
                detail: "Register the helper, then approve it in System Settings.",
                symbol: "laptopcomputer",
                buttons: [HelperAction(title: "Register helper", action: state.registerHelper)]
            )
        case .requiresApproval:
            helperAttention(
                title: "Approval needed",
                detail: lidController.setupStatus.detail,
                symbol: "lock.fill",
                buttons: [HelperAction(title: "Open Login Items", action: state.openLoginItemsSettings)]
            )
        case .error(let detail):
            helperAttention(
                title: "Lid support needs attention",
                detail: detail,
                symbol: "exclamationmark.triangle.fill",
                buttons: [
                    HelperAction(title: "Repair", action: state.repairHelper),
                    HelperAction(title: "Login Items", action: state.openLoginItemsSettings)
                ]
            )
        }
    }

    private func helperAttention(
        title: String,
        detail: String,
        symbol: String,
        buttons: [HelperAction]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(symbol == "exclamationmark.triangle.fill" ? Color.orange : Color.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(buttons) { item in
                    Button(item.title, action: item.action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(state.isBusy)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }

    private var statusSymbol: String {
        switch state.sessionStatus {
        case .off: "moon.zzz"
        case .starting: "hourglass"
        case .active: "cup.and.saucer.fill"
        case .stopping: "arrow.uturn.backward.circle"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch state.sessionStatus {
        case .off, .starting, .stopping: .secondary
        case .active: Color(red: 0.29, green: 0.53, blue: 0.37)
        case .error: .orange
        }
    }

    private var statusDescription: String {
        switch state.sessionStatus {
        case .active:
            state.remaining == nil ? "Awake until stopped." : "Your Mac can sleep when the timer ends."
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
        if hours == 0 {
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        if extraMinutes == 0 {
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "\(hours) \(hours == 1 ? "hour" : "hours") and \(extraMinutes) \(extraMinutes == 1 ? "minute" : "minutes")"
    }
}

private struct HelperAction: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
}
