import Foundation
import Speech
import AVFoundation

enum TranscriptionJobStatus: String {
    case idle
    case queued
    case installingLocale = "installing-locale"
    case transcribing
    case diarizing
    case complete
    case cancelled
    case error
}

/// A transcript chunk with its time range in the recording.
struct TimedSegment {
    let start: Double
    let end: Double
    let text: String
}

/// One speaker-labeled transcript segment, persisted in the `.json` sidecar.
struct LabeledSegment: Codable {
    let start: Double
    let end: Double
    let speakerId: String?
    let speaker: String
    let text: String
}

struct TranscriptDocument: Codable {
    let segments: [LabeledSegment]
}

struct TranscriptionProgress {
    let fileURL: URL
    let status: TranscriptionJobStatus
    let progress: Double
    var error: String?
    var transcriptURL: URL?
}

enum TranscriptionError: LocalizedError, Equatable {
    case speechUnavailable
    case localeUnsupported
    case emptyAudio
    case noTranscript
    case modelMissing
    case modelInstallFailed(String)
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return "Speech transcription is not available on this Mac."
        case .localeUnsupported:
            return "The selected transcription language is not supported on this Mac."
        case .emptyAudio:
            return "The recording contains no audio."
        case .noTranscript:
            return "Transcript was not created."
        case .modelMissing:
            return "The Whisper model is not installed. Download it in Settings, or switch to Apple Speech."
        case .modelInstallFailed(let message):
            return "The model could not be downloaded: \(message)"
        case .engineFailed(let detail):
            return "Transcription failed: \(detail)."
        }
    }
}

@MainActor
final class TranscriptionService: ObservableObject {
    @Published var jobs: [String: TranscriptionProgress] = [:]

    private var queue: [URL] = []
    private var activeURL: URL?
    private let prefs = PreferencesStore.shared
    /// The engine that is always available: Apple's on-device speech recognition.
    private let fallbackEngine: TranscriptionEngine
    private let alternatives: [TranscriptionEngine]
    private var runningEngine: TranscriptionEngine?

    init(engine: TranscriptionEngine, alternatives: [TranscriptionEngine] = []) {
        self.fallbackEngine = engine
        self.alternatives = alternatives
    }

    /// Apple Speech, plus Whisper when the user has chosen it and its model is installed.
    convenience init() {
        self.init(engine: AppleSpeechEngine(), alternatives: [WhisperEngine()])
    }

    /// The engine chosen in Settings, falling back to Apple Speech when that engine is not ready
    /// (for example its model has not been downloaded).
    private var engine: TranscriptionEngine {
        let chosen = prefs.transcriptionEngineID
        if chosen != fallbackEngine.id,
           let preferred = alternatives.first(where: { $0.id == chosen }), preferred.isAvailable {
            return preferred
        }
        return fallbackEngine
    }

    // MARK: Job status

    func status(for url: URL) -> TranscriptionProgress {
        jobs[url.path] ?? TranscriptionProgress(fileURL: url, status: .idle, progress: 0)
    }

    func start(_ url: URL) {
        do {
            _ = try PathGuard.assertAudioFile(url, saveFolder: prefs.saveFolder)
        } catch {
            jobs[url.path] = TranscriptionProgress(fileURL: url, status: .error, progress: 0, error: error.localizedDescription)
            return
        }
        if let existing = jobs[url.path], existing.status == .queued || existing.status == .installingLocale || existing.status == .transcribing || existing.status == .diarizing {
            return
        }
        jobs[url.path] = TranscriptionProgress(fileURL: url, status: .queued, progress: 0)
        queue.append(url)
        pump()
    }

    func cancel(_ url: URL) {
        if activeURL == url {
            let engine = runningEngine ?? engine
            Task { await engine.cancel() }
            activeURL = nil
            jobs[url.path] = TranscriptionProgress(fileURL: url, status: .cancelled, progress: 0)
            pump()
            return
        }
        queue.removeAll { $0 == url }
        jobs[url.path] = TranscriptionProgress(fileURL: url, status: .cancelled, progress: 0)
    }

