import AppKit
import Carbon.HIToolbox

@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    func register(_ shortcut: RecordedShortcut?) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let shortcut else { return }
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x4C4B_5759), id: 1)
        RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.shared.onPress?() } }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}
