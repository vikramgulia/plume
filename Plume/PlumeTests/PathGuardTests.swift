import XCTest
@testable import Plume

final class PathGuardTests: XCTestCase {
    func testSidecarPath() {
        let audio = URL(fileURLWithPath: "/Users/test/Plume/foo.m4a")
        let side = PathGuard.sidecarURL(for: audio, ext: "txt")
        XCTAssertEqual(side.path, "/Users/test/Plume/foo.txt")
    }

    func testAssertUnderSaveFolderAllowsChild() throws {
        let root = URL(fileURLWithPath: "/Users/test/Plume")
        let child = URL(fileURLWithPath: "/Users/test/Plume/Recording.m4a")
        let resolved = try PathGuard.assertAudioFile(child, saveFolder: root)
        XCTAssertEqual(resolved.path, child.path)
    }

    func testAssertUnderSaveFolderRejectsOutside() {
        let root = URL(fileURLWithPath: "/Users/test/Plume")
        let outside = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertThrowsError(try PathGuard.assertUnderSaveFolder(outside, saveFolder: root))
    }

    func testRenameCollision() {
        let dir = URL(fileURLWithPath: "/Users/test/Plume")
        let old = dir.appendingPathComponent("old.m4a")
        let taken = dir.appendingPathComponent("New Name.m4a")
        let target = PathGuard.resolveRenameTarget(
            dir: dir,
            oldURL: old,
            newName: "New Name",
            ext: "m4a",
            exists: { $0 == taken }
        )
        XCTAssertEqual(target.lastPathComponent, "New Name (1).m4a")
    }
}

final class AudioFileWriterTests: XCTestCase {
    func testWavHeaderIs44BytesAndLittleEndian() {
        let header = AudioFileWriter.wavHeader(dataBytes: 1600)
        XCTAssertEqual(header.count, 44)
        XCTAssertEqual(String(data: header.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: header.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        // float32 stereo: format tag 3, channels 2
        XCTAssertEqual(header[20], 3)
        XCTAssertEqual(header[22], 2)
        XCTAssertEqual(header[24], 0x80) // 48000 little-endian low byte
    }
}
