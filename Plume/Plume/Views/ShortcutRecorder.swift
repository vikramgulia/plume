import SwiftUI
import AppKit
import Carbon.HIToolbox

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var m: ShortcutModifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        self = m
    }
}

/// A button that records a keyboard shortcut: click, press the keys, done.
/// Esc cancels and Delete clears.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    /// The other shortcut, so the same combination can't be used twice.
    var other: Shortcut?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                Button(isRecording ? "Press keys…" : (shortcut?.displayString ?? "Record")) {
                    isRecording ? stop() : start()
                }
                .frame(minWidth: 96)
                if shortcut != nil && !isRecording {
                    Button {
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear shortcut")
                }
            }
            if let message {
                Text(message).font(.caption2).foregroundStyle(.red)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stop()
            return
        case kVK_Delete, kVK_ForwardDelete:
            shortcut = nil
            stop()
            return
        default:
            break
        }
        let candidate = Shortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: ShortcutModifiers(event.modifierFlags),
            keyLabel: Shortcut.label(forKeyCode: Int(event.keyCode), characters: event.charactersIgnoringModifiers))
        guard candidate.isValid else {
            message = "Include ⌃, ⌥ or ⌘"
            return
        }
        guard candidate != other else {
            message = "Already used by the other shortcut"
            return
        }
        shortcut = candidate
        stop()
    }
}
