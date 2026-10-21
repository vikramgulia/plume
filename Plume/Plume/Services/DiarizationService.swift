import Foundation
import CoreMedia
import AVFoundation

struct SpeakerTurn {
    let start: Double
    let end: Double
    let cluster: Int
}

enum DiarizationError: LocalizedError {
    case modelsMissing
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            return "Speaker diarization models are not bundled."
        case .noSpeech:
            return "Not enough distinct speech to identify speakers."
        }
    }
}

/// On-device speaker diarization via sherpa-onnx: segmentation + embedding +
/// clustering produce who-spoke-when; per-cluster embeddings are matched
/// against SpeakerLibrary so labels persist across recordings.
///
/// Stereo recordings are diarized by channel — system output (remote voices)
/// through the full pipeline, mic channel via energy VAD — because averaging
/// the two acoustic paths together makes the clusterer over-split the same
/// voice into dozens of fragments (157 clusters on a 62-min meeting).
@MainActor
final class DiarizationService: ObservableObject {
    static let shared = DiarizationService()

    /// Cluster id reserved for the mic side of stereo recordings — a single
    /// physical voice (the user's microphone), so it bypasses segmentation.
    nonisolated static let micCluster = 1000
    /// A system-cluster embedding close to the mic embedding is the user's own
    /// voice leaking back through the meeting — merge it into the mic cluster.
    nonisolated static let echoMergeThreshold: Float = 0.65
    /// Cluster fragments of one voice re-merge at the identity criterion — the
    /// same cosine threshold SpeakerLibrary uses to recognize a speaker (on a
    /// real 62-min meeting this took 41 system clusters down to 6 speakers).
    nonisolated static let clusterCollapseThreshold: Float = SpeakerLibrary.matchThreshold

    private let speakers = SpeakerLibrary.shared

    nonisolated static func modelPaths() -> (segmentation: URL, embedding: URL)? {
        func complete(_ dir: URL) -> (URL, URL)? {
            let seg = dir.appendingPathComponent("segmentation.onnx")
            let emb = dir.appendingPathComponent("embedding.onnx")
            guard FileManager.default.fileExists(atPath: seg.path),
                  FileManager.default.fileExists(atPath: emb.path) else {
                return nil
            }
            return (seg, emb)
        }
        func find(_ dir: URL) -> (URL, URL)? {
            FileManager.default.fileExists(atPath: dir.path) ? complete(dir) : nil
        }

        // Bundled app resources (release): Resources/diarization-models.
        if let res = Bundle.main.resourceURL,
           let found = find(res.appendingPathComponent("diarization-models")) {
            return found
        }
        // Dev/test checkouts: models live in the repo's extraResources/, but the
        // test bundle nests several levels deep in DerivedData — walk up to it.
        var probe = Bundle.main.bundleURL
        for _ in 0..<8 {
            probe = probe.deletingLastPathComponent()
            if let found = find(probe.appendingPathComponent("extraResources/diarization-models")) {
                return found
            }
        }
        // Relative to cwd (plain dev runs).
        return find(URL(fileURLWithPath: "extraResources/diarization-models"))
    }

    var isAvailable: Bool {
        Self.modelPaths() != nil
    }

    /// Diarize a recording and assign persistent speaker labels.
    /// Returns time-ordered turns and the profile each cluster belongs to.
    func diarize(audioURL: URL) async throws -> (turns: [SpeakerTurn], labels: [Int: (id: UUID, name: String)]) {
        guard let paths = Self.modelPaths() else {
            throw DiarizationError.modelsMissing
        }
        let t0 = Date()
        Diag.log("DIAR start")

        let channels = Int(try AVAudioFile(forReading: audioURL).processingFormat.channelCount)
        let raw: (turns: [SpeakerTurn], embeddings: [Int: [Float]], clusterSamples: [Int: [Float]])
        raw = if channels >= 2 {
            try await Self.diarizeStereo(audioURL: audioURL, modelPaths: paths)
        } else {
            try await Self.diarizeMono(audioURL: audioURL, modelPaths: paths)
        }

        guard !raw.turns.isEmpty else { throw DiarizationError.noSpeech }

        // Clusters without an embedding (too little speech, or extraction
        // failed) are fragments: drop their turns so they never hijack
        // transcript attribution.
        let valid = Set(raw.embeddings.compactMap { $0.value.isEmpty ? nil : $0.key })
        let turns = raw.turns.filter { valid.contains($0.cluster) }
        guard !turns.isEmpty else { throw DiarizationError.noSpeech }

        // Debug hook for cluster-collapse tuning (opt-in via env).
        if let dumpPath = ProcessInfo.processInfo.environment["PLUME_DAR_DUMP"] {
            let payload = Dictionary(uniqueKeysWithValues: raw.embeddings.map { (String($0.key), $0.value) })
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? data.write(to: URL(fileURLWithPath: dumpPath))
            }
        }

