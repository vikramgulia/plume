import XCTest
import CryptoKit
@testable import Plume

@MainActor
final class WhisperModelStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = PathGuard.appTempDirectory
            .appendingPathComponent("plume-whisper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Catalog

    func testCatalogEntriesAreWellFormed() {
        let models = WhisperModelCatalog.models
        XCTAssertEqual(Set(models.map(\.id)).count, models.count, "ids are unique")
        for model in models {
            XCTAssertEqual(model.archiveURL.scheme, "https", model.id)
            XCTAssertEqual(model.archiveURL.host, "github.com", model.id)
            XCTAssertEqual(model.sha256.count, 64, model.id)
            XCTAssertTrue(model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, model.id)
            XCTAssertGreaterThan(model.archiveBytes, 100_000_000, model.id)
            XCTAssertGreaterThan(model.installedBytes, 100_000_000, model.id)
            XCTAssertTrue((1...5).contains(model.accuracy) && (1...5).contains(model.speed), model.id)
            XCTAssertEqual(model.archiveMembers.count, 3)
            XCTAssertTrue(model.encoderFile.hasSuffix(".int8.onnx") && model.decoderFile.hasSuffix(".int8.onnx"), model.id)
        }
    }

    func testDefaultsExistAndMatchTheirLanguageScope() throws {
        let multi = try XCTUnwrap(WhisperModelCatalog.model(id: WhisperModelCatalog.defaultMultilingual))
        let english = try XCTUnwrap(WhisperModelCatalog.model(id: WhisperModelCatalog.defaultEnglishOnly))
        XCTAssertTrue(multi.isMultilingual)
        XCTAssertFalse(english.isMultilingual)
        XCTAssertNil(WhisperModelCatalog.model(id: "nope"))
    }

    // MARK: Checksum

    func testSHA256MatchesKnownValues() throws {
        let empty = dir.appendingPathComponent("empty")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertEqual(try WhisperModelStore.sha256(of: empty),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let abc = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(try WhisperModelStore.sha256(of: abc),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256ReadsFilesLargerThanOneChunk() throws {
        let big = dir.appendingPathComponent("big")
        let data = Data(repeating: 7, count: 9 * 1024 * 1024 + 123)
        try data.write(to: big)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try WhisperModelStore.sha256(of: big), expected)
    }

    // MARK: Unpacking

    func testExtractUnpacksOnlyTheRequestedMembers() throws {
        let source = dir.appendingPathComponent("src/model-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("encoder".utf8).write(to: source.appendingPathComponent("enc.onnx"))
        try Data("big unused".utf8).write(to: source.appendingPathComponent("unused.onnx"))
        try Data("tokens".utf8).write(to: source.appendingPathComponent("tokens.txt"))

        let archive = dir.appendingPathComponent("m.tar.bz2")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cjf", archive.path, "-C", dir.appendingPathComponent("src").path, "model-folder"]
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let out = dir.appendingPathComponent("out")
        try WhisperModelStore.extract(archive: archive, members: ["model-folder/enc.onnx", "model-folder/tokens.txt"], into: out)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("model-folder/enc.onnx"), encoding: .utf8), "encoder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("model-folder/tokens.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("model-folder/unused.onnx").path))
    }

    func testExtractReportsAMissingMember() {
        let archive = dir.appendingPathComponent("not-an-archive.tar.bz2")
        try? Data("garbage".utf8).write(to: archive)
        XCTAssertThrowsError(try WhisperModelStore.extract(archive: archive, members: ["x"], into: dir.appendingPathComponent("o")))
    }

    // MARK: Store state

    func testInstalledStateFollowsTheFilesOnDisk() throws {
        let store = WhisperModelStore(root: dir.appendingPathComponent("models"))
        let model = try XCTUnwrap(WhisperModelCatalog.model(id: "small"))
        XCTAssertEqual(store.state(for: model), .notInstalled)
        XCTAssertTrue(store.installedModels.isEmpty)

        let files = store.files(for: model)
        try FileManager.default.createDirectory(at: store.directory(for: model), withIntermediateDirectories: true)
        for url in [files.encoder, files.decoder, files.tokens] { try Data("x".utf8).write(to: url) }
        store.refresh()
        XCTAssertEqual(store.state(for: model), .installed)
        XCTAssertEqual(store.installedModels.map(\.id), ["small"])

        store.remove(model)
        XCTAssertEqual(store.state(for: model), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(for: model).path))
    }

    func testAPartialInstallIsNotInstalled() throws {
        let store = WhisperModelStore(root: dir.appendingPathComponent("models"))
        let model = try XCTUnwrap(WhisperModelCatalog.model(id: "base"))
        try FileManager.default.createDirectory(at: store.directory(for: model), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.files(for: model).encoder)
        XCTAssertFalse(store.isInstalled(model))
    }
}
