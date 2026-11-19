import Foundation

enum RecordingSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case longest = "Longest"
    case largest = "Largest"
    case name = "Name"

    var id: String { rawValue }

    func sorted(_ items: [RecordingItem]) -> [RecordingItem] {
        switch self {
        case .newest: return items.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return items.sorted { $0.createdAt < $1.createdAt }
        case .longest: return items.sorted { $0.duration > $1.duration }
        case .largest: return items.sorted { $0.size > $1.size }
        case .name: return items.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
    }

    /// Recordings whose file name contains every word of `query`, ignoring case.
    static func filter(_ items: [RecordingItem], query: String) -> [RecordingItem] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            words.allSatisfy { item.filename.localizedCaseInsensitiveContains($0) }
        }
    }
}
