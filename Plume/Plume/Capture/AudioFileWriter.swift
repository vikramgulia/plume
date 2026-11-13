import Foundation
import AVFoundation
import CoreMedia
import CoreAudio

/// In-process stereo recorder: left channel = system audio, right channel = microphone.
/// Both sources push Float32 mono 48 kHz PCM chunks; a `StereoAligner` places them on a
/// shared timeline by arrival time, and a ticker writes the aligned stereo through
/// AVAssetWriter (M4A/AAC) or as a plain float32 PCM WAV file. A source that starts late
/// or goes quiet leaves silence at the right position, so the channels stay in sync.
final class AudioFileWriter: @unchecked Sendable {
    static let sampleRate: Double = 48000
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var wavHandle: FileHandle?
    private var wavDataBytes = 0
    private var pcmFormatDescription: CMAudioFormatDescription?
    private var framesWritten: Int64 = 0
    private var format: AudioFormat = .m4a

    private let lock = NSLock()
    private var aligner = StereoAligner()
    private let clock: () -> TimeInterval
    private var startTime: TimeInterval = 0
    /// How far behind real time output is written, so slightly late data can still be placed.
    private static let latency: TimeInterval = 0.2
    private let maxChunkFrames = 9600

    private let tickerQueue = DispatchQueue(label: "com.plume.writer.ticker")
    private var timer: DispatchSourceTimer?
    private var finished = false
    private var tickCount = 0
    private var appendCount = 0
    private var deferredCount = 0

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func start(format: AudioFormat, output: URL) throws {
        self.format = format
        framesWritten = 0
        aligner = StereoAligner()
        startTime = clock()
        Diag.log("WRITER start format=\(format.rawValue) output=\(output.lastPathComponent)")

        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Self.sampleRate
        asbd.mFormatID = kAudioFormatLinearPCM
        asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        asbd.mFramesPerPacket = 1
        asbd.mBytesPerFrame = 8
        asbd.mBytesPerPacket = 8
        asbd.mChannelsPerFrame = 2
        asbd.mBitsPerChannel = 32
        var fd: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &fd
        )
        pcmFormatDescription = fd

        switch format {
        case .m4a: try startAssetWriter(output: output)
        case .wav: try startWav(output: output)
        }

