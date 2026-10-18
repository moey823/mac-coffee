import Carbon.HIToolbox
import Combine

private let coffeeShortcutSignature: OSType = 0x4D434F46
private let coffeeShortcutIdentifier: UInt32 = 1

@MainActor
final class CoffeeShortcut: ObservableObject {
    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    @discardableResult
    func register(action: @escaping () -> Void) -> Bool {
        self.action = action
        errorMessage = nil

        if isRegistered { return true }

        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            guard status == noErr else {
                errorMessage = "Could not remove a previous Mac Coffee shortcut handler (macOS error \(status))."
                return false
            }
            self.eventHandler = nil
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var pressedID = EventHotKeyID(signature: 0, id: 0)
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard readStatus == noErr,
                      pressedID.signature == coffeeShortcutSignature,
                      pressedID.id == coffeeShortcutIdentifier else {
                    return OSStatus(eventNotHandledErr)
                }

                let shortcut = Unmanaged<CoffeeShortcut>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in shortcut.performAction() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            errorMessage = "Could not install the Mac Coffee shortcut handler (macOS error \(handlerStatus))."
            eventHandler = nil
            self.action = nil
            return false
        }

        let hotKeyID = EventHotKeyID(
            signature: coffeeShortcutSignature,
            id: coffeeShortcutIdentifier
        )
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_C),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            if let eventHandler {
                _ = RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            self.action = nil
            errorMessage = Self.registrationError(for: registrationStatus)
            return false
        }

        isRegistered = true
        return true
    }

    @discardableResult
    func unregister() -> Bool {
        errorMessage = nil

        if let hotKey {
            let status = UnregisterEventHotKey(hotKey)
            guard status == noErr else {
                errorMessage = "Could not unregister the Mac Coffee shortcut (macOS error \(status))."
                return false
            }
            self.hotKey = nil
        }

        if let eventHandler {
            let status = RemoveEventHandler(eventHandler)
            guard status == noErr else {
                errorMessage = "Could not remove the Mac Coffee shortcut handler (macOS error \(status))."
                isRegistered = false
                return false
            }
            self.eventHandler = nil
        }

        action = nil
        isRegistered = false
        return true
    }

    private func performAction() {
        action?()
    }

    private static func registrationError(for status: OSStatus) -> String {
        if status == OSStatus(-9878) {
            return "Command-Option-C is already in use. Turn off the conflicting shortcut to enable Mac Coffee's shortcut."
        }
        return "Could not register Command-Option-C (macOS error \(status))."
    }
}
