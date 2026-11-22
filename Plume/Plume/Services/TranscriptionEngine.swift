import Foundation

/// Whether an engine has what it needs to transcribe a language.
enum EngineAssetStatus: Equatable {
    case ready
    case needsDownload
    case downloading
    case unsupported
}

/// A speech-to-text engine. `TranscriptionService` owns the queue, progress, speaker labelling and
/// the saved files; an engine only turns one audio file into timed text.
@MainActor
protocol TranscriptionEngine: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// False for engines that send audio off the Mac. Those must never run without explicit consent.
    var runsOnDevice: Bool { get }
    var isAvailable: Bool { get }

    func supportedLocales() async -> [Locale]
    /// The engine's own locale closest to a language identifier such as "en-US", or nil if unsupported.
    func resolveLocale(_ identifier: String) async -> Locale?
    func assetStatus(for locale: Locale) async -> EngineAssetStatus
    func installAssets(for locale: Locale) async throws

    /// Transcribes `fileURL` and returns timed segments. `report` receives the stage and a percentage
    /// (-1 when unknown) as the work goes.
    func transcribe(_ fileURL: URL,
                    locale: Locale,
                    report: @escaping @MainActor (TranscriptionJobStatus, Double) -> Void) async throws -> [TimedSegment]

    /// Stops a transcription that is running.
    func cancel() async
}