        let t = DispatchSource.makeTimerSource(queue: tickerQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func appendSystem(_ data: Data) {
        push(data, source: .system)
    }

    func appendMic(_ data: Data) {
        push(data, source: .mic)
    }

    /// Flush buffered audio, finalize the file, and close.
    func finish() async throws {
        Diag.log("WRITER finish: ticks=\(tickCount) appended=\(appendCount) deferred=\(deferredCount) framesWritten=\(framesWritten)")
        tickerQueue.sync {
            timer?.cancel()
            timer = nil
        }
        lock.lock()
        finished = true
        lock.unlock()

        // Drain whatever both sources still have buffered, waiting out encoder back-pressure.
        while let chunk = nextChunk(draining: true) {
            var attempts = 0
            while !writeStereo(chunk) && attempts < 1000 {
                attempts += 1
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            if attempts >= 1000 {
                Diag.log("WRITER finish: encoder never became ready, dropping remaining audio")
                break
            }
            commit(chunk)
        }

        switch format {
        case .m4a:
            input?.markAsFinished()
            guard let writer else { return }
            await writer.finishWriting()
            Diag.log("WRITER finishWriting status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "none")")
            if writer.status == .failed, let err = writer.error {
                throw err
            }
        case .wav:
            guard let h = wavHandle else { return }
            try? h.seek(toOffset: 0)
            try? h.write(contentsOf: Self.wavHeader(dataBytes: wavDataBytes))
            try? h.close()
            wavHandle = nil
        }
    }

    /// Abort and leave the file in whatever state it's in (caller removes it).
    func cancel() {
        tickerQueue.sync {
            timer?.cancel()
            timer = nil
        }
        writer?.cancelWriting()
        writer = nil
        input = nil
        try? wavHandle?.close()
        wavHandle = nil
    }

    // MARK: - Internals

    private func push(_ data: Data, source: StereoAligner.Source) {
        let floats = data.withUnsafeBytes { raw -> [Float] in
            Array(raw.bindMemory(to: Float.self))
        }
        guard !floats.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        aligner.push(floats, source: source, at: clock() - startTime)
    }

    /// The next chunk of aligned stereo (L = system, R = mic) that is due, without consuming it.
    private func nextChunk(draining: Bool) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        if draining { return aligner.peekAll(maxFrames: maxChunkFrames) }
        return aligner.peek(upTo: clock() - startTime, latency: Self.latency, maxFrames: maxChunkFrames)
    }

    private func commit(_ chunk: [Float]) {
        lock.lock()
        aligner.commit(frames: chunk.count / 2)
        lock.unlock()
    }

    private func tick() {
        tickCount += 1
        if tickCount % 100 == 0 {
            lock.lock()
            let pending = aligner.pendingFrames
            lock.unlock()
            Diag.log("WRITER tick #\(tickCount) appended=\(appendCount) deferred=\(deferredCount) pendingFrames=\(pending)")
        }
        guard let chunk = nextChunk(draining: false) else { return }
        if writeStereo(chunk) { commit(chunk) }
    }

    /// Returns false when the encoder is not ready; the chunk is kept and retried.
    private func writeStereo(_ stereo: [Float]) -> Bool {
        switch format {
        case .m4a: return appendToAssetWriter(stereo)
        case .wav: return appendToWav(stereo)
        }
    }

    private func appendToAssetWriter(_ stereo: [Float]) -> Bool {
        guard let input, let fd = pcmFormatDescription else { return true }
        // Under encoder back-pressure keep the chunk and retry; PTS only advances on a successful append.
        guard input.isReadyForMoreMediaData else {
            deferredCount += 1
            return false
        }

        let frames = stereo.count / 2
        let bytes = stereo.count * MemoryLayout<Float>.size

        // Provide our own memory block: with a NULL memory block the data region is
        // never materialized and GetDataPointer fails, silently dropping every chunk.
        guard let mem = malloc(bytes) else { return true }
        stereo.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(mem, base, bytes)
            }
        }
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: mem,
            blockLength: bytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            free(mem)
            return true
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(Self.sampleRate)),
            presentationTimeStamp: CMTime(value: framesWritten, timescale: CMTimeScale(Self.sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        let ok = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fd,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        guard ok == noErr, let sb else {
            Diag.log("WRITER CMSampleBufferCreate failed at tick #\(tickCount)")
            return true
        }
        if input.append(sb) {
            framesWritten += Int64(frames)
            appendCount += 1
        } else {
            Diag.log("WRITER append returned false at tick #\(tickCount)")
        }
        return true
    }

    // MARK: - M4A

    private func startAssetWriter(output: URL) throws {
        let w = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Int(Self.sampleRate),
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]
        let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: pcmFormatDescription)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else {
            throw NSError(domain: "Plume", code: 30, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio track"])
        }
        w.add(i)
        guard w.startWriting() else {
            throw w.error ?? NSError(domain: "Plume", code: 31, userInfo: [NSLocalizedDescriptionKey: "Cannot start audio writer"])
        }
        w.startSession(atSourceTime: .zero)
        writer = w
        input = i
    }

    // MARK: - WAV

    private func startWav(output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: output.path) else {
            throw NSError(domain: "Plume", code: 32, userInfo: [NSLocalizedDescriptionKey: "Cannot create WAV file"])
        }
        wavHandle = h
        wavDataBytes = 0
        // Placeholder header; patched with real sizes in finish().
        try h.write(contentsOf: Self.wavHeader(dataBytes: 0))
    }

    private func appendToWav(_ stereo: [Float]) -> Bool {
        guard let h = wavHandle else { return true }
        let data = stereo.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try h.write(contentsOf: data)
            wavDataBytes += data.count
        } catch {
            // disk full or file gone; nothing useful to do
        }
        return true
    }

    static func wavHeader(dataBytes: Int) -> Data {
        let sampleRate = 48000
        let channels = 2
        let bitsPerSample = 32
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign

        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func ascii(_ s: String) { d.append(contentsOf: s.utf8) }

        ascii("RIFF")
        le32(UInt32(36 + dataBytes))
        ascii("WAVE")
        ascii("fmt ")
        le32(16)
        le16(3) // IEEE float
        le16(UInt16(channels))
        le32(UInt32(sampleRate))
        le32(UInt32(byteRate))
        le16(UInt16(blockAlign))
        le16(UInt16(bitsPerSample))
        ascii("data")
        le32(UInt32(dataBytes))
        return d
    }
}