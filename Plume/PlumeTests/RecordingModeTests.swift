import XCTest
@testable import Plume

final class RecordingModeTests: XCTestCase {
    func testVoiceNotesAreNamedDifferentlyFromRecordings() {
        XCTAssertEqual(RecordingMode.systemAndMic.filePrefix, "Recording")
        XCTAssertEqual(RecordingMode.voiceNote.filePrefix, "Voice note")
    }

    /// A voice note is a normal stereo file with only the mic (right) channel filled in.
    func testMicOnlyAudioLandsOnTheRightChannelOnly() async throws {
        let dir = PathGuard.appTempDirectory
            .appendingPathComponent("plume-voicenote-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Voice note.wav")

        let writer = AudioFileWriter()
        try writer.start(format: .wav, output: url)
        let mic = [Float](repeating: 0.4, count: 4800).withUnsafeBufferPointer { Data(buffer: $0) }
        writer.appendMic(mic)
        try await writer.finish()

        let samples = try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(samples.count, 4800 * 2)
        XCTAssertTrue(stride(from: 0, to: samples.count, by: 2).allSatisfy { samples[$0] == 0 }, "left (system) stays silent")
        XCTAssertTrue(stride(from: 1, to: samples.count, by: 2).allSatisfy { samples[$0] == 0.4 }, "right carries the mic")
    }
}
