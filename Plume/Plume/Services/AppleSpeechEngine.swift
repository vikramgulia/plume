import Foundation
import Speech
import AVFoundation

/// Apple's on-device speech recognition (`SpeechAnalyzer` / `SpeechTranscriber`, macOS 26).
/// Language models are managed by macOS and downloaded on demand through `AssetInventory`.
@MainActor
final class AppleSpeechEngine: TranscriptionEngine {
    let id = "apple"
    let displayName = "Apple Speech"
    let runsOnDevice = true

    private var activeAnalyzer: SpeechAnalyzer?

    var isAvailable: Bool { SpeechTranscriber.isAvailable }

    func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func resolveLocale(_ identifier: String) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier))
    }

    func assetStatus(for locale: Locale) async -> EngineAssetStatus {
        let status = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)])
        switch status {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .downloading: return .downloading
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func installAssets(for locale: Locale) async throws {
        try await install(for: locale, module: SpeechTranscriber(locale: locale, preset: .transcription))
    }

    func transcribe(_ fileURL: URL,
                    locale: Locale,
                    report: @escaping @MainActor (TranscriptionJobStatus, Double) -> Void) async throws -> [TimedSegment] {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.speechUnavailable
        }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        try await ensureAssets(for: locale, module: module, report: report)

        report(.transcribing, -1)
        let audioFile = try AVAudioFile(forReading: fileURL)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        // SpeechAnalyzer transcribes only one channel of stereo input, so
        // transcribe a mono downmix that carries both sides.
        var transcribeURL = fileURL
        var tempMix: URL? = nil
        if audioFile.processingFormat.channelCount > 1 {
            tempMix = try TranscriptionService.writeMonoMixdown(of: audioFile)
            transcribeURL = tempMix!
        }
        defer {
            if let tempMix {
                try? FileManager.default.removeItem(at: tempMix)
            }
        }

        let analyzer = SpeechAnalyzer(modules: [module])
        activeAnalyzer = analyzer
        defer { activeAnalyzer = nil }

        // The results sequence must have a consumer before analyzeSequence runs.
        async let timedSegments = collectResults(from: module, duration: duration, report: report)

        let mixdownFile = try AVAudioFile(forReading: transcribeURL)
        guard let lastSample = try await analyzer.analyzeSequence(from: mixdownFile) else {
            await analyzer.cancelAndFinishNow()
            throw TranscriptionError.emptyAudio
        }
        try await analyzer.finalizeAndFinish(through: lastSample)
        return try await timedSegments
    }

    func cancel() async {
        let analyzer = activeAnalyzer
        activeAnalyzer = nil
        await analyzer?.cancelAndFinishNow()
    }

    // MARK: Internals

    private func collectResults(from module: SpeechTranscriber,
                                duration: Double,
                                report: @MainActor (TranscriptionJobStatus, Double) -> Void) async throws -> [TimedSegment] {
        var segments: [TimedSegment] = []
        for try await result in module.results {
            let chunk = String(result.text.characters)
            if !chunk.isEmpty {
                let start = max(0, result.range.start.seconds)
                let end = result.range.end.seconds
                // Merge chunks that continue the same utterance.
                if let last = segments.last, abs(last.end - start) < 0.5 {
                    segments[segments.count - 1] = TimedSegment(
                        start: last.start, end: max(last.end, end), text: last.text + " " + chunk)
                } else {
                    segments.append(TimedSegment(start: start, end: end, text: chunk))
                }
            }
            if duration > 0, duration.isFinite {
                let fraction = min(100, max(0, result.range.end.seconds / duration * 100))
                report(.transcribing, fraction)
            }
        }
        return segments
    }

    private func ensureAssets(for locale: Locale,
                              module: SpeechTranscriber,
                              report: @MainActor (TranscriptionJobStatus, Double) -> Void) async throws {
        let status = await AssetInventory.status(forModules: [module])
        if status == .supported {
            report(.installingLocale, 0)
            try await install(for: locale, module: module)
        } else if status == .unsupported {
            throw TranscriptionError.localeUnsupported
        }
    }

    private func install(for locale: Locale, module: SpeechTranscriber) async throws {
        guard try await AssetInventory.reserve(locale: locale) else {
            throw TranscriptionError.localeUnsupported
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            throw TranscriptionError.localeUnsupported
        }
        try await request.downloadAndInstall()
    }
}
