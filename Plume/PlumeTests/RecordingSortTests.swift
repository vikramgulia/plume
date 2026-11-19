import XCTest
@testable import Plume

final class RecordingSortTests: XCTestCase {
    private func item(_ name: String, minutesAgo: Double, duration: TimeInterval, size: Int64) -> RecordingItem {
        RecordingItem(
            fileURL: URL(fileURLWithPath: "/tmp/\(name).m4a"),
            filename: "\(name).m4a",
            createdAt: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60),
            size: size,
            duration: duration,
            transcriptURL: nil)
    }

    private var items: [RecordingItem] {
        [
            item("Standup", minutesAgo: 10, duration: 300, size: 5_000),
            item("Planning 2", minutesAgo: 60, duration: 3_600, size: 90_000),
            item("Planning 10", minutesAgo: 30, duration: 1_200, size: 20_000),
        ]
    }

    func testSortOrders() {
        XCTAssertEqual(RecordingSort.newest.sorted(items).map(\.filename), ["Standup.m4a", "Planning 10.m4a", "Planning 2.m4a"])
        XCTAssertEqual(RecordingSort.oldest.sorted(items).map(\.filename), ["Planning 2.m4a", "Planning 10.m4a", "Standup.m4a"])
        XCTAssertEqual(RecordingSort.longest.sorted(items).first?.filename, "Planning 2.m4a")
        XCTAssertEqual(RecordingSort.largest.sorted(items).first?.filename, "Planning 2.m4a")
    }

    func testNameSortIsNumericAware() {
        XCTAssertEqual(RecordingSort.name.sorted(items).map(\.filename), ["Planning 2.m4a", "Planning 10.m4a", "Standup.m4a"])
    }

    func testFilterMatchesEveryWordIgnoringCase() {
        XCTAssertEqual(RecordingSort.filter(items, query: "plan").count, 2)
        XCTAssertEqual(RecordingSort.filter(items, query: "PLANNING 10").map(\.filename), ["Planning 10.m4a"])
        XCTAssertEqual(RecordingSort.filter(items, query: "nothing").count, 0)
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(RecordingSort.filter(items, query: "  ").count, 3)
    }
}
