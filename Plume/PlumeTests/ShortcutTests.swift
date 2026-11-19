import XCTest
import Carbon.HIToolbox
@testable import Plume

final class ShortcutTests: XCTestCase {
    func testDisplayStringUsesMacOSModifierOrder() {
        let s = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: [.command, .shift, .option, .control], keyLabel: "R")
        XCTAssertEqual(s.displayString, "⌃⌥⇧⌘R")
        XCTAssertEqual(Shortcut.defaultToggleRecording.displayString, "⌃⌥⌘R")
    }

    func testCarbonMaskCombinesModifiers() {
        let mods: ShortcutModifiers = [.command, .option]
        XCTAssertEqual(mods.carbonMask, UInt32(cmdKey) | UInt32(optionKey))
        XCTAssertEqual(ShortcutModifiers([]).carbonMask, 0)
    }

    func testShortcutNeedsControlOptionOrCommand() {
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [], keyLabel: "A").isValid)
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [.shift], keyLabel: "A").isValid)
        XCTAssertTrue(Shortcut(keyCode: 0, modifiers: [.shift, .command], keyLabel: "A").isValid)
        XCTAssertFalse(Shortcut(keyCode: 0, modifiers: [.command], keyLabel: "").isValid)
    }

    func testCodableRoundTrip() throws {
        let original = Shortcut(keyCode: UInt32(kVK_F5), modifiers: [.control, .option], keyLabel: "F5")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testKeyLabels() {
        XCTAssertEqual(Shortcut.label(forKeyCode: kVK_Space, characters: " "), "Space")
        XCTAssertEqual(Shortcut.label(forKeyCode: kVK_F12, characters: nil), "F12")
        XCTAssertEqual(Shortcut.label(forKeyCode: kVK_ANSI_R, characters: "r"), "R")
        XCTAssertEqual(Shortcut.label(forKeyCode: kVK_LeftArrow, characters: nil), "←")
    }
}
