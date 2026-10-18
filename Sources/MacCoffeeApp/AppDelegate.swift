import AppKit
import Combine
import SwiftUI
import MacCoffeeCore

@MainActor
final class MacCoffeeAppDelegate: NSObject, NSApplicationDelegate {
    private let preferences: CoffeePreferences
    private let notifications: CoffeeNotifications
    private let loginItem = CoffeeLoginItem()
    private let shortcut = CoffeeShortcut()
    private let state: CoffeeState
    private let popover = NSPopover()
    private let showPopoverOnLaunch: Bool
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    init(showPopoverOnLaunch: Bool = false) {
        let preferences = CoffeePreferences.shared
        let notifications = CoffeeNotifications()
        self.preferences = preferences
        self.notifications = notifications
        self.state = CoffeeState(preferences: preferences, notifications: notifications)
        self.showPopoverOnLaunch = showPopoverOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.title = ""
            button.attributedTitle = NSAttributedString(string: "")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        let hostingController = NSHostingController(
            rootView: MacCoffeeMenuView(state: state, loginItem: loginItem, shortcut: shortcut)
        )
        hostingController.sizingOptions = [.preferredContentSize]
        hostingController.loadViewIfNeeded()
        popover.contentViewController = hostingController
        sizePopoverToContent(using: hostingController)
        bindState()
        state.start()

        loginItem.refreshStatus()
        preferences.startAtLogin = loginItem.isEnabled
        if preferences.shortcutEnabled {
            shortcut.register { [weak self] in
                guard let self else { return }
                self.state.setEnabled(!self.state.isEnabled)
            }
        }
        if showPopoverOnLaunch {
            DispatchQueue.main.async { self.showPopover() }
        }
    }

    private func bindState() {
        state.$sessionStatus
            .combineLatest(state.$remaining, state.$keepsScreenOn, state.$isWaitingForLidClose)
            .map { values in
                let (status, remaining, keepsScreenOn, waiting) = values
                let menuState: CoffeeMenuBarState
                if waiting {
                    menuState = .waitingForLidClose
                } else {
                    switch status {
                    case .off: menuState = .off
                    case .starting: menuState = .starting
                    case .active: menuState = .active(remaining: remaining)
                    case .stopping: menuState = .stopping
                    case .error(let detail): menuState = .error(detail)
                    }
                }
                return CoffeeMenuBarPresentation.make(for: menuState, keepsScreenOn: keepsScreenOn)
            }
            .removeDuplicates()
            .sink { [weak self] in self?.updateStatusItem($0) }
            .store(in: &cancellables)
    }

    private func updateStatusItem(_ presentation: CoffeeMenuBarPresentation) {
        guard let button = statusItem?.button else { return }
        let tint: NSColor
        switch presentation.tint {
        case .red: tint = .systemRed
        case .green: tint = .systemGreen
        case .amber: tint = .systemOrange
        }
        let image = coloredStatusImage(presentation, tint: tint)
        button.image = image
        button.contentTintColor = image == nil ? tint : nil
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = presentation.accessibilityLabel
        button.setAccessibilityLabel("Mac Coffee")
        button.setAccessibilityValue(presentation.accessibilityLabel)
        button.setAccessibilityHelp(presentation.accessibilityLabel)
    }

    private func coloredStatusImage(_ presentation: CoffeeMenuBarPresentation, tint: NSColor) -> NSImage? {
        let pointSize: CGFloat = 18
        let scale: CGFloat = 4
        let pixelSize = Int(pointSize * scale)
        guard
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelSize, pixelsHigh: pixelSize,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap),
            let baseImage = NSImage(systemSymbolName: presentation.symbolName,
                                    accessibilityDescription: presentation.accessibilityLabel)
        else { return nil }

        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let symbol = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        let bounds = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        graphicsContext.imageInterpolation = .high
        graphicsContext.shouldAntialias = true
        graphicsContext.cgContext.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        graphicsContext.cgContext.scaleBy(x: scale, y: scale)
        symbol.draw(in: bounds, from: NSRect(origin: .zero, size: symbol.size),
                    operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        graphicsContext.cgContext.setBlendMode(.sourceIn)
        let resolvedTint = tint.usingColorSpace(.deviceRGB) ?? tint
        graphicsContext.cgContext.setFillColor(resolvedTint.cgColor)
        graphicsContext.cgContext.fill(bounds)
        graphicsContext.cgContext.setBlendMode(.normal)
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        image.isTemplate = false
        image.accessibilityDescription = presentation.accessibilityLabel
        return image
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
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
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
        _ = shortcut.unregister()
        state.applicationWillTerminate()
    }
}
