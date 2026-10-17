import AppKit
import SwiftUI

@MainActor
final class MacCoffeeAppDelegate: NSObject, NSApplicationDelegate {
    private let state = CoffeeState()
    private let popover = NSPopover()
    private let showPopoverOnLaunch: Bool
    private var statusItem: NSStatusItem?

    init(showPopoverOnLaunch: Bool = false) {
        self.showPopoverOnLaunch = showPopoverOnLaunch
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Mac Coffee")
            button.imagePosition = .imageOnly
            button.toolTip = "Mac Coffee"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 340, height: 520)
        popover.contentViewController = NSHostingController(rootView: MacCoffeeMenuView(state: state))
        state.start()
        if showPopoverOnLaunch {
            DispatchQueue.main.async { self.showPopover() }
        }
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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        state.applicationWillTerminate()
    }
}
