import Foundation

/// Thread-safe flag the decoder checks between chunks, so a transcription can be cancelled.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}

/// Whisper speech recognition on the Mac, through the sherpa-onnx library already used for speaker
/// labels. A voice activity detector cuts the recording into speech chunks of at most 25 seconds
/// (Whisper works on 30-second windows), and each chunk is transcribed on its own, which also gives
/// every piece of text a start and end time.
@MainActor
final class WhisperEngine: TranscriptionEngine {
    let id = "whisper"
    let displayName = "Whisper"
    let runsOnDevice = true

    private let store: WhisperModelStore
    private let prefs = PreferencesStore.shared
    private let cancelFlag = CancelFlag()

    init(store: WhisperModelStore) {
        self.store = store
    }

    convenience init() {
        self.init(store: WhisperModelStore.shared)
    }

    var selectedModel: WhisperModel? {
        WhisperModelCatalog.model(id: prefs.whisperModelID)
    }

    /// Ready to transcribe: the chosen model is installed and the speech detector is bundled.
    var isAvailable: Bool {
        guard let model = selectedModel, store.isInstalled(model) else { return false }
        return BundledModels.sileroVAD != nil
    }

    func supportedLocales() async -> [Locale] {
        let multilingual = selectedModel?.isMultilingual ?? true
        return (multilingual ? WhisperLanguages.codes : ["en"]).map { Locale(identifier: $0) }
    }

    func resolveLocale(_ identifier: String) async -> Locale? {
        let englishOnly = !(selectedModel?.isMultilingual ?? true)
        return WhisperLanguages.code(forLocaleIdentifier: identifier, englishOnly: englishOnly).map { Locale(identifier: $0) }
    }

    func assetStatus(for locale: Locale) async -> EngineAssetStatus {
        guard let model = selectedModel else { return .unsupported }
        switch store.state(for: model) {
        case .installed: return .ready
        case .downloading, .verifying, .unpacking: return .downloading
        case .notInstalled, .failed: return .needsDownload
        }
    }

    /// Downloads the chosen model and waits for it. The app only calls this after the user agrees.
    func installAssets(for locale: Locale) async throws {
        guard let model = selectedModel else { throw TranscriptionError.modelMissing }
        store.startInstall(model)
        while true {
            switch store.state(for: model) {
            case .installed:
                return
            case .failed(let message):
                throw TranscriptionError.modelInstallFailed(message)
            case .notInstalled:
                throw CancellationError()
            case .downloading, .verifying, .unpacking:
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func transcribe(_ fileURL: URL,
                    locale: Locale,
                    report: @escaping @MainActor (TranscriptionJobStatus, Double) -> Void) async throws -> [TimedSegment] {
        guard let model = selectedModel, store.isInstalled(model), let vad = BundledModels.sileroVAD else {
            throw TranscriptionError.modelMissing
        }
        let files = store.files(for: model)
        let language = WhisperLanguages.code(forLocaleIdentifier: locale.identifier, englishOnly: !model.isMultilingual) ?? ""
        let job = WhisperDecoder.Job(
            encoder: files.encoder.path, decoder: files.decoder.path, tokens: files.tokens.path,
            vad: vad.path, language: language)

        cancelFlag.reset()
        let flag = cancelFlag
        report(.transcribing, -1)
        return try await Task.detached(priority: .userInitiated) {
            try WhisperDecoder.run(job: job, file: fileURL, cancelled: { flag.isSet }) { fraction in
                Task { @MainActor in report(.transcribing, fraction * 100) }
            }
        }.value
    }

    func cancel() async {
        cancelFlag.set()
    }
}

/// The part of Whisper transcription that runs off the main thread.
enum WhisperDecoder {
    struct Job: Sendable {
        let encoder: String
        let decoder: String
        let tokens: String
        let vad: String
        /// Whisper's language code, or empty to let the model detect it.
        let language: String
    }

    private static let sampleRate = 16_000
    private static let vadWindow = 512

    nonisolated static func run(job: Job,
                                file: URL,
                                cancelled: @Sendable () -> Bool,
                                progress: @Sendable (Double) -> Void) throws -> [TimedSegment] {
        let samples = try AudioFileReader.readMono16k(from: file)
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }

        // 1. Cut the recording into chunks of speech.
        var vadConfig = sherpaOnnxVadModelConfig(
            sileroVad: sherpaOnnxSileroVadModelConfig(
                model: job.vad, threshold: 0.5, minSilenceDuration: 0.5, minSpeechDuration: 0.25,
                windowSize: vadWindow, maxSpeechDuration: 25),
            sampleRate: Int32(sampleRate), numThreads: 1, provider: "cpu", debug: 0)
        guard let detector = SherpaOnnxVoiceActivityDetectorWrapper(config: &vadConfig, buffer_size_in_seconds: 60) else {
            throw TranscriptionError.engineFailed("the speech detector could not start")
        }
        var chunks: [(start: Int, samples: [Float])] = []
        func collect() {
            while !detector.isEmpty() {
                if let segment = detector.front() {
                    chunks.append((segment.start, segment.samples))
                }
                detector.pop()
            }
        }
        var position = 0
        while position < samples.count {
            if cancelled() { throw CancellationError() }
            let end = min(position + vadWindow, samples.count)
            detector.acceptWaveform(samples: Array(samples[position..<end]))
            collect()
            position = end
        }
        detector.flush()
        collect()
        guard !chunks.isEmpty else { return [] }

        // 2. Load the model.
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 80),
            modelConfig: sherpaOnnxOfflineModelConfig(
                tokens: job.tokens,
                whisper: sherpaOnnxOfflineWhisperModelConfig(
                    encoder: job.encoder, decoder: job.decoder, language: job.language,
                    task: "transcribe", tailPaddings: -1),
                numThreads: threads, provider: "cpu", debug: 0, modelType: "whisper"))
        guard let recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig) else {
            throw TranscriptionError.engineFailed("the Whisper model could not be loaded; try downloading it again")
        }

        // 3. Transcribe each chunk.
        var segments: [TimedSegment] = []
        for chunk in chunks {
            if cancelled() { throw CancellationError() }
            if let result = recognizer.decode(samples: chunk.samples, sampleRate: sampleRate),
               let segment = timedSegment(startSample: chunk.start, sampleCount: chunk.samples.count, text: result.text) {
                segments.append(segment)
            }
            progress(Double(chunk.start + chunk.samples.count) / Double(samples.count))
        }
        return segments
    }

    /// A transcript segment for a chunk, or nil when Whisper produced nothing worth keeping
    /// (empty text, or only punctuation and symbols).
    nonisolated static func timedSegment(startSample: Int, sampleCount: Int, text: String) -> TimedSegment? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let start = Double(startSample) / Double(sampleRate)
        return TimedSegment(start: start, end: start + Double(sampleCount) / Double(sampleRate), text: trimmed)
    }
}
