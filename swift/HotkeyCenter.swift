import AppKit
import ApplicationServices
import Carbon.HIToolbox.Events

/// System-wide ⌥Space: record/stop from any app. Carbon hotkeys are still the only
/// dependency-free way to catch a global key on macOS.
final class HotkeyCenter {
    var onToggle: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            // Carbon calls on the main run loop already; hop into Swift land
            Unmanaged<HotkeyCenter>.fromOpaque(userData!).takeUnretainedValue().fire()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
        RegisterEventHotKey(49, UInt32(optionKey),  // 49 = Space keycode
                            EventHotKeyID(signature: OSType(0x7475_7475), id: 1),  // 'tuti'
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    private func fire() { onToggle?() }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Pastes the clipboard into `app`: reactivates it and posts ⌘V. Returns an error string
    /// when Tuti is not trusted for Accessibility (synthetic keys are dropped without it).
    static func paste(into app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else {
            return "Paste needs Tuti in System Settings › Privacy & Security › Accessibility"
        }
        _ = app.activate()
        Thread.sleep(forTimeInterval: 0.15)  // let the app take focus before the key lands
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 9,  // V keycode
                                keyDown: keyDown)
            if keyDown { event?.flags = CGEventFlags(rawValue: 1 << 20) }  // 1<<20 = command
            event?.post(tap: .cghidEventTap)
        }
        return nil
    }
}
