import XCTest
import CoreAudio
@testable import Plume

final class AudioInputChoiceTests: XCTestCase {
    private let builtIn = AudioInputDevice(id: 1, uid: "builtin", name: "MacBook Pro Microphone", isBluetooth: false, isBuiltIn: true)
    private let headset = AudioInputDevice(id: 2, uid: "airpods", name: "AirPods", isBluetooth: true, isBuiltIn: false)
    private let usb = AudioInputDevice(id: 3, uid: "usb", name: "USB Mic", isBluetooth: false, isBuiltIn: false)

    func testBluetoothDefaultFallsBackToTheBuiltInMic() {
        let pick = AudioInputChoice.pick(preferredUID: nil, devices: [builtIn, headset], defaultID: 2)
        XCTAssertEqual(pick, builtIn)
    }

    func testBluetoothDefaultIsKeptWhenThereIsNoBuiltInMic() {
        let pick = AudioInputChoice.pick(preferredUID: nil, devices: [headset], defaultID: 2)
        XCTAssertEqual(pick, headset)
    }

    func testNonBluetoothDefaultIsKept() {
        XCTAssertEqual(AudioInputChoice.pick(preferredUID: nil, devices: [builtIn, usb], defaultID: 3), usb)
    }

    func testAChoiceInSettingsWins() {
        XCTAssertEqual(AudioInputChoice.pick(preferredUID: "airpods", devices: [builtIn, headset], defaultID: 1), headset)
    }

    func testAChoiceThatIsNoLongerPluggedInFallsBackToAutomatic() {
        XCTAssertEqual(AudioInputChoice.pick(preferredUID: "gone", devices: [builtIn, headset], defaultID: 2), builtIn)
    }

    func testNoDefaultDeviceLeavesTheSystemChoice() {
        XCTAssertNil(AudioInputChoice.pick(preferredUID: nil, devices: [builtIn], defaultID: nil))
    }
}
