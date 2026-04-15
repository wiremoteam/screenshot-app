import Carbon
import AppKit

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var callback: (() -> Void)?

    // Static reference needed for the C callback
    static weak var instance: HotkeyManager?

    func register(callback: @escaping () -> Void) {
        self.callback = callback
        HotkeyManager.instance = self

        installEventHandler()
        registerHotKey()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeyChanged,
            object: nil
        )
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerProcPtr = { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                HotkeyManager.instance?.callback?()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
    }

    private func registerHotKey() {
        let settings = SettingsManager.shared
        let hotkeyID = EventHotKeyID(signature: 0x53435250, id: 1) // 'SCRP'

        let status = RegisterEventHotKey(
            UInt32(settings.hotkeyKeyCode),
            UInt32(settings.hotkeyModifiers),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("Failed to register hotkey: \(status)")
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    @objc func hotkeySettingsChanged() {
        unregisterHotKey()
        registerHotKey()
    }

    deinit {
        unregisterHotKey()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
        NotificationCenter.default.removeObserver(self)
    }
}
