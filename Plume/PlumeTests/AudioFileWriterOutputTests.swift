import XCTest
import AVFoundation
@testable import Plume

/// Exercises AudioFileWriter end to end by writing real files and reading them back.
final class AudioFileWriterOutputTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = PathGuard.appTempDirectory
            .appendingPathComponent("plume-writer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pcm(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Interleaved float samples following the 44-byte WAV header.
    private func wavSamples(_ file: Data) -> [Float] {
        file.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private func littleEndianUInt32(_ file: Data, at offset: Int) -> Int {
        let b = [UInt8](file[offset..<offset + 4])
        return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
    }

    func testWavInterleavesSystemLeftAndMicRight() async throws {
        let url = dir.appendingPathComponent("stereo.wav")
        let writer = AudioFileWriter()
        try writer.start(format: .wav, output: url)
        let frames = 4800
        writer.appendSystem(pcm([Float](repeating: 0.25, count: frames)))
        writer.appendMic(pcm([Float](repeating: -0.5, count: frames)))
        try await writer.finish()

        let file = try Data(contentsOf: url)
        let dataBytes = frames * 2 * MemoryLayout<Float>.size
        XCTAssertEqual(littleEndianUInt32(file, at: 40), dataBytes, "data chunk size")
        XCTAssertEqual(littleEndianUInt32(file, at: 4), 36 + dataBytes, "RIFF size")
        XCTAssertEqual(file.count, 44 + dataBytes)

        let samples = wavSamples(file)
        XCTAssertEqual(samples.count, frames * 2)
        XCTAssertTrue(stride(from: 0, to: samples.count, by: 2).allSatisfy { samples[$0] == 0.25 }, "left = system")
        XCTAssertTrue(stride(from: 1, to: samples.count, by: 2).allSatisfy { samples[$0] == -0.5 }, "right = mic")
    }

    func testWavWithOnlySystemAudioLeavesMicChannelSilent() async throws {
        let url = dir.appendingPathComponent("system-only.wav")
        let writer = AudioFileWriter()
        try writer.start(format: .wav, output: url)
        writer.appendSystem(pcm([Float](repeating: 0.5, count: 4800)))
        try await writer.finish()

        let samples = wavSamples(try Data(contentsOf: url))
        XCTAssertEqual(samples.count, 4800 * 2)
        XCTAssertTrue(stride(from: 1, to: samples.count, by: 2).allSatisfy { samples[$0] == 0 })
    }

    func testWavWithNoAudioIsAValidEmptyFile() async throws {
        let url = dir.appendingPathComponent("empty.wav")
        let writer = AudioFileWriter()
        try writer.start(format: .wav, output: url)
        try await writer.finish()

        let file = try Data(contentsOf: url)
        XCTAssertEqual(file.count, 44)
        XCTAssertEqual(littleEndianUInt32(file, at: 40), 0)
    }

    func testM4AProducesReadableStereoFile() async throws {
        let url = dir.appendingPathComponent("tone.m4a")
        let writer = AudioFileWriter()
        try writer.start(format: .m4a, output: url)
        let sine = (0..<48000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.3 }
        for start in stride(from: 0, to: sine.count, by: 480) {
            writer.appendSystem(pcm(Array(sine[start..<start + 480])))
        }
        try await writer.finish()

        let audio = try AVAudioFile(forReading: url)
        XCTAssertEqual(audio.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(audio.length, 0)
    }

    func testCancelStopsWritingWithoutCrashing() throws {
        let url = dir.appendingPathComponent("cancelled.wav")
        let writer = AudioFileWriter()
        try writer.start(format: .wav, output: url)
        writer.appendSystem(pcm([Float](repeating: 0.1, count: 480)))
        writer.cancel()
        writer.appendSystem(pcm([Float](repeating: 0.1, count: 480)))
    }
}
