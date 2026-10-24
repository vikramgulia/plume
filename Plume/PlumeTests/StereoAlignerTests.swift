import XCTest
@testable import Plume

final class StereoAlignerTests: XCTestCase {
    private let rate = Double(StereoAligner.sampleRate)

    private func ramp(from start: Int, count: Int, scale: Float = 1) -> [Float] {
        (start..<start + count).map { Float($0) * scale }
    }

    func testContinuousSourcesStayFrameAligned() throws {
        var a = StereoAligner()
        let chunk = 480
        for k in 0..<100 {
            let t = Double((k + 1) * chunk) / rate
            a.push(ramp(from: k * chunk, count: chunk), source: .system, at: t)
            a.push(ramp(from: k * chunk, count: chunk, scale: -1), source: .mic, at: t)
        }
        let out = try XCTUnwrap(a.peekAll(maxFrames: 100_000))
        XCTAssertEqual(out.count, 48000 * 2)
        for f in stride(from: 0, to: 48000, by: 997) {
            XCTAssertEqual(out[f * 2], Float(f))
            XCTAssertEqual(out[f * 2 + 1], -Float(f))
        }
    }

    func testLateStartingMicIsPlacedAtItsRealTime() throws {
        var a = StereoAligner()
        a.push([Float](repeating: 0.5, count: 48000), source: .system, at: 1.0)
        // First mic buffer arrives half a second in and covers the 480 frames before that.
        a.push([Float](repeating: 1, count: 480), source: .mic, at: 0.5)

        let out = try XCTUnwrap(a.peekAll(maxFrames: 100_000))
        let firstMicFrame = 24000 - 480
        XCTAssertEqual(out[(firstMicFrame - 1) * 2 + 1], 0, "silence before the mic started")
        XCTAssertEqual(out[firstMicFrame * 2 + 1], 1, "mic lands at its real position")
        XCTAssertEqual(out[(firstMicFrame + 479) * 2 + 1], 1)
    }

    func testQuietSourceGapIsSilenceNotAShift() throws {
        var a = StereoAligner()
        a.push([Float](repeating: 1, count: 4800), source: .system, at: 0.125)
        // Nothing for a while (no buffers while silent), then audio resumes at t = 1.5 s.
        a.push([Float](repeating: 2, count: 4800), source: .system, at: 1.5)

        let out = try XCTUnwrap(a.peekAll(maxFrames: 200_000))
        XCTAssertEqual(out.count, 72000 * 2)
        let resume = 72000 - 4800
        XCTAssertEqual(out[(resume - 1) * 2], 0)
        XCTAssertEqual(out[resume * 2], 2)
    }

    func testSmallDeliveryJitterIsNotPadded() {
        var a = StereoAligner()
        a.push([Float](repeating: 1, count: 2048), source: .mic, at: 0.043)
        // Arrives 20 ms later than a perfectly regular stream would.
        a.push([Float](repeating: 1, count: 2048), source: .mic, at: 0.043 * 2 + 0.02)

        XCTAssertEqual(a.pendingFrames, 4096)
    }

    func testPeekStopsAtLatencyHorizon() throws {
        var a = StereoAligner()
        a.push([Float](repeating: 1, count: 48000), source: .system, at: 1.0)

        let first = try XCTUnwrap(a.peek(upTo: 1.0, latency: 0.2, maxFrames: 100_000))
        XCTAssertEqual(first.count, 38400 * 2)
        a.commit(frames: first.count / 2)
        XCTAssertNil(a.peek(upTo: 1.0, latency: 0.2, maxFrames: 100_000))

        let later = try XCTUnwrap(a.peek(upTo: 1.1, latency: 0.2, maxFrames: 100_000))
        XCTAssertEqual(later.count, 4800 * 2)
    }

    func testPeekRespectsMaxFramesAndCommitAdvances() throws {
        var a = StereoAligner()
        a.push(ramp(from: 0, count: 48000), source: .system, at: 1.0)

        let chunk = try XCTUnwrap(a.peek(upTo: 1.0, latency: 0, maxFrames: 9600))
        XCTAssertEqual(chunk.count, 9600 * 2)
        a.commit(frames: 9600)
        XCTAssertEqual(a.position, 9600)

        let next = try XCTUnwrap(a.peek(upTo: 1.0, latency: 0, maxFrames: 9600))
        XCTAssertEqual(next[0], 9600, "continues exactly where the last chunk ended")
    }

    func testSilenceIsEmittedAtRealTimePaceWhenNothingArrives() throws {
        let a = StereoAligner()
        let out = try XCTUnwrap(a.peek(upTo: 1.0, latency: 0.2, maxFrames: 100_000))
        XCTAssertEqual(out.count, 38400 * 2)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testSourceFarAheadOfRealTimeHasExcessDropped() {
        var a = StereoAligner()
        a.push([Float](repeating: 1, count: 96000), source: .mic, at: 0.1)
        a.push([Float](repeating: 1, count: 480), source: .mic, at: 0.1)

        XCTAssertEqual(a.pendingFrames, 96000)
    }
}

final class AudioFileWriterAlignmentTests: XCTestCase {
    func testLateMicStaysAlignedInWav() async throws {
        let dir = PathGuard.appTempDirectory
            .appendingPathComponent("plume-align-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("late-mic.wav")

        var now: TimeInterval = 1000
        let writer = AudioFileWriter(clock: { now })
        try writer.start(format: .wav, output: url)

        func pcm(_ v: Float, _ n: Int) -> Data {
            [Float](repeating: v, count: n).withUnsafeBufferPointer { Data(buffer: $0) }
        }
        // One second of system audio in 10 ms chunks; the mic joins at 0.5 s.
        for k in 0..<100 {
            now = 1000 + Double(k + 1) * 0.01
            writer.appendSystem(pcm(0.5, 480))
            if k >= 50 { writer.appendMic(pcm(0.25, 480)) }
        }
        try await writer.finish()

        let samples = try Data(contentsOf: url).dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(samples.count / 2, 48000)
        let micStart = 24000  // chunk 50 arrives at 0.51 s and covers the 480 frames before it
        XCTAssertEqual(samples[(micStart - 100) * 2 + 1], 0, "mic channel silent before it joined")
        XCTAssertEqual(samples[(micStart + 100) * 2 + 1], 0.25, "mic present afterwards")
        XCTAssertEqual(samples[100 * 2], 0.5, "system present from the start")
    }
}
