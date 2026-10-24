import Foundation

/// Places audio from two independently clocked sources (system audio = left,
/// microphone = right) on one shared timeline of 48 kHz frames.
///
/// Each push is stamped with its arrival time, so a source that starts late or goes
/// quiet leaves a silent gap at the right position instead of shifting the audio that
/// follows. Output is read in chunks up to a wall-clock horizon (minus a small
/// latency that lets late data arrive); frames a source has not supplied are silence.
///
/// Not thread-safe: the owner serialises access.
struct StereoAligner {
    enum Source { case system, mic }

    static let sampleRate = 48000
    /// Gaps shorter than this (100 ms) are delivery jitter, not silence, and are not padded.
    static let gapTolerance = 4800
    /// A source more than this (500 ms) ahead of real time has its excess dropped, which
    /// keeps a slightly fast device clock from drifting away from the other channel.
    static let leadLimit = 24000
    /// Upper bound on buffered frames; beyond it the oldest frames of both channels are dropped.
    static let maxPending = 48000 * 120

    /// Absolute frame index of the first frame that has not been committed yet.
    private(set) var position: Int64 = 0
    private var system: [Float] = []
    private var mic: [Float] = []

    /// Frames buffered beyond the committed position, for the longer of the two sources.
    var pendingFrames: Int { max(system.count, mic.count) }

    /// Adds mono samples that arrived `elapsed` seconds after recording started.
    mutating func push(_ samples: [Float], source: Source, at elapsed: TimeInterval) {
        guard !samples.isEmpty else { return }
        let now = Int64(elapsed * Double(Self.sampleRate))
        switch source {
        case .system: Self.place(samples, into: &system, position: position, now: now)
        case .mic: Self.place(samples, into: &mic, position: position, now: now)
        }
        let over = pendingFrames - Self.maxPending
        if over > 0 {
            system.removeFirst(min(over, system.count))
            mic.removeFirst(min(over, mic.count))
            position += Int64(over)
        }
    }

    /// Interleaved stereo for the frames between the committed position and the real-time
    /// horizon (`elapsed - latency`), at most `maxFrames`. Nil when nothing is due.
    func peek(upTo elapsed: TimeInterval, latency: TimeInterval, maxFrames: Int) -> [Float]? {
        let horizon = Int64((elapsed - latency) * Double(Self.sampleRate))
        guard horizon > position else { return nil }
        return interleave(frames: min(maxFrames, Int(horizon - position)))
    }

    /// Interleaved stereo for whatever is still buffered, at most `maxFrames`. Used to
    /// flush at the end of a recording. Nil when nothing is buffered.
    func peekAll(maxFrames: Int) -> [Float]? {
        let n = min(maxFrames, pendingFrames)
        guard n > 0 else { return nil }
        return interleave(frames: n)
    }

    /// Marks `frames` frames returned by `peek`/`peekAll` as written.
    mutating func commit(frames n: Int) {
        system.removeFirst(min(n, system.count))
        mic.removeFirst(min(n, mic.count))
        position += Int64(n)
    }

    private func interleave(frames n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<min(n, system.count) { out[i * 2] = system[i] }
        for i in 0..<min(n, mic.count) { out[i * 2 + 1] = mic[i] }
        return out
    }

    private static func place(_ samples: [Float], into buffer: inout [Float], position: Int64, now: Int64) {
        let cursor = position + Int64(buffer.count)
        let expectedStart = now - Int64(samples.count)
        if expectedStart - cursor > Int64(gapTolerance) {
            buffer.append(contentsOf: repeatElement(0, count: Int(expectedStart - cursor)))
        } else if cursor - now > Int64(leadLimit) {
            return
        }
        buffer.append(contentsOf: samples)
    }
}
