import XCTest
@testable import Plume

@MainActor
private final class FakeEngine: TranscriptionEngine {
    let id: String
    let displayName = "Fake"
    let runsOnDevice = true
    var isAvailable = true
    var locales: [Locale]
    var status = EngineAssetStatus.needsDownload
    private(set) var installed: [Locale] = []

    init(id: String = "fake", locales: [String] = ["en-US", "de-DE"]) {
        self.id = id
        self.locales = locales.map { Locale(identifier: $0) }
    }

    func supportedLocales() async -> [Locale] { locales }
    func resolveLocale(_ identifier: String) async -> Locale? {
        locales.first { $0.identifier == identifier }
    }
    func assetStatus(for locale: Locale) async -> EngineAssetStatus { status }
    func installAssets(for locale: Locale) async throws { installed.append(locale) }
    func transcribe(_ fileURL: URL, locale: Locale,
                    report: @escaping @MainActor (TranscriptionJobStatus, Double) -> Void) async throws -> [TimedSegment] {
        []
    }
    func cancel() async {}
}

@MainActor
final class TranscriptionEngineTests: XCTestCase {
    private var savedLanguage = ""
    private var savedEngine = ""

    override func setUp() {
        super.setUp()
        savedLanguage = PreferencesStore.shared.transcriptionLanguage
        savedEngine = PreferencesStore.shared.transcriptionEngineID
    }

    override func tearDown() {
        PreferencesStore.shared.transcriptionLanguage = savedLanguage
        PreferencesStore.shared.transcriptionEngineID = savedEngine
        super.tearDown()
    }

    func testServiceUsesTheChosenEngineWhenItIsAvailable() async {
        let service = TranscriptionService(
            engine: FakeEngine(id: "apple", locales: ["en-US"]),
            alternatives: [FakeEngine(id: "whisper", locales: ["en", "fr"])])
        PreferencesStore.shared.transcriptionEngineID = "whisper"
        let locales = await service.supportedLocales()
        XCTAssertEqual(locales.map(\.identifier), ["en", "fr"])
    }

    func testServiceFallsBackToTheMainEngineWhenTheChosenOneIsNotReady() async {
        let whisper = FakeEngine(id: "whisper", locales: ["en", "fr"])
        whisper.isAvailable = false
        let service = TranscriptionService(engine: FakeEngine(id: "apple", locales: ["en-US"]), alternatives: [whisper])
        PreferencesStore.shared.transcriptionEngineID = "whisper"
        let locales = await service.supportedLocales()
        XCTAssertEqual(locales.map(\.identifier), ["en-US"])
    }

    func testServiceUsesTheMainEngineWhenAppleIsChosen() async {
        let service = TranscriptionService(
            engine: FakeEngine(id: "apple", locales: ["en-US"]),
            alternatives: [FakeEngine(id: "whisper", locales: ["en", "fr"])])
        PreferencesStore.shared.transcriptionEngineID = "apple"
        let locales = await service.supportedLocales()
        XCTAssertEqual(locales.map(\.identifier), ["en-US"])
    }

    func testAnUnknownEngineIdFallsBackToTheMainEngine() async {
        let service = TranscriptionService(engine: FakeEngine(id: "apple", locales: ["en-US"]))
        PreferencesStore.shared.transcriptionEngineID = "does-not-exist"
        let locales = await service.supportedLocales()
        XCTAssertEqual(locales.map(\.identifier), ["en-US"])
    }

    func testServiceListsTheEnginesLanguages() async {
        let service = TranscriptionService(engine: FakeEngine())
        let locales = await service.supportedLocales()
        XCTAssertEqual(locales.map(\.identifier), ["en-US", "de-DE"])
    }

    func testServiceReportsTheEnginesAssetStatusForTheSelectedLanguage() async {
        let engine = FakeEngine()
        let service = TranscriptionService(engine: engine)
        PreferencesStore.shared.transcriptionLanguage = "en-US"

        engine.status = .needsDownload
        let needs = await service.assetStatus()
        XCTAssertEqual(needs, .needsDownload)
        engine.status = .ready
        let ready = await service.assetStatus()
        XCTAssertEqual(ready, .ready)
    }

    func testUnsupportedLanguageHasNoAssetStatusAndCannotBeInstalled() async {
        let service = TranscriptionService(engine: FakeEngine())
        PreferencesStore.shared.transcriptionLanguage = "xx-XX"
        let status = await service.assetStatus()
        XCTAssertNil(status)
        do {
            try await service.installAssets()
            XCTFail("expected localeUnsupported")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .localeUnsupported)
        }
    }

    func testInstallGoesToTheEngineForTheSelectedLanguage() async throws {
        let engine = FakeEngine()
        let service = TranscriptionService(engine: engine)
        PreferencesStore.shared.transcriptionLanguage = "de-DE"
        try await service.installAssets()
        XCTAssertEqual(engine.installed.map(\.identifier), ["de-DE"])
    }

    func testAppleEngineIdentity() {
        let apple = AppleSpeechEngine()
        XCTAssertEqual(apple.id, "apple")
        XCTAssertTrue(apple.runsOnDevice)
    }
}
