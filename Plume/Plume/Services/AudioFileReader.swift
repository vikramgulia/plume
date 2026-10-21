import Foundation
import AVFoundation

/// Reads audio files into plain mono Float sample arrays for ML pipelines.
enum AudioFileReader {
    /// Mono Float32 samples at the file's native rate. `channel` selects one
    /// channel of a multi-channel file; nil averages all channels.
    nonisolated static func monoSamples(from url: URL, channel: Int? = nil) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let channels = Int(srcFormat.channelCount)
        if let channel, channel >= channels {
            throw NSError(domain: "Plume", code: 44, userInfo: [NSLocalizedDescriptionKey: "Recording has no channel \(channel)"])
        }
        var out: [Float] = []
        out.reserveCapacity(Int(file.length))

        let cap: AVAudioFrameCount = 65536
        while file.framePosition < file.length {
            // Read an explicit frame count: a bare capacity read throws nilError
            // when it hits the file's final partial chunk.
            let want = min(cap, AVAudioFrameCount(file.length - file.framePosition))
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: want) else { break }
            try file.read(into: buf, frameCount: want)
            if buf.frameLength == 0 { break }
            let n = Int(buf.frameLength)
            if let sourceCh = channel ?? (channels == 1 ? 0 : nil), let ch = buf.floatChannelData?[sourceCh] {
                out.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
            } else {
                for i in 0..<n {
                    var sum: Float = 0
                    for c in 0..<channels {
                        if let p = buf.floatChannelData?[c] {
                            sum += p[i]
                        }
                    }
                    out.append(sum / Float(channels))
                }
            }
        }
        return (out, srcFormat.sampleRate)
    }

    /// Mono Float32 samples resampled to 16 kHz — sherpa-onnx diarization input.
    /// `channel` (nil = average all channels) mirrors `monoSamples`.
    nonisolated static func readMono16k(from url: URL, channel: Int? = nil) throws -> [Float] {
        let (src, srcRate) = try monoSamples(from: url, channel: channel)
        if srcRate == 16000 {
            return src
        }
        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcRate, channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw NSError(domain: "Plume", code: 42, userInfo: [NSLocalizedDescriptionKey: "Cannot create 16 kHz resampler"])
        }
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(src.count)) else {
            throw NSError(domain: "Plume", code: 43, userInfo: [NSLocalizedDescriptionKey: "Cannot create resample buffer"])
        }
        srcBuf.frameLength = AVAudioFrameCount(src.count)
        src.withUnsafeBufferPointer { buf in
            if let dst = srcBuf.floatChannelData?[0], let base = buf.baseAddress {
                dst.update(from: base, count: src.count)
            }
        }

        var out: [Float] = []
        let ratio = 16000.0 / srcRate
        out.reserveCapacity(Int(Double(src.count) * ratio) + 1024)

        // The converter buffers samples for rate conversion; once the single input
        // buffer is consumed the input block reports .endOfStream so the remaining
        // tail is flushed across the following convert calls.
        var inputExhausted = false
        let block: AVAudioConverterInputBlock = { _, status in
            if inputExhausted {
                status.pointee = .endOfStream
                return nil
            }
            inputExhausted = true
            status.pointee = .haveData
            return srcBuf
        }

        while true {
            let cap: AVAudioFrameCount = 65536
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: cap) else { break }
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error, withInputFrom: block)
            if let error { throw error }
            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error {
                break
            }
        }
        return out
    }
}