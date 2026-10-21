import Foundation
import CoreMedia
import AVFoundation
import CoreAudio

enum AudioPCM {
    /// Mono RMS across channels, mapped roughly to 0...1.
    static func rmsLevel(_ buf: UnsafePointer<Float32>, frames: Int, channels: Int) -> Float {
        guard frames > 0 else { return 0 }
        var sum: Double = 0
        let n = frames * channels
        for i in 0..<n {
            let v = Double(buf[i])
            sum += v * v
        }
        let rms = sqrt(sum / Double(n))
        let mapped = 20.0 * log10(max(rms, 1e-7)) + 60.0
        return Float(max(0, min(1, mapped / 60.0)))
    }

    /// Extract interleaved Float32 PCM from a CMSampleBuffer.
    static func interleavedPCM(from sampleBuffer: CMSampleBuffer, frames: Int, channels: Int) -> Data? {
        guard channels > 0, frames > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        let maxBuffers = max(channels, 1)
        let ablPtr = AudioBufferList.allocate(maximumBuffers: maxBuffers)
        defer { free(ablPtr.unsafeMutablePointer) }
        let ablByteSize = MemoryLayout<AudioBufferList>.size
            + (maxBuffers - 1) * MemoryLayout<AudioBuffer>.size

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr.unsafeMutablePointer,
            bufferListSize: ablByteSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        if ablPtr.count == 1 {
            guard let mData = ablPtr[0].mData else { return nil }
            return Data(bytes: mData, count: Int(ablPtr[0].mDataByteSize))
        }

        var out = [Float32](repeating: 0, count: frames * ablPtr.count)
        for (ch, buffer) in ablPtr.enumerated() {
            guard let mData = buffer.mData else { continue }
            let src = mData.assumingMemoryBound(to: Float32.self)
            let n = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size)
            for i in 0..<n {
                out[i * ablPtr.count + ch] = src[i]
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
