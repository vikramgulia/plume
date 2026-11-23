import XCTest
@testable import Plume

final class WhisperEngineTests: XCTestCase {
    // MARK: Languages

    func testLocaleIdentifiersMapToWhisperCodes() {
        XCTAssertEqual(WhisperLanguages.code(forLocaleIdentifier: "en-US", englishOnly: false), "en")
        XCTAssertEqual(WhisperLanguages.code(forLocaleIdentifier: "de-DE", englishOnly: false), "de")
        XCTAssertEqual(WhisperLanguages.code(forLocaleIdentifier: "zh-Hans", englishOnly: false), "zh")
        XCTAssertEqual(WhisperLanguages.code(forLocaleIdentifier: "nb-NO", englishOnly: false), "no")
        XCTAssertEqual(WhisperLanguages.code(forLocaleIdentifier: "es-419", englishOnly: false), "es")
        XCTAssertNil(WhisperLanguages.code(forLocaleIdentifier: "tlh", englishOnly: false))
    }

    func testEnglishOnlyModelsAcceptOnlyEnglish() {
        XCTAssertEqual(WhisperLanguages.code(forLocaleIdentifier: "en-GB", englishOnly: true), "en")
        XCTAssertNil(WhisperLanguages.code(forLocaleIdentifier: "de-DE", englishOnly: true))
    }

    func testLanguageListIsCompleteAndUnique() {
        XCTAssertEqual(Set(WhisperLanguages.codes).count, WhisperLanguages.codes.count)
        XCTAssertEqual(WhisperLanguages.codes.count, 99)
        XCTAssertEqual(WhisperLanguages.codes.first, "en")
    }

    // MARK: Segments

    func testSegmentTimesComeFromSampleOffsetsAt16kHz() throws {
        let segment = try XCTUnwrap(WhisperDecoder.timedSegment(startSample: 16_000, sampleCount: 8_000, text: "  Hello there.  "))
        XCTAssertEqual(segment.start, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segment.end, 1.5, accuracy: 0.0001)
        XCTAssertEqual(segment.text, "Hello there.")
    }

    func testEmptyAndSymbolOnlyTextIsDropped() {
        XCTAssertNil(WhisperDecoder.timedSegment(startSample: 0, sampleCount: 16_000, text: ""))
        XCTAssertNil(WhisperDecoder.timedSegment(startSample: 0, sampleCount: 16_000, text: "   "))
        XCTAssertNil(WhisperDecoder.timedSegment(startSample: 0, sampleCount: 16_000, text: "..."))
        XCTAssertNil(WhisperDecoder.timedSegment(startSample: 0, sampleCount: 16_000, text: "♪ ♪"))
        XCTAssertNotNil(WhisperDecoder.timedSegment(startSample: 0, sampleCount: 16_000, text: "42"))
    }

    // MARK: Cancel flag

    func testCancelFlagSetsAndResets() {
        let flag = CancelFlag()
        XCTAssertFalse(flag.isSet)
        flag.set()
        XCTAssertTrue(flag.isSet)
        flag.reset()
        XCTAssertFalse(flag.isSet)
    }

    // MARK: Engine readiness

    @MainActor
    func testEngineIsNotAvailableWithoutAnInstalledModel() throws {
        let root = PathGuard.appTempDirectory.appendingPathComponent("plume-whisper-engine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = WhisperEngine(store: WhisperModelStore(root: root))
        XCTAssertFalse(engine.isAvailable)
        XCTAssertEqual(engine.id, "whisper")
        XCTAssertTrue(engine.runsOnDevice)
    }

    @MainActor
    func testAssetStatusReflectsTheStore() async throws {
        let root = PathGuard.appTempDirectory.appendingPathComponent("plume-whisper-engine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root)
        let engine = WhisperEngine(store: store)
        let saved = PreferencesStore.shared.whisperModelID
        defer { PreferencesStore.shared.whisperModelID = saved }
        PreferencesStore.shared.whisperModelID = "base"
        let model = try XCTUnwrap(WhisperModelCatalog.model(id: "base"))

        let before = await engine.assetStatus(for: Locale(identifier: "en"))
        XCTAssertEqual(before, .needsDownload)

        try FileManager.default.createDirectory(at: store.directory(for: model), withIntermediateDirectories: true)
        let files = store.files(for: model)
        for url in [files.encoder, files.decoder, files.tokens] { try Data("x".utf8).write(to: url) }
        store.refresh()
        let after = await engine.assetStatus(for: Locale(identifier: "en"))
        XCTAssertEqual(after, .ready)
    }

    @MainActor
    func testEnglishOnlyModelOffersOnlyEnglish() async {
        let engine = WhisperEngine(store: WhisperModelStore(root: PathGuard.appTempDirectory.appendingPathComponent("plume-we-\(UUID().uuidString)")))
        let saved = PreferencesStore.shared.whisperModelID
        defer { PreferencesStore.shared.whisperModelID = saved }

        PreferencesStore.shared.whisperModelID = "small.en"
        let english = await engine.supportedLocales()
        XCTAssertEqual(english.map(\.identifier), ["en"])
        let german = await engine.resolveLocale("de-DE")
        XCTAssertNil(german)

        PreferencesStore.shared.whisperModelID = "small"
        let many = await engine.supportedLocales()
        XCTAssertEqual(many.count, 99)
        let resolved = await engine.resolveLocale("de-DE")
        XCTAssertEqual(resolved?.identifier, "de")
    }
}