    // MARK: Language assets (Settings UI)

    func supportedLocales() async -> [Locale] {
        await engine.supportedLocales()
    }

    func resolvedLocale() async -> Locale? {
        await engine.resolveLocale(prefs.transcriptionLanguage)
    }

    func assetStatus() async -> EngineAssetStatus? {
        guard let locale = await resolvedLocale() else { return nil }
        return await engine.assetStatus(for: locale)
    }

    func installAssets() async throws {
        guard let locale = await resolvedLocale() else {
            throw TranscriptionError.localeUnsupported
        }
        try await engine.installAssets(for: locale)
    }

    // MARK: Transcript sidecar

    nonisolated static func writeTranscript(_ text: String, to audioURL: URL) throws {
        try text.write(
            to: PathGuard.sidecarURL(for: audioURL, ext: "txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    nonisolated static func writeTranscriptJSON(_ segments: [LabeledSegment], to audioURL: URL) throws {
        let doc = TranscriptDocument(segments: segments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: PathGuard.sidecarURL(for: audioURL, ext: "json"), options: .atomic)
    }

    /// Pick, for each transcript segment, the speaker turn with the largest time
    /// overlap; fall back to the nearest turn when nothing overlaps.
    nonisolated static func mergeSegments(_ segments: [TimedSegment],
                                          turns: [SpeakerTurn],
                                          labels: [Int: (id: UUID, name: String)]) -> [LabeledSegment] {
        guard !turns.isEmpty else {
            return segments.map { LabeledSegment(start: $0.start, end: $0.end, speakerId: nil, speaker: "", text: $0.text) }
        }
        return segments.map { seg in
            var best: (turn: SpeakerTurn, overlap: Double)?
            for turn in turns {
                let overlap = min(seg.end, turn.end) - max(seg.start, turn.start)
                if overlap > 0, best == nil || overlap > best!.overlap {
                    best = (turn, overlap)
                }
            }
            let chosen: SpeakerTurn
            if let b = best {
                chosen = b.turn
            } else {
                let mid = (seg.start + seg.end) / 2
                chosen = turns.min { a, b in
                    abs((a.start + a.end) / 2 - mid) < abs((b.start + b.end) / 2 - mid)
                }!
            }
            let label = labels[chosen.cluster]
            return LabeledSegment(
                start: seg.start,
                end: seg.end,
                speakerId: label?.id.uuidString,
                speaker: label?.name ?? "Unknown",
                text: seg.text
            )
        }
    }

    /// `[mm:ss] Name: text` lines — the human-readable labeled transcript.
    nonisolated static func renderLabeledText(_ segments: [LabeledSegment]) -> String {
        segments.map { seg in
            let name = seg.speaker.isEmpty ? "Unknown" : seg.speaker
            return "[\(clockString(seg.start))] \(name): \(seg.text)"
        }.joined(separator: "\n")
    }

    nonisolated static func clockString(_ t: Double) -> String {
        let s = max(0, Int(t))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%02d:%02d", m, sec)
    }

    /// SpeechAnalyzer reads only one channel of a stereo file, which drops the
    /// mic side of Plume's recordings. Write a mono downmix (both channels
    /// averaged) to a temporary WAV and transcribe that instead.
    nonisolated static func writeMonoMixdown(of src: AVAudioFile) throws -> URL {
        let srcFormat = src.processingFormat
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcFormat.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "Plume", code: 40, userInfo: [NSLocalizedDescriptionKey: "Cannot create mono format"])
        }
        let tmp = PathGuard.appTempDirectory
            .appendingPathComponent("plume-mix-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: srcFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let out = try AVAudioFile(forWriting: tmp, settings: settings)
        let channels = Int(srcFormat.channelCount)

        let cap: AVAudioFrameCount = 65536
        while src.framePosition < src.length {
            // Read an explicit frame count: a bare capacity read throws nilError
            // when it hits the file's final partial chunk.
            let want = min(cap, AVAudioFrameCount(src.length - src.framePosition))
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: want) else { break }
            try src.read(into: inBuf, frameCount: want)
            if inBuf.frameLength == 0 { break }
            let n = Int(inBuf.frameLength)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: want) else { break }
            outBuf.frameLength = inBuf.frameLength
            // AVAudioConverter's channel remap drops all but the first channel,
            // so average the channels by hand.
            if let dst = outBuf.floatChannelData?[0] {
                for i in 0..<n {
                    var sum: Float = 0
                    for ch in 0..<channels {
                        if let p = inBuf.floatChannelData?[ch] {
                            sum += p[i]
                        }
                    }
                    dst[i] = sum / Float(channels)
                }
            }
            try out.write(from: outBuf)
        }
        return tmp
    }

    // MARK: Queue

    private func pump() {
        guard activeURL == nil, let next = queue.first else { return }
        queue.removeFirst()
        activeURL = next
        Task { await runJob(next) }
    }

    private func finishJob(_ fileURL: URL) {
        guard activeURL == fileURL else { return }
        activeURL = nil
        pump()
    }

    private func runJob(_ fileURL: URL) async {
        do {
            let engine = engine
            runningEngine = engine
            defer { runningEngine = nil }
            guard engine.isAvailable else {
                throw TranscriptionError.speechUnavailable
            }
            guard let locale = await engine.resolveLocale(prefs.transcriptionLanguage) else {
                throw TranscriptionError.localeUnsupported
            }
            let segments = try await engine.transcribe(fileURL, locale: locale) { [weak self] status, progress in
                self?.update(fileURL, status: status, progress: progress)
            }
            guard !segments.isEmpty else {
                throw TranscriptionError.emptyAudio
            }

            // Unlabeled transcript first — the always-present fallback.
            let plain = segments.map(\.text).joined(separator: " ")
            try Self.writeTranscript(plain, to: fileURL)
            let side = PathGuard.sidecarURL(for: fileURL, ext: "txt")
            guard FileManager.default.fileExists(atPath: side.path) else {
                throw TranscriptionError.noTranscript
            }
            jobs[fileURL.path] = TranscriptionProgress(fileURL: fileURL, status: .complete, progress: 100, transcriptURL: side)

            // Optional speaker-labeling stage. Failure here never fails the job.
            if DiarizationService.shared.isAvailable {
                update(fileURL, status: .diarizing, progress: 0)
                do {
                    // The original file, not the mixdown: for stereo recordings
                    // diarization runs per-channel (system / mic).
                    let (turns, labels) = try await DiarizationService.shared.diarize(audioURL: fileURL)
                    let labeled = Self.mergeSegments(segments, turns: turns, labels: labels)
                    try Self.writeTranscript(Self.renderLabeledText(labeled), to: fileURL)
                    try Self.writeTranscriptJSON(labeled, to: fileURL)
                } catch {
                    Diag.log("DIAR stage failed (transcript stays unlabeled): \(error.localizedDescription)")
                }
                // Return to complete either way so the UI unblocks and the
                // transcript panel reloads the labeled sidecar.
                jobs[fileURL.path] = TranscriptionProgress(fileURL: fileURL, status: .complete, progress: 100, transcriptURL: side)
            }
        } catch {
            if jobs[fileURL.path]?.status != .cancelled {
                jobs[fileURL.path] = TranscriptionProgress(fileURL: fileURL, status: .error, progress: 0, error: error.localizedDescription)
            }
        }
        finishJob(fileURL)
    }

    private func update(_ url: URL, status: TranscriptionJobStatus, progress: Double) {
        jobs[url.path] = TranscriptionProgress(fileURL: url, status: status, progress: progress)
    }
}