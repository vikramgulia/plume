import XCTest
@testable import Plume

final class TranscriptExporterTests: XCTestCase {
    private func seg(_ start: Double, _ end: Double, _ speaker: String, _ text: String) -> LabeledSegment {
        LabeledSegment(start: start, end: end, speakerId: nil, speaker: speaker, text: text)
    }

    private var sample: [LabeledSegment] {
        [
            seg(0, 4, "Alice", "Welcome everyone."),
            seg(4, 9.5, "Alice", "Let's start with the plan."),
            seg(10, 14, "Bob", "Sounds good to me."),
        ]
    }

    func testTimestampFormats() {
        XCTAssertEqual(TranscriptExporter.timestamp(0, separator: ","), "00:00:00,000")
        XCTAssertEqual(TranscriptExporter.timestamp(3725.5, separator: "."), "01:02:05.500")
        XCTAssertEqual(TranscriptExporter.timestamp(-3, separator: ","), "00:00:00,000")
    }

    func testSRTHasNumberedCuesAndSpeakerPrefixOnlyOnTurnChanges() throws {
        let srt = try XCTUnwrap(TranscriptExporter.render(.srt, segments: sample, plainText: "", title: "T", date: Date(), duration: 14))
        XCTAssertTrue(srt.hasPrefix("1\n00:00:00,000 --> 00:00:04,000\nAlice: Welcome everyone.\n\n2\n"))
        XCTAssertTrue(srt.contains("00:00:04,000 --> 00:00:09,500\nLet's start with the plan.\n"), "same speaker: no repeated name")
        XCTAssertTrue(srt.contains("3\n00:00:10,000 --> 00:00:14,000\nBob: Sounds good to me.\n"))
    }

    func testVTTHasHeaderAndVoiceTags() throws {
        let vtt = try XCTUnwrap(TranscriptExporter.render(.vtt, segments: sample, plainText: "", title: "T", date: Date(), duration: 14))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:04.000\n<v Alice>Welcome everyone.\n"))
        XCTAssertTrue(vtt.contains("<v Bob>Sounds good to me."))
    }

    func testVTTEscapesMarkup() throws {
        let vtt = try XCTUnwrap(TranscriptExporter.render(
            .vtt, segments: [seg(0, 2, "R&D", "a < b & c")], plainText: "", title: "T", date: Date(), duration: 2))
        XCTAssertTrue(vtt.contains("<v R&amp;D>a &lt; b &amp; c"))
    }

    func testLongSegmentsAreSplitIntoCuesThatShareTheTime() throws {
        let text = "This is the first sentence of a long answer. This is the second sentence that keeps going for a while. And a third one to finish."
        let cues = TranscriptExporter.cues(from: [seg(10, 40, "Alice", text)])
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { $0.text.count <= 84 })
        XCTAssertEqual(cues.first?.start, 10)
        XCTAssertEqual(try XCTUnwrap(cues.last).end, 40, accuracy: 0.001)
        for (a, b) in zip(cues, cues.dropFirst()) {
            XCTAssertEqual(a.end, b.start, accuracy: 0.001, "cues are contiguous")
        }
        XCTAssertEqual(cues.filter(\.startsTurn).count, 1)
    }

    func testLongCueIsWrappedToTwoLines() {
        let wrapped = TranscriptExporter.wrap("This sentence is long enough that it needs to be wrapped onto two lines.")
        XCTAssertEqual(wrapped.split(separator: "\n").count, 2)
        XCTAssertEqual(TranscriptExporter.wrap("Short text"), "Short text")
    }

    func testMarkdownGroupsConsecutiveSpeakers() throws {
        let md = try XCTUnwrap(TranscriptExporter.render(.markdown, segments: sample, plainText: "", title: "Standup", date: Date(), duration: 14))
        XCTAssertTrue(md.hasPrefix("# Standup\n"))
        XCTAssertTrue(md.contains("**Alice** · 00:00\n\nWelcome everyone. Let's start with the plan.\n"))
        XCTAssertTrue(md.contains("**Bob** · 00:10\n\nSounds good to me."))
        XCTAssertEqual(md.components(separatedBy: "**Alice**").count - 1, 1)
    }

    func testTextFormatKeepsTheSavedLayout() throws {
        let text = try XCTUnwrap(TranscriptExporter.render(.text, segments: sample, plainText: "", title: "T", date: Date(), duration: 14))
        XCTAssertEqual(text, TranscriptionService.renderLabeledText(sample))
    }

    func testTranscriptsWithoutTimingExportAsTextOrMarkdownButNotSubtitles() throws {
        XCTAssertEqual(TranscriptExporter.render(.text, segments: nil, plainText: "just words", title: "T", date: Date(), duration: 0), "just words")
        XCTAssertTrue(try XCTUnwrap(TranscriptExporter.render(.markdown, segments: nil, plainText: "just words", title: "T", date: Date(), duration: 0)).contains("just words"))
        XCTAssertNil(TranscriptExporter.render(.srt, segments: nil, plainText: "just words", title: "T", date: Date(), duration: 0))
        XCTAssertNil(TranscriptExporter.render(.vtt, segments: [], plainText: "just words", title: "T", date: Date(), duration: 0))
    }
}