        // Collapse over-split fragments: greedy agglomerative re-merge on the
        // cluster-mean embeddings, at the same criterion the library uses to
        // recognize a speaker.
        let collapsed = Self.collapseClusters(
            turns: turns, embeddings: raw.embeddings, clusterSamples: raw.clusterSamples,
            threshold: Self.clusterCollapseThreshold)

        var perCluster: [Int: (turns: Int, seconds: Double)] = [:]
        for turn in collapsed.turns {
            let cur = perCluster[turn.cluster] ?? (0, 0)
            perCluster[turn.cluster] = (cur.turns + 1, cur.seconds + turn.end - turn.start)
        }
        let top = perCluster.sorted { $0.value.seconds > $1.value.seconds }
            .prefix(10)
            .map { "c\($0.key):\($0.value.turns)t/\(String(format: "%.0f", $0.value.seconds))s" }
            .joined(separator: " ")
        Diag.log("DIAR clusters=\(perCluster.count) top \(top)")

        // Match embeddings against remembered speakers on the main actor.
        var labels: [Int: (UUID, String)] = [:]
        for (cluster, embedding) in collapsed.embeddings where !embedding.isEmpty {
            let profile = speakers.upsert(embedding: embedding)
            // Refine the profile with this cluster's data (a fresh profile
            // blends with itself, which is a no-op).
            speakers.updateEmbedding(id: profile.id, embedding: embedding)
            labels[cluster] = (profile.id, profile.name)
            // Save a voice sample for new/empty profiles so they can be previewed later.
            if speakers.sampleURL(for: profile) == nil, let chunk = collapsed.clusterSamples[cluster] {
                speakers.storeSample(id: profile.id, samples: chunk, sampleRate: 16000)
            }
        }
        Diag.log("DIAR done in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s turns=\(collapsed.turns.count) clusters=\(perCluster.keys.sorted())")
        return (collapsed.turns, labels)
    }

    // MARK: - Channel pipelines

    private typealias Raw = (turns: [SpeakerTurn], embeddings: [Int: [Float]], clusterSamples: [Int: [Float]])

    /// Stereo: diarize the system channel; carve the mic channel into turns
    /// with energy VAD (one physical voice, no segmentation model needed).
    nonisolated private static func diarizeStereo(
        audioURL: URL, modelPaths: (segmentation: URL, embedding: URL))
        async throws -> Raw {
        let task = Task.detached(priority: .utility) { () -> Raw in
            let sysSamples = try AudioFileReader.readMono16k(from: audioURL, channel: 0)
            Diag.log("DIAR sys samples=\(sysSamples.count) (\(String(format: "%.1f", Double(sysSamples.count) / 16000.0))s @16k)")
            let sys = try processSamples(sysSamples, modelPaths: modelPaths)

            let micSamples = try AudioFileReader.readMono16k(from: audioURL, channel: 1)
            let micTurns = voiceTurns(micSamples, sampleRate: 16000)
            let micSeconds = micTurns.reduce(0.0) { $0 + $1.end - $1.start }
            Diag.log("DIAR mic turns=\(micTurns.count) speech=\(String(format: "%.0f", micSeconds))s")

            var turns = sys.turns
            var embeddings = sys.embeddings
            var clusterSamples = sys.clusterSamples

            if micSeconds >= 3.0 {
                let tagged = micTurns.map { SpeakerTurn(start: $0.start, end: $0.end, cluster: micCluster) }
                let (micEmbeddings, micSamples10s) = extractClusterEmbeddingsAndSamples(
                    samples: micSamples,
                    sampleRate: 16000,
                    turns: tagged,
                    embeddingModelPath: modelPaths.embedding.path)
                // Echo pass: system clusters that sound like the mic speaker.
                if let micEmb = micEmbeddings[micCluster] {
                    var echoMerged: Set<Int> = []
                    for (cluster, emb) in sys.embeddings
                    where cluster != micCluster
                           && SpeakerLibrary.cosineSimilarity(emb, micEmb) >= echoMergeThreshold {
                        echoMerged.insert(cluster)
                    }
                    if !echoMerged.isEmpty {
                        Diag.log("DIAR echo merge \(echoMerged.sorted()) -> mic")
                        turns = turns.map {
                            echoMerged.contains($0.cluster)
                                ? SpeakerTurn(start: $0.start, end: $0.end, cluster: micCluster)
                                : $0
                        }
                    }
                }
                turns.append(contentsOf: tagged)
                if let micEmb = micEmbeddings[micCluster], !micEmb.isEmpty {
                    embeddings[micCluster] = micEmb
                    clusterSamples[micCluster] = micSamples10s[micCluster]
                }
            }
            return (turns, embeddings, clusterSamples)
        }
        return try await task.value
    }

    /// Mono: the classic full pipeline over the whole file.
    nonisolated private static func diarizeMono(
        audioURL: URL, modelPaths: (segmentation: URL, embedding: URL))
        async throws -> Raw {
        let task = Task.detached(priority: .utility) { () -> Raw in
            let samples = try AudioFileReader.readMono16k(from: audioURL)
            guard samples.count > 16000 else { throw DiarizationError.noSpeech }
            Diag.log("DIAR samples=\(samples.count) (\(String(format: "%.1f", Double(samples.count) / 16000.0))s @16k)")
            return try processSamples(samples, modelPaths: modelPaths)
        }
        return try await task.value
    }

    /// Segmentation + fast clustering + per-cluster embeddings for one set of
    /// 16 kHz mono samples. Blocking; call from a detached task.
    nonisolated private static func processSamples(
        _ samples: [Float], modelPaths: (segmentation: URL, embedding: URL)) throws -> Raw {
        guard samples.count > 16000 else { throw DiarizationError.noSpeech }
        return autoreleasepool { () -> Raw in
            let segConfig = sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: modelPaths.segmentation.path))
            let embConfig = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: modelPaths.embedding.path)
            let clusterConfig = sherpaOnnxFastClusteringConfig(threshold: 0.6)
            var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
                segmentation: segConfig,
                embedding: embConfig,
                clustering: clusterConfig)

            let diarizer = SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
            guard diarizer.impl != nil else {
                return ([], [:], [:])
            }

            let raw = diarizer.process(samples: samples)
            let turns = raw.map { SpeakerTurn(start: Double($0.start), end: Double($0.end), cluster: $0.speaker) }
            let (embeddings, clusterSamples) = extractClusterEmbeddingsAndSamples(
                samples: samples,
                sampleRate: 16000,
                turns: turns,
                embeddingModelPath: modelPaths.embedding.path)
            return (turns, embeddings, clusterSamples)
        }
    }

    /// Energy-gated voice activity → SpeakerTurns bound to one cluster id.
    /// Hysteresis keeps short dropouts from splitting an utterance.
    nonisolated static func voiceTurns(_ samples: [Float], sampleRate: Int, cluster: Int = DiarizationService.micCluster) -> [SpeakerTurn] {
        let hop = max(1, sampleRate / 50) // 20 ms frames
        var rms: [Float] = []
        rms.reserveCapacity(samples.count / hop + 1)
        var i = 0
        while i + hop <= samples.count {
            var sum2: Float = 0
            for j in i..<(i + hop) {
                sum2 += samples[j] * samples[j]
            }
            rms.append((sum2 / Float(hop)).squareRoot())
            i += hop
        }
        // Adaptive gate: near-silence must stay silent, strong speech must pass.
        let peak = rms.max() ?? 0
        let open = max(0.008, peak * 0.08)
        var spans: [(Int, Int)] = []
        var on = false
        var spanStart = 0
        for (idx, level) in rms.enumerated() {
            if on {
                if level < open * 0.5 {
                    spans.append((spanStart, idx))
                    on = false
                }
            } else if level > open {
                spanStart = idx
                on = true
            }
        }
        if on {
            spans.append((spanStart, rms.count))
        }

        // Bridge gaps ≤ 0.6s, then keep utterances ≥ 0.25s.
        let hopFraction = Double(hop) / Double(sampleRate)
        var merged: [(Int, Int)] = []
        for span in spans {
            if let last = merged.last, Double(span.0 - last.1) * hopFraction <= 0.6 {
                merged[merged.count - 1] = (last.0, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged.compactMap { startF, endF -> SpeakerTurn? in
            guard Double(endF - startF) * hopFraction >= 0.25 else { return nil }
            return SpeakerTurn(start: Double(startF) * hopFraction, end: Double(endF) * hopFraction, cluster: cluster)
        }
    }

    /// Greedy agglomerative re-merge of speaker clusters whose mean embeddings
    /// clear `threshold`. Fragmented clusters of one real voice sit far apart
    /// at segment level but bind tightly once their 30s aggregates are averaged,
    /// so distinct speakers (whose similarity never approaches the threshold)
    /// stay separate. Returns remapped turns, per-group mean embeddings, and
    /// voice samples re-keyed to the surviving cluster id (smallest original id).
    nonisolated static func collapseClusters(
        turns: [SpeakerTurn], embeddings: [Int: [Float]], clusterSamples: [Int: [Float]],
        threshold: Float)
        -> (turns: [SpeakerTurn], embeddings: [Int: [Float]], clusterSamples: [Int: [Float]]) {
        guard embeddings.count > 1 else { return (turns, embeddings, clusterSamples) }

        var groups: [[Int]] = embeddings.keys.map { [$0] }
        var means: [[Float]] = []

        func recomputeMeans() {
            means = groups.map { group in
                guard let first = group.first, let emb = embeddings[first] else { return [] }
                var m = [Float](repeating: 0, count: emb.count)
                for id in group {
                    if let e = embeddings[id], e.count == m.count {
                        for (i, x) in e.enumerated() {
                            m[i] += x / Float(group.count)
                        }
                    }
                }
                let norm = sqrtf(m.reduce(0) { $0 + $1 * $1 })
                if norm > 0 {
                    for i in m.indices {
                        m[i] /= norm
                    }
                }
                return m
            }
        }
        recomputeMeans()

        while groups.count > 1 {
            var best: (i: Int, j: Int, s: Float)?
            for i in 0..<groups.count {
                for j in (i + 1)..<groups.count {
                    let s = SpeakerLibrary.cosineSimilarity(means[i], means[j])
                    if s >= threshold, best == nil || s > best!.s {
                        best = (i, j, s)
                    }
                }
            }
            guard let merge = best else { break }
            groups[merge.i].append(contentsOf: groups.remove(at: merge.j))
            recomputeMeans()
        }

        var remap: [Int: Int] = [:]
        var outEmbeddings: [Int: [Float]] = [:]
        var outSamples: [Int: [Float]] = [:]
        for (idx, group) in groups.enumerated() {
            let rep = group.min() ?? idx
            for id in group {
                remap[id] = rep
            }
            outEmbeddings[rep] = means[idx]
            if let sample = group.compactMap({ clusterSamples[$0] }).first {
                outSamples[rep] = sample
            }
        }
        let outTurns = turns.map {
            SpeakerTurn(start: $0.start, end: $0.end, cluster: remap[$0.cluster] ?? $0.cluster)
        }
        return (outTurns, outEmbeddings, outSamples)
    }

    /// Concatenate each cluster's speech slices and extract a voice embedding.
    /// Returns embeddings for clusters with >=3s of speech plus a short audio sample
    /// (first up to 10 seconds) for each of those clusters.
    nonisolated private static func extractClusterEmbeddingsAndSamples(
        samples: [Float], sampleRate: Int, turns: [SpeakerTurn], embeddingModelPath: String)
        -> (embeddings: [Int: [Float]], clusterSamples: [Int: [Float]]) {
        // Cap concatenated audio per cluster: feeding a long meeting's full
        // cluster (tens of minutes) to the TITANet embedding model makes
        // ONNXRuntime throw, which aborts the process (C++ exceptions cannot
        // be caught from Swift). 30s is plenty for a stable speaker embedding.
        let maxClusterFrames = sampleRate * 30
        var byCluster: [Int: [Float]] = [:]
        var durations: [Int: Double] = [:]
        for turn in turns {
            let startIdx = max(0, Int(turn.start * Double(sampleRate)))
            let endIdx = min(samples.count, Int(turn.end * Double(sampleRate)))
            guard endIdx > startIdx else { continue }
            durations[turn.cluster, default: 0] += turn.end - turn.start
            var acc = byCluster[turn.cluster] ?? []
            guard acc.count < maxClusterFrames else { continue }
            let take = max(0, min(endIdx - startIdx, maxClusterFrames - acc.count))
            if take > 0 {
                acc.append(contentsOf: samples[startIdx..<(startIdx + take)])
                byCluster[turn.cluster] = acc
            }
        }

        // toCPointer hands the C API pointers into autoreleased NSString storage,
        // so keep the extractor's whole lifetime inside a pool.
        return autoreleasepool { () -> (embeddings: [Int: [Float]], clusterSamples: [Int: [Float]]) in
            var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(model: embeddingModelPath)
            let extractor = SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
            guard extractor.impl != nil else {
                return ([:], [:])
            }

            var embeddings: [Int: [Float]] = [:]
            var clusterSamples: [Int: [Float]] = [:]
            let maxSampleFrames = sampleRate * 10
            for (cluster, chunk) in byCluster {
                guard let seconds = durations[cluster], seconds >= 3.0 else { continue }
                clusterSamples[cluster] = Array(chunk.prefix(maxSampleFrames))
                let stream = extractor.createStream()
                stream.acceptWaveform(samples: chunk, sampleRate: sampleRate)
                stream.inputFinished()
                if extractor.isReady(stream: stream) {
                    let embedding = extractor.compute(stream: stream)
                    if !embedding.isEmpty {
                        embeddings[cluster] = embedding
                    }
                }
            }
            return (embeddings, clusterSamples)
        }
    }
}