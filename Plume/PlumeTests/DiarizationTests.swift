import XCTest
import AVFoundation
@testable import Plume

final class DiarizationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = PathGuard.appTempDirectory
            .appendingPathComponent("plume-diar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - mergeSegments

    func testMergeAssignsSpeakerByMaxOverlap() {
        let segments = [
            TimedSegment(start: 0.0, end: 3.0, text: "hello there"),
            TimedSegment(start: 6.0, end: 9.0, text: "hi back")
        ]
        let turns = [
            SpeakerTurn(start: 0.0, end: 4.0, cluster: 0),
            SpeakerTurn(start: 5.5, end: 10.0, cluster: 1)
        ]
        let id0 = UUID(), id1 = UUID()
        let labels: [Int: (UUID, String)] = [0: (id0, "Alice"), 1: (id1, "Bob")]

        let merged = TranscriptionService.mergeSegments(segments, turns: turns, labels: labels)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].speaker, "Alice")
        XCTAssertEqual(merged[0].speakerId, id0.uuidString)
        XCTAssertEqual(merged[1].speaker, "Bob")
        XCTAssertEqual(merged[1].text, "hi back")
    }

    func testMergeFallsBackToNearestTurnWithoutOverlap() {
        let segments = [TimedSegment(start: 20.0, end: 21.0, text: "echo")]
        let turns = [
            SpeakerTurn(start: 0.0, end: 10.0, cluster: 0),
            SpeakerTurn(start: 18.0, end: 19.5, cluster: 1)
        ]
        let labels: [Int: (UUID, String)] = [0: (UUID(), "Far"), 1: (UUID(), "Near")]

        let merged = TranscriptionService.mergeSegments(segments, turns: turns, labels: labels)

        XCTAssertEqual(merged[0].speaker, "Near")
    }

    func testMergeWithNoTurnsLeavesSpeakerEmpty() {
        let segments = [TimedSegment(start: 0, end: 1, text: "alone")]
        let merged = TranscriptionService.mergeSegments(segments, turns: [], labels: [:])
        XCTAssertEqual(merged[0].speaker, "")
        XCTAssertNil(merged[0].speakerId)
    }

    func testRenderLabeledTextFormat() {
        let segments = [
            LabeledSegment(start: 5, end: 8, speakerId: nil, speaker: "Alice", text: "hi"),
            LabeledSegment(start: 62, end: 70, speakerId: nil, speaker: "", text: "mystery")
        ]
        let text = TranscriptionService.renderLabeledText(segments)
        XCTAssertEqual(text, "[00:05] Alice: hi\n[01:02] Unknown: mystery")
    }

    func testClockString() {
        XCTAssertEqual(TranscriptionService.clockString(0), "00:00")
        XCTAssertEqual(TranscriptionService.clockString(65), "01:05")
        XCTAssertEqual(TranscriptionService.clockString(3671), "1:01:11")
    }

    // MARK: - SpeakerLibrary

    @MainActor
    func testSpeakerLibraryPersistsAndMatches() throws {
        let lib = SpeakerLibrary(directory: dir)
        XCTAssertTrue(lib.profiles().isEmpty)

        // Two clearly different "voices".
        let v1: [Float] = [1, 0, 0, 0, 1, 0, 0, 0]
        let v1Again: [Float] = [0.9, 0.05, 0.02, 0.01, 0.85, 0.04, 0.03, 0.02]
        let v2: [Float] = [0, 1, 0, 0, 0, 1, 0, 0]

        let p1 = lib.upsert(embedding: v1)
        let p2 = lib.upsert(embedding: v2)
        XCTAssertEqual(lib.profiles().count, 2)
        XCTAssertNotEqual(p1.id, p2.id)

        let matched = lib.upsert(embedding: v1Again)
        XCTAssertEqual(matched.id, p1.id, "same voice should match the existing profile")
        XCTAssertEqual(lib.profiles().count, 2)

        // Round-trip through a fresh instance backed by the same directory.
        let reloaded = SpeakerLibrary(directory: dir)
        XCTAssertEqual(reloaded.profiles().count, 2)
        XCTAssertEqual(reloaded.profiles().first?.name, "Speaker 1")

        reloaded.rename(id: p1.id, to: "Vikas")
        XCTAssertEqual(reloaded.profiles().first { $0.id == p1.id }?.name, "Vikas")

        reloaded.remove(id: p2.id)
        XCTAssertEqual(reloaded.profiles().count, 1)
    }

    @MainActor
    func testCosineSimilarityBasics() {
        XCTAssertEqual(SpeakerLibrary.cosineSimilarity([1, 0], [1, 0]), 1, accuracy: 1e-5)
        XCTAssertEqual(SpeakerLibrary.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-5)
        XCTAssertEqual(SpeakerLibrary.cosineSimilarity([1, 0], [-1, 0]), -1, accuracy: 1e-5)
        XCTAssertEqual(SpeakerLibrary.cosineSimilarity([1, 0], []), 0)
    }

    /// Regression: the per-cluster embedding extractor aborts the process when
    /// fed a long meeting's full cluster audio (ONNXRuntime C++ exception).
    /// Opt in with PLUME_DAR_LONG_AUDIO=/path/to/recording.m4a — takes ~RTF×0.1.
    @MainActor
    func testDiarizeLongRecordingWithoutAbort() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLUME_DAR_LONG_AUDIO"],
              FileManager.default.fileExists(atPath: path),
              DiarizationService.modelPaths() != nil else {
            throw XCTSkip("Skipping: set PLUME_DAR_LONG_AUDIO to a long recording to run")
        }
        // diarize writes real SpeakerLibrary state — snapshot and restore it.
        let store = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plume/speakers.json")
        let backup = try? Data(contentsOf: store)
        defer {
            if let backup {
                try? backup.write(to: store, options: .atomic)
            }
        }
        let (turns, labels) = try await DiarizationService.shared.diarize(
            audioURL: URL(fileURLWithPath: path))
        XCTAssertFalse(turns.isEmpty)
        XCTAssertFalse(labels.isEmpty, "at least one cluster should map to a speaker profile")
    }

    // MARK: - Fragment collapse

    func testCollapseClustersMergesSameVoiceFragments() {
        // c1 and c2 are the same voice (cos ~0.995); c3 is a different voice.
        let e1: [Float] = [1, 0, 0, 0, 0, 0, 0, 0]
        let e2: [Float] = [0.99, 0.1, 0, 0, 0, 0, 0, 0]
        let e3: [Float] = [0, 0, 0, 1, 0, 0, 0, 0]
        let turns = [
            SpeakerTurn(start: 0, end: 5, cluster: 1),
            SpeakerTurn(start: 5, end: 9, cluster: 2),
            SpeakerTurn(start: 9, end: 12, cluster: 3)
        ]

        let out = DiarizationService.collapseClusters(
            turns: turns, embeddings: [1: e1, 2: e2, 3: e3], clusterSamples: [:],
            threshold: 0.55)

        XCTAssertEqual(out.turns.filter { $0.cluster == 1 }.count, 2)
        XCTAssertEqual(out.turns.first { $0.cluster == 3 }?.start, 9)
        XCTAssertNil(out.embeddings[2], "fragment should be merged into its representative")
        XCTAssertNotNil(out.embeddings[1])
        XCTAssertNotNil(out.embeddings[3])
    }

    func testCollapseClustersKeepsDistinctVoicesApart() {
        // Orthogonal voices must not merge at 0.55.
        let voice1: [Float] = [1, 1, 0, 0, 0, 0, 0, 0]
        let voice2: [Float] = [0, 0, 1, 1, 0, 0, 0, 0]
        let out = DiarizationService.collapseClusters(
            turns: [], embeddings: [10: voice1, 20: voice2], clusterSamples: [:],
            threshold: 0.55)
        XCTAssertEqual(out.embeddings.count, 2)
    }

    // MARK: - Mic-channel VAD
    func testVoiceTurnsDetectsSpeechAndSkipsSilence() {
        let rate = 16000
        var samples: [Float] = []
        func append(seconds: Double, level: Float) {
            samples.append(contentsOf: Array(repeating: level, count: Int(seconds * Double(rate))))
        }
        append(seconds: 3.0, level: 0)      // leading silence
        append(seconds: 2.0, level: 0.2)    // utterance
        append(seconds: 0.3, level: 0)      // tiny pause (bridged)
        append(seconds: 1.5, level: 0.15)   // same utterance, continues
        append(seconds: 2.0, level: 0)      // trailing silence
        // Sub-threshold blip well under min utterance.
        append(seconds: 0.1, level: 0.1)
        append(seconds: 1.0, level: 0.0)

        let turns = DiarizationService.voiceTurns(samples, sampleRate: rate)

        // The two utterances bridge the 0.3s gap into one; the 0.1s blip is dropped.
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].cluster, DiarizationService.micCluster)
        XCTAssertGreaterThan(turns[0].start, 2.0)
        XCTAssertLessThan(turns[0].start, 3.5)
        XCTAssertEqual(turns[0].end, 6.8, accuracy: 0.1)
    }

    func testVoiceTurnsAllSilence() {
        let samples: [Float] = Array(repeating: 0, count: 16000)
        XCTAssertTrue(DiarizationService.voiceTurns(samples, sampleRate: 16000).isEmpty)
    }

    func testMicClusterNeverCollidesWithPyannoteOutput() {
        // Pyannote clusters are small ints; the reserved mic id must stay apart.
        XCTAssertGreaterThan(DiarizationService.micCluster, 100)
    }

    // MARK: - AudioFileReader
    func testReadMono16kResamples() throws {
        // 1 second of 48 kHz mono float WAV.
        let url = dir.appendingPathComponent("fixture.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try {
            let out = try AVAudioFile(forWriting: url, settings: settings)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            buf.frameLength = 48000
            for f in 0..<48000 {
                buf.floatChannelData![0][f] = sinf(2 * Float.pi * 440 * Float(f) / 48000.0)
            }
            try out.write(from: buf)
        }()

        let samples = try AudioFileReader.readMono16k(from: url)

        // 48k -> 16k should be roughly a third of the frames, with real signal.
        XCTAssertEqual(Double(samples.count) / 16000.0, 1.0, accuracy: 0.05)
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        XCTAssertGreaterThan(peak, 0.5)
    }
}