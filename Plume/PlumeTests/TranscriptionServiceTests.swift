import XCTest
import AVFoundation
@testable import Plume

final class TranscriptionServiceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = PathGuard.appTempDirectory
            .appendingPathComponent("plume-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testWriteTranscriptCreatesSidecar() throws {
        let audio = dir.appendingPathComponent("Recording.m4a")
        FileManager.default.createFile(atPath: audio.path, contents: Data())

        try TranscriptionService.writeTranscript("hello world", to: audio)

        let side = PathGuard.sidecarURL(for: audio, ext: "txt")
        XCTAssertEqual(side.lastPathComponent, "Recording.txt")
        XCTAssertEqual(try String(contentsOf: side, encoding: .utf8), "hello world")
    }

    func testWriteTranscriptOverwrites() throws {
        let audio = dir.appendingPathComponent("Recording.wav")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        try TranscriptionService.writeTranscript("first", to: audio)

        try TranscriptionService.writeTranscript("second", to: audio)

        XCTAssertEqual(try String(contentsOf: PathGuard.sidecarURL(for: audio, ext: "txt"), encoding: .utf8), "second")
    }

    func testSidecarDiscoverableAsTranscript() throws {
        let audio = dir.appendingPathComponent("Meeting.m4a")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        try TranscriptionService.writeTranscript("text", to: audio)

        let side = PathGuard.sidecarURL(for: audio, ext: "txt")
        XCTAssertEqual(PathGuard.transcriptExtensions, ["txt", "json"])
        XCTAssertTrue(PathGuard.transcriptExtensions.contains(side.pathExtension))
    }

    func testMonoMixdownFlattensStereo() throws {
        // Build a 1-second stereo float32 WAV fixture with a tone on each channel.
        let stereoURL = dir.appendingPathComponent("stereo.wav")
        let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true
        ]
        let frames: AVAudioFrameCount = 48000
        // Scope the writer so it finalizes the file before we read it back.
        try {
            let out = try AVAudioFile(forWriting: stereoURL, settings: settings)
            let buf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frames)!
            buf.frameLength = frames
            for f in 0..<Int(frames) {
                buf.floatChannelData![0][f] = 0.5
                buf.floatChannelData![1][f] = -0.5
            }
            try out.write(from: buf)
        }()

        let src = try AVAudioFile(forReading: stereoURL)
        let mixURL = try TranscriptionService.writeMonoMixdown(of: src)
        defer { try? FileManager.default.removeItem(at: mixURL) }

        let mix = try AVAudioFile(forReading: mixURL)
        XCTAssertEqual(mix.processingFormat.channelCount, 1)
        XCTAssertEqual(mix.length, src.length)

        // Both channels averaged: the downmixed samples should be near zero.
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let read = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 48000)!
        try mix.read(into: read)
        var peak: Float = 0
        for f in 0..<Int(read.frameLength) {
            peak = max(peak, abs(read.floatChannelData![0][f]))
        }
        XCTAssertLessThan(peak, 0.01)
    }
}