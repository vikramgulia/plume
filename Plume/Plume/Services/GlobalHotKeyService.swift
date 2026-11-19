import AppKit
import Carbon.HIToolbox

enum HotKeyAction: UInt32 {
    case toggleRecording = 1
    case voiceNote = 2
}

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`, which works from any app
/// and does not need the Accessibility permission.
@MainActor
final class GlobalHotKeyService {
    var onAction: ((HotKeyAction) -> Void)?

    private var registered: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x504C_4D45 // 'PLME'

    init() {
        installHandler()
    }

    /// Registers `shortcut` for `action`, replacing any earlier one. Pass nil to clear it.
    /// Returns false if the system refused it (usually because another app owns it).
    @discardableResult
    func set(_ shortcut: Shortcut?, for action: HotKeyAction) -> Bool {
        if let old = registered.removeValue(forKey: action) {
            UnregisterEventHotKey(old)
        }
        guard let shortcut else { return true }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers.carbonMask, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Diag.log("HOTKEY register failed for \(shortcut.displayString): \(status)")
            return false
        }
        registered[action] = ref
        return true
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, userData, &handlerRef)
    }
}

/// Carbon calls this on the main thread when a registered shortcut is pressed. It is a plain
/// function (not a closure inside the class) so it can be passed as a C callback.
private func hotKeyEventHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, let action = HotKeyAction(rawValue: hotKeyID.id) else { return status }
    let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in service.onAction?(action) }
    return noErr
}
