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
        VStack(alignment: .leading, spacing: 14) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { state.isEnabled },
                        set: { state.setEnabled($0) }
                    )) {
                        Label("Keep awake", systemImage: "cup.and.saucer.fill")
                            .font(.headline)
                    }
                    .disabled(state.isBusy)

                    HStack {
                        Text(state.sessionStatus.title)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if let remaining = state.remaining {
                            Text(Self.formatRemaining(remaining))
                                .monospacedDigit()
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(state.sessionStatus.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: Binding(
                get: { state.keepsScreenOn },
                set: { state.setKeepsScreenOn($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep screen on")
                    Text("Only applies while Keep awake is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(state.isBusy)

            HStack {
                Text("Stop after")
                Spacer()
                Picker("Stop after", selection: Binding(
                    get: { lidController.duration },
                    set: { lidController.duration = $0 }
                )) {
                    ForEach(LidAwakeDuration.allCases) { duration in
                        Text(duration.title).tag(duration)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(state.isEnabled || state.isBusy)
            }

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
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color(red: 0.48, green: 0.27, blue: 0.15))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac Coffee")
                    .font(.title3.weight(.semibold))
                Text("A little help staying awake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var lidSupportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Lid-closed sleep support")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(lidController.setupStatus.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(lidController.setupStatus.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                switch lidController.setupStatus {
                case .notRegistered:
                    Button("Register helper") { state.registerHelper() }
                case .requiresApproval:
                    Button("Open Login Items") { state.openLoginItemsSettings() }
                case .enabled:
                    Button("Refresh status") { state.refreshHelperStatus() }
                case .error:
                    Button("Repair helper") { state.repairHelper() }
                    Button("Open Login Items") { state.openLoginItemsSettings() }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .disabled(state.isBusy)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
