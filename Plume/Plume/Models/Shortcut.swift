import Foundation
import Carbon.HIToolbox

struct ShortcutModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int
    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// Modifier mask for Carbon's `RegisterEventHotKey`.
    var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.control) { mask |= UInt32(controlKey) }
        if contains(.option) { mask |= UInt32(optionKey) }
        if contains(.shift) { mask |= UInt32(shiftKey) }
        if contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Glyphs in the order macOS shows them: ⌃⌥⇧⌘.
    var glyphs: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A global keyboard shortcut: a key plus modifiers.
struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    /// What to show for the key, for example "R", "Space" or "F5".
    var keyLabel: String

    /// A global shortcut needs ⌃, ⌥ or ⌘, otherwise ordinary typing would trigger it.
    var isValid: Bool {
        !modifiers.isDisjoint(with: [.control, .option, .command]) && !keyLabel.isEmpty
    }

    var displayString: String { modifiers.glyphs + keyLabel }

    /// ⌃⌥⌘R: unlikely to clash with another app.
    static let defaultToggleRecording = Shortcut(
        keyCode: UInt32(kVK_ANSI_R), modifiers: [.control, .option, .command], keyLabel: "R")

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// The label for a key press: a name for special keys, else the typed character.
    static func label(forKeyCode keyCode: Int, characters: String?) -> String {
        if let special = specialKeys[keyCode] { return special }
        return (characters ?? "").uppercased()
    }
}
