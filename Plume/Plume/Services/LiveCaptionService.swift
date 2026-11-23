import Foundation
import Speech
import AVFoundation

enum CaptionSource: Equatable {
    /// Sound from the Mac (the other people in a call).
    case others
    /// The microphone (you).
    case you

    var label: String { self == .you ? "You" : "Others" }
}

struct CaptionLine: Identifiable, Equatable {
    let id = UUID()
    let source: CaptionSource
    var text: String
    var isFinal: Bool
}

/// Keeps the caption lines. One in-progress ("volatile") line per source is updated in place
/// until the recognizer finalizes it. Pure logic, so it can be tested without any audio.
struct CaptionLog: Equatable {
    static let maxLines = 60
    private(set) var lines: [CaptionLine] = []
    private var open: [CaptionSource: UUID] = [:]

    mutating func apply(_ text: String, isFinal: Bool, source: CaptionSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = open[source], let i = lines.firstIndex(where: { $0.id == id }) {
            if trimmed.isEmpty {
                if isFinal { lines.remove(at: i); open[source] = nil }
                return
            }
            lines[i].text = trimmed
            lines[i].isFinal = isFinal
            if isFinal { open[source] = nil }
        } else if !trimmed.isEmpty {
            let line = CaptionLine(source: source, text: trimmed, isFinal: isFinal)
            lines.append(line)
            if !isFinal { open[source] = line.id }
            if lines.count > Self.maxLines {
                let dropped = lines.removeFirst()
                if open[dropped.source] == dropped.id { open[dropped.source] = nil }
            }
        }
    }

    /// Everything said so far, one line per caption, for copying.
    var plainText: String {
        lines.map { "\($0.source.label): \($0.text)" }.joined(separator: "\n")
    }
}

/// Live captions while recording, using Apple's on-device `SpeechAnalyzer`.
/// One analyzer runs per channel, so every line is labelled You or Others without speaker detection.
@MainActor
final class LiveCaptionService: ObservableObject {
    @Published private(set) var log = CaptionLog()
    @Published private(set) var isRunning = false
    /// Why captions could not start (shown once as a notice).
    var onProblem: ((String) -> Void)?

    private var channels: [CaptionSource: LiveCaptionChannel] = [:]

    /// Starts one analyzer for each of `sources`. Does nothing if already running.
    func start(sources: [CaptionSource], language: String) async {
        guard !isRunning else { return }
        guard SpeechTranscriber.isAvailable else {
            onProblem?("Live captions are not available on this Mac.")
            return
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            onProblem?("Live captions do not support the selected language. Change it in Settings → Transcription.")
            return
        }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        guard await AssetInventory.status(forModules: [probe]) == .installed else {
            onProblem?("Install the language in Settings → Transcription to use live captions.")
            return
        }
        log = CaptionLog()
        isRunning = true
        for source in sources {
            let channel = LiveCaptionChannel(locale: locale) { [weak self] text, isFinal in
                Task { @MainActor in self?.log.apply(text, isFinal: isFinal, source: source) }
            }
            channels[source] = channel
            do {
                try await channel.start()
            } catch {
                channels[source] = nil
                onProblem?("Live captions could not start: \(error.localizedDescription)")
            }
        }
        if channels.isEmpty { isRunning = false }
    }

    /// Feeds 48 kHz mono Float32 audio from a capture source.
    func feed(_ data: Data, source: CaptionSource) {
        channels[source]?.feed(data)
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        let active = channels
        channels = [:]
        for channel in active.values { await channel.finish() }
    }
}

/// One `SpeechAnalyzer` fed with one channel's audio.
@MainActor
final class LiveCaptionChannel {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let onResult: @Sendable (String, Bool) -> Void
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!

    init(locale: Locale, onResult: @escaping @Sendable (String, Bool) -> Void) {
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults], attributeOptions: [])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        self.onResult = onResult
    }

    func start() async throws {
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        targetFormat = format
        if let format, format != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: format)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation

        let transcriber = self.transcriber
        let onResult = self.onResult
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    onResult(String(result.text.characters), result.isFinal)
                }
            } catch {
                Diag.log("LIVE results ended: \(error.localizedDescription)")
            }
        }
        try await analyzer.start(inputSequence: stream)
    }

    func feed(_ data: Data) {
        let frames = data.count / MemoryLayout<Float>.size
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Float.self).baseAddress { dst.update(from: base, count: frames) }
        }
        guard let converter, let targetFormat else {
            continuation?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            continuation?.yield(AnalyzerInput(buffer: out))
        }
    }

    func finish() async {
        continuation?.finish()
        continuation = nil
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        resultsTask = nil
    }
}
