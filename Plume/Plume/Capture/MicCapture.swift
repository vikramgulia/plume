import Foundation
import AVFoundation

/// Captures microphone as Float32 mono PCM at 44.1 kHz.
final class MicCapture: @unchecked Sendable {
    var onPCM: ((Data, Float) -> Void)?
    var onError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var started = false
    private let lock = NSLock()
    private var delivered = false
    private var bufferCount = 0

    /// Whether the input tap has produced at least one buffer.
    var hasDeliveredFrames: Bool {
        lock.lock(); defer { lock.unlock() }
        return delivered
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        if started { return }

        if AVAudioApplication.shared.recordPermission == .denied {
            throw NSError(domain: "Plume", code: 10, userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }

        let input = engine.inputNode
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw NSError(domain: "Plume", code: 11, userInfo: [NSLocalizedDescriptionKey: "No microphone input"])
        }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: true)!
        let converter = AVAudioConverter(from: hwFormat, to: target)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.delivered = true
            self.bufferCount += 1
            let n = self.bufferCount
            self.lock.unlock()
            if n == 1 || n % 100 == 0 {
                Diag.log("MIC buffer #\(n) rate=\(hwFormat.sampleRate) frames=\(buffer.frameLength)")
            }

            if let converter {
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 48000.0 / hwFormat.sampleRate) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var error: NSError?
                var consumed = false
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                converter.convert(to: out, error: &error, withInputFrom: inputBlock)
                if error == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] {
                    let frames = Int(out.frameLength)
                    let data = Data(bytes: ch, count: frames * MemoryLayout<Float>.size)
                    let lvl = AudioPCM.rmsLevel(ch, frames: frames, channels: 1)
                    self.onPCM?(data, lvl)
                }
            } else if let ch = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                let channels = Int(buffer.format.channelCount)
                // Downmix/take first channel
                var mono = [Float](repeating: 0, count: frames)
                for i in 0..<frames {
                    mono[i] = ch[i * channels]
                }
                let data = mono.withUnsafeBufferPointer { Data(buffer: $0) }
                let lvl = mono.withUnsafeBufferPointer { buf -> Float in
                    guard let base = buf.baseAddress else { return 0 }
                    return AudioPCM.rmsLevel(base, frames: frames, channels: 1)
                }
                self.onPCM?(data, lvl)
            }
        }

        engine.prepare()
        try engine.start()
        started = true
    }

    /// One-shot attempt to recover an input tap that stopped delivering
    /// (e.g. a Bluetooth device switching profiles when system audio capture starts).
    func restart() {
        lock.lock()
        let wasStarted = started
        lock.unlock()
        guard wasStarted else { return }
        Diag.log("MIC restart begin")
        stop()
        do {
            try start()
            Diag.log("MIC restart ok")
        } catch {
            Diag.log("MIC restart failed: \(error.localizedDescription)")
            onError?(error)
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
    }
}