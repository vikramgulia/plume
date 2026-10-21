import Foundation
import AVFoundation

struct SpeakerProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var embedding: [Float]
    var sampleFile: String?
}

/// Persistent memory of known speakers. Voice embeddings are matched with
/// cosine similarity so the same person keeps the same label across meetings.
/// Stored locally in Application Support — nothing leaves the Mac.
@MainActor
final class SpeakerLibrary: ObservableObject {
    static let shared = SpeakerLibrary()

    /// Above this cosine similarity a new embedding is treated as the same speaker.
    static let matchThreshold: Float = 0.55

    @Published private(set) var speakers: [SpeakerProfile] = []

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("speakers.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SpeakerProfile].self, from: data) else {
            return
        }
        speakers = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(speakers) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Matching (pure math, unit-testable)

    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (sqrtf(na) * sqrtf(nb))
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    nonisolated static func bestMatch(for embedding: [Float],
                                      in profiles: [SpeakerProfile],
                                      threshold: Float = SpeakerLibrary.matchThreshold) -> (profile: SpeakerProfile, score: Float)? {
        var best: (SpeakerProfile, Float)?
        for p in profiles {
            let score = cosineSimilarity(embedding, p.embedding)
            if score >= threshold, best == nil || score > best!.1 {
                best = (p, score)
            }
        }
        return best
    }

    // MARK: - API

    func profiles() -> [SpeakerProfile] {
        speakers
    }

    func rename(id: UUID, to name: String) {
        guard let idx = speakers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakers[idx].name = trimmed
        save()
    }

    func sampleURL(for profile: SpeakerProfile) -> URL? {
        guard let name = profile.sampleFile else { return nil }
        let url = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func storeSample(id: UUID, samples: [Float], sampleRate: Int = 16000, maxSeconds: Double = 10) {
        guard let idx = speakers.firstIndex(where: { $0.id == id }), !samples.isEmpty else { return }
        let keepFrames = min(samples.count, Int(maxSeconds * Double(sampleRate)))
        let keep = Array(samples.prefix(keepFrames))
        guard !keep.isEmpty else { return }

        let name = "sample-\(id.uuidString).wav"
        let url = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let out = try AVAudioFile(forWriting: url, settings: settings)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(keep.count)) else { return }
            buf.frameLength = AVAudioFrameCount(keep.count)
            keep.withUnsafeBufferPointer { src in
                if let base = src.baseAddress, let dst = buf.floatChannelData?[0] {
                    dst.update(from: base, count: keep.count)
                }
            }
            try out.write(from: buf)
            if let old = speakers[idx].sampleFile, old != name {
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().appendingPathComponent(old))
            }
            speakers[idx].sampleFile = name
            save()
        } catch {
            Diag.log("SPEAKER failed to store sample for \(id): \(error.localizedDescription)")
        }
    }

    func remove(id: UUID) {
        if let profile = speakers.first(where: { $0.id == id }),
           let old = profile.sampleFile {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().appendingPathComponent(old))
        }
        speakers.removeAll { $0.id == id }
        save()
    }

    /// Match against known speakers; create a new profile when nobody matches.
    /// Returns the profile the embedding belongs to.
    @discardableResult
    func upsert(embedding: [Float]) -> SpeakerProfile {
        if let (match, score) = Self.bestMatch(for: embedding, in: speakers) {
            Diag.log("SPEAKER matched '\(match.name)' score=\(score)")
            return match
        }
        let n = speakers.count + 1
        let profile = SpeakerProfile(id: UUID(), name: "Speaker \(n)", embedding: embedding)
        speakers.append(profile)
        save()
        Diag.log("SPEAKER created '\(profile.name)'")
        return profile
    }

    func updateEmbedding(id: UUID, embedding: [Float]) {
        guard let idx = speakers.firstIndex(where: { $0.id == id }) else { return }
        let old = speakers[idx].embedding
        guard old.count == embedding.count, !old.isEmpty else {
            speakers[idx].embedding = embedding
            save()
            return
        }
        // Equal-weight blend keeps the profile stable as more meetings arrive.
        var blended: [Float] = []
        blended.reserveCapacity(old.count)
        for i in 0..<old.count {
            blended.append((old[i] + embedding[i]) / 2)
        }
        speakers[idx].embedding = blended
        save()
    }

    func reset() {
        speakers.removeAll()
        save()
    }
}