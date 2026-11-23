import Foundation

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case text, markdown, srt, vtt

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        case .vtt: return "vtt"
        }
    }

    var menuTitle: String {
        switch self {
        case .text: return "Plain text (.txt)"
        case .markdown: return "Markdown (.md)"
        case .srt: return "Subtitles (.srt)"
        case .vtt: return "Subtitles (.vtt)"
        }
    }

    /// Subtitle formats need the timed segments saved with the transcript.
    var needsTimestamps: Bool { self == .srt || self == .vtt }
}

/// One subtitle cue: a short, readable piece of a transcript segment.
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
    /// First cue after the speaker changed.
    let startsTurn: Bool
}

enum TranscriptExporter {
    /// The transcript in `format`, or nil when the format needs timed segments and there are none
    /// (a transcript saved without speaker/timing data can still be exported as text or Markdown).
    static func render(_ format: TranscriptFormat,
                       segments: [LabeledSegment]?,
                       plainText: String,
                       title: String,
                       date: Date,
                       duration: TimeInterval) -> String? {
        let timed = segments?.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        switch format {
        case .text:
            return timed.isEmpty ? plainText : TranscriptionService.renderLabeledText(timed)
        case .markdown:
            return markdown(segments: timed, plainText: plainText, title: title, date: date, duration: duration)
        case .srt:
            return timed.isEmpty ? nil : srt(cues(from: timed))
        case .vtt:
            return timed.isEmpty ? nil : vtt(cues(from: timed))
        }
    }

    // MARK: Markdown

    static func markdown(segments: [LabeledSegment], plainText: String, title: String, date: Date, duration: TimeInterval) -> String {
        var out = "# \(title)\n\n"
        out += "\(date.formatted(date: .long, time: .shortened))"
        if duration > 0 { out += " · \(TranscriptionService.clockString(duration))" }
        out += "\n\n"
        guard !segments.isEmpty else {
            return out + plainText + "\n"
        }
        // One paragraph per run of segments from the same speaker.
        var index = 0
        while index < segments.count {
            let first = segments[index]
            var texts = [first.text.trimmingCharacters(in: .whitespacesAndNewlines)]
            var next = index + 1
            while next < segments.count, segments[next].speaker == first.speaker {
                texts.append(segments[next].text.trimmingCharacters(in: .whitespacesAndNewlines))
                next += 1
            }
            let when = TranscriptionService.clockString(first.start)
            let heading = first.speaker.isEmpty ? "**\(when)**" : "**\(first.speaker)** · \(when)"
            out += "\(heading)\n\n\(texts.joined(separator: " "))\n\n"
            index = next
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: Subtitles

    /// Splits segments into cues of at most `maxChars` characters, breaking at word boundaries
    /// (and after sentence ends when the cue is already a reasonable length). Each segment's time
    /// range is shared out between its cues in proportion to their length.
    static func cues(from segments: [LabeledSegment], maxChars: Int = 84) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var lastSpeaker: String?
        for segment in segments {
            let pieces = split(segment.text, maxChars: maxChars)
            guard !pieces.isEmpty else { continue }
            let totalChars = Double(pieces.reduce(0) { $0 + $1.count })
            let span = max(segment.end - segment.start, 0.3 * Double(pieces.count))
            var cursor = segment.start
            for (i, piece) in pieces.enumerated() {
                let end = i == pieces.count - 1 ? segment.start + span : cursor + span * Double(piece.count) / totalChars
                out.append(SubtitleCue(start: cursor, end: end, speaker: segment.speaker, text: piece,
                                       startsTurn: i == 0 && segment.speaker != lastSpeaker))
                cursor = end
            }
            lastSpeaker = segment.speaker
        }
        return out
    }

    static func split(_ text: String, maxChars: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var pieces: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > maxChars, !current.isEmpty {
                pieces.append(current)
                current = word
            } else {
                current = candidate
            }
            if let last = current.last, ".?!".contains(last), current.count >= 24 {
                pieces.append(current)
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Breaks a long cue into two balanced lines at the space nearest the middle.
    static func wrap(_ text: String, lineLength: Int = 42) -> String {
        guard text.count > lineLength else { return text }
        let chars = Array(text)
        let middle = chars.count / 2
        let spaces = chars.indices.filter { chars[$0] == " " }
        guard let split = spaces.min(by: { abs($0 - middle) < abs($1 - middle) }) else { return text }
        return String(chars[..<split]) + "\n" + String(chars[(split + 1)...])
    }

    static func timestamp(_ seconds: Double, separator: Character) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, String(separator), ms % 1000)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            let prefix = cue.startsTurn && !cue.speaker.isEmpty ? "\(cue.speaker): " : ""
            out += "\(i + 1)\n"
            out += "\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n"
            out += wrap(prefix + cue.text) + "\n\n"
        }
        return out
    }

    static func vtt(_ cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n"
            let text = wrap(escapeVTT(cue.text))
            if cue.speaker.isEmpty {
                out += text + "\n\n"
            } else {
                out += "<v \(escapeVTT(cue.speaker))>\(text)\n\n"
            }
        }
        return out
    }

    private static func escapeVTT(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
