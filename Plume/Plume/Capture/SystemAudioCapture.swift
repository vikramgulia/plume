import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// In-process ScreenCaptureKit system-audio capture (no CLI). Delivers Float32
/// mono PCM at 48 kHz, converted from the stream's native format.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// (mono 48k Float32 PCM chunk, RMS level 0...1)
    var onPCM: ((Data, Float) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.plume.systemaudio")
    private let audioQueue = DispatchQueue(label: "com.plume.systemaudio.samples")
    private var converter: AVAudioConverter?
    private var convRate: Double = 0
    private var convChannels: UInt32 = 0
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: true)!
    private var bufferCount = 0
    private var stopRequested = false

    func start() {
        Diag.log("SCK start requested")
        queue.async { [weak self] in
            self?.startSync()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopSync()
        }
    }

    private func startSync() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            if let error {
                Diag.log("SCK shareable content error: \(error.localizedDescription)")
                self.onError?(error)
                return
            }
            guard let content, let display = content.displays.first else {
                Diag.log("SCK no display available")
                self.onError?(NSError(domain: "Plume", code: 3, userInfo: [NSLocalizedDescriptionKey: "No display available"]))
                return
            }

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.width = 2
            config.height = 2
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
            config.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)

            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            } catch {
                Diag.log("SCK addStreamOutput failed: \(error.localizedDescription)")
                self.onError?(error)
                return
            }

            self.stream = stream
            stream.startCapture { [weak self] error in
                if let error {
                    Diag.log("SCK startCapture failed: \(error.localizedDescription)")
                    self?.onError?(error)
                } else {
                    Diag.log("SCK capture started")
                }
            }
        }
    }

    private func stopSync() {
        stopRequested = true
        let s = stream
        stream = nil
        s?.stopCapture { _ in }
    }

    /// The stream ended on its own (display removed, system stopped capture, ...).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, !self.stopRequested else { return }
            Diag.log("SCK stream stopped with error: \(error.localizedDescription)")
            self.stream = nil
            self.onError?(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 else { return }
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        let channels = Int(asbd.mChannelsPerFrame)
        bufferCount += 1
        if bufferCount == 1 || bufferCount % 100 == 0 {
            Diag.log("SCK buffer #\(bufferCount) rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) frames=\(frames)")
        }
        guard let srcData = AudioPCM.interleavedPCM(from: sampleBuffer, frames: frames, channels: channels) else {
            Diag.log("SCK PCM extraction failed at buffer #\(bufferCount)")
            return
        }

        // Wrap the interleaved float32 chunk in a buffer the converter accepts.
        var srcASBD = AudioStreamBasicDescription()
        srcASBD.mSampleRate = asbd.mSampleRate
        srcASBD.mFormatID = kAudioFormatLinearPCM
        srcASBD.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        srcASBD.mFramesPerPacket = 1
        srcASBD.mBytesPerFrame = 4 * UInt32(channels)
        srcASBD.mBytesPerPacket = srcASBD.mBytesPerFrame
        srcASBD.mChannelsPerFrame = UInt32(channels)
        srcASBD.mBitsPerChannel = 32

        if converter == nil || convRate != asbd.mSampleRate || convChannels != asbd.mChannelsPerFrame {
            guard let srcFormat = AVAudioFormat(streamDescription: &srcASBD) else { return }
            converter = AVAudioConverter(from: srcFormat, to: target)
            convRate = asbd.mSampleRate
            convChannels = asbd.mChannelsPerFrame
        }
        guard let converter,
              let srcBuf = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        srcBuf.frameLength = AVAudioFrameCount(frames)
        srcData.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: Float.self).baseAddress, let dst = srcBuf.floatChannelData?[0] {
                dst.update(from: base, count: frames * channels)
            }
        }

        let capacity = AVAudioFrameCount(Double(frames) * 48000.0 / asbd.mSampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var convError: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return srcBuf
        }
        converter.convert(to: out, error: &convError, withInputFrom: inputBlock)
        if let convError {
            Diag.log("SCK conversion failed at buffer #\(bufferCount): \(convError.localizedDescription)")
            return
        }
        if out.frameLength == 0 { return }
        guard let ch = out.floatChannelData?[0] else { return }

        let outFrames = Int(out.frameLength)
        let data = Data(bytes: ch, count: outFrames * MemoryLayout<Float>.size)
        let level = AudioPCM.rmsLevel(ch, frames: outFrames, channels: 1)
        onPCM?(data, level)
    }
}