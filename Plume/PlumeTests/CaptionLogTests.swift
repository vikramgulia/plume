import XCTest
@testable import Plume

final class CaptionLogTests: XCTestCase {
    func testInProgressTextIsUpdatedInPlaceThenFinalized() {
        var log = CaptionLog()
        log.apply("hel", isFinal: false, source: .you)
        log.apply("hello wor", isFinal: false, source: .you)
        XCTAssertEqual(log.lines.count, 1)
        log.apply("Hello world.", isFinal: true, source: .you)
        XCTAssertEqual(log.lines.map(\.text), ["Hello world."])
        XCTAssertEqual(log.lines.first?.isFinal, true)
    }

    func testNextUtteranceStartsANewLine() {
        var log = CaptionLog()
        log.apply("One.", isFinal: true, source: .you)
        log.apply("Two", isFinal: false, source: .you)
        XCTAssertEqual(log.lines.map(\.text), ["One.", "Two"])
    }

    func testEachSourceKeepsItsOwnInProgressLine() {
        var log = CaptionLog()
        log.apply("from me", isFinal: false, source: .you)
        log.apply("from them", isFinal: false, source: .others)
        log.apply("from me now", isFinal: false, source: .you)
        XCTAssertEqual(log.lines.map(\.text), ["from me now", "from them"])
        XCTAssertEqual(log.lines.map(\.source), [.you, .others])
    }

    func testEmptyResultsAddNothingAndClearAnEmptiedLine() {
        var log = CaptionLog()
        log.apply("  ", isFinal: false, source: .you)
        XCTAssertTrue(log.lines.isEmpty)
        log.apply("um", isFinal: false, source: .you)
        log.apply("", isFinal: true, source: .you)
        XCTAssertTrue(log.lines.isEmpty)
    }

    func testOldLinesAreDropped() {
        var log = CaptionLog()
        for i in 0..<(CaptionLog.maxLines + 5) { log.apply("line \(i)", isFinal: true, source: .others) }
        XCTAssertEqual(log.lines.count, CaptionLog.maxLines)
        XCTAssertEqual(log.lines.first?.text, "line 5")
    }

    func testPlainTextLabelsEachLine() {
        var log = CaptionLog()
        log.apply("Hi", isFinal: true, source: .others)
        log.apply("Hello", isFinal: true, source: .you)
        XCTAssertEqual(log.plainText, "Others: Hi\nYou: Hello")
    }
}
