import AppKit
import Combine
import SwiftUI
import MacCoffeeCore

@MainActor
final class MacCoffeeAppDelegate: NSObject, NSApplicationDelegate {
    private let state = CoffeeState()
    private let popover = NSPopover()
    private let showPopoverOnLaunch: Bool
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private static var statusItemWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        let labels = ["120:00", "Starting", "Stopping"]
        let titleWidth = labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 44
        // Reserve the widest two-hour countdown and transition labels so the next menu item never shifts.
        return ceil(titleWidth + 16 + 6 + 20)
    }

    init(showPopoverOnLaunch: Bool = false) {
        self.showPopoverOnLaunch = showPopoverOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        statusItem = item
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(rootView: MacCoffeeMenuView(state: state))
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.loadViewIfNeeded()
        popover.contentViewController = hostingController
        sizePopoverToContent(using: hostingController)
        bindState()
        state.start()

        if showPopoverOnLaunch {
            DispatchQueue.main.async { self.showPopover() }
        }
    }

    private func bindState() {
        state.$sessionStatus
            .combineLatest(state.$remaining, state.$keepsScreenOn)
            .map { values in
                let (status, remaining, keepsScreenOn) = values
                let menuState: CoffeeMenuBarState
                switch status {
                case .off: menuState = .off
                case .starting: menuState = .starting
                case .active: menuState = .active(remaining: remaining)
                case .stopping: menuState = .stopping
                case .error(let detail): menuState = .error(detail)
                }
                return CoffeeMenuBarPresentation.make(for: menuState, keepsScreenOn: keepsScreenOn)
            }
            .removeDuplicates()
            .sink { [weak self] presentation in
                self?.updateStatusItem(presentation)
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(_ presentation: CoffeeMenuBarPresentation) {
        guard let button = statusItem?.button else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityLabel
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        button.image = image
        button.attributedTitle = NSAttributedString(
            string: presentation.title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)]
        )
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    private func sizePopoverToContent(using hostingController: NSHostingController<MacCoffeeMenuView>) {
        let availableSize = NSSize(width: 336, height: 520)
        let fittedSize = hostingController.sizeThatFits(in: availableSize)
        guard fittedSize.height.isFinite, fittedSize.height > 0 else { return }
        let size = NSSize(width: 336, height: min(fittedSize.height, availableSize.height))
        hostingController.preferredContentSize = size
        popover.contentSize = size
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard statusItem?.button != nil else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if let hostingController = popover.contentViewController as? NSHostingController<MacCoffeeMenuView> {
            sizePopoverToContent(using: hostingController)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        state.applicationWillTerminate()
    }
}
