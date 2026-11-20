import Foundation
import AVFoundation

/// Captures microphone as Float32 mono PCM at 48 kHz.
final class MicCapture: @unchecked Sendable {
    var onPCM: ((Data, Float) -> Void)?
    var onError: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private var started = false
    private let lock = NSLock()
    private var delivered = false
    private var bufferCount = 0
    private var configObserver: NSObjectProtocol?
    private var pendingRestart: DispatchWorkItem?
    private var recentRestarts: [Date] = []
    private let restartQueue = DispatchQueue(label: "com.plume.mic.restart")

    /// A microphone chosen in Settings (its UID), or nil to choose automatically.
    var preferredDeviceUID: String?

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
        // Pick the microphone first: opening a Bluetooth headset's mic switches it to the
        // hands-free profile, which silences what is playing in it. Use the Mac's own mic instead.
        if let device = AudioDevices.chooseInput(preferredUID: preferredDeviceUID) {
            if device.id != AudioDevices.defaultInputID() {
                do { try input.auAudioUnit.setDeviceID(device.id) }
                catch { Diag.log("MIC could not select \(device.name): \(error.localizedDescription)") }
            }
            Diag.log("MIC input device: \(device.name) bluetooth=\(device.isBluetooth) builtIn=\(device.isBuiltIn)")
        }
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

        // The engine stops itself when the input device changes (AirPods connect,
        // a USB mic is unplugged, ...); rebuild the tap on the new device.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    /// Device changes arrive in bursts (a Bluetooth headset can change profile several times), and
    /// restarting on each one keeps reopening the input, which stops the headset settling. Wait until
    /// the changes stop, restart once, and give up after a few rounds.
    private func handleConfigurationChange() {
        lock.lock()
        guard started else { lock.unlock(); return }
        pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.restartAfterDeviceChange() }
        pendingRestart = item
        lock.unlock()
        restartQueue.asyncAfter(deadline: .now() + 0.7, execute: item)
    }

    private func restartAfterDeviceChange() {
        lock.lock()
        let now = Date()
        recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < 15 }
        let allowed = started && recentRestarts.count < 3
        if allowed { recentRestarts.append(now) }
        let gaveUp = started && !allowed
        lock.unlock()
        if gaveUp {
            Diag.log("MIC device keeps changing — not restarting again")
            onError?(NSError(domain: "Plume", code: 12, userInfo: [NSLocalizedDescriptionKey: "the audio device keeps changing"]))
            return
        }
        guard allowed else { return }
        Diag.log("MIC input settled after a device change — restarting")
        restart()
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
        pendingRestart?.cancel()
        pendingRestart = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        started = false
    }
}