// Vendored from k2-fsa/sherpa-onnx v1.13.3 (Apache-2.0),
// swift-api-examples/SherpaOnnx.swift — trimmed to the offline speaker
// diarization and speaker embedding extractor wrappers Plume uses.

import Foundation

func toCPointer(_ s: String) -> UnsafePointer<Int8>! {
  let cs = (s as NSString).utf8String
  return UnsafePointer<Int8>(cs)
}

func sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: String)
  -> SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig
{
  return SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(model: toCPointer(model))
}

func sherpaOnnxOfflineSpeakerSegmentationModelConfig(
  pyannote: SherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxOfflineSpeakerSegmentationModelConfig {
  return SherpaOnnxOfflineSpeakerSegmentationModelConfig(
    pyannote: pyannote,
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider)
  )
}

func sherpaOnnxFastClusteringConfig(numClusters: Int = -1, threshold: Float = 0.5)
  -> SherpaOnnxFastClusteringConfig
{
  return SherpaOnnxFastClusteringConfig(num_clusters: Int32(numClusters), threshold: threshold)
}

func sherpaOnnxSpeakerEmbeddingExtractorConfig(
  model: String,
  numThreads: Int = 1,
  debug: Int = 0,
  provider: String = "cpu"
) -> SherpaOnnxSpeakerEmbeddingExtractorConfig {
  return SherpaOnnxSpeakerEmbeddingExtractorConfig(
    model: toCPointer(model),
    num_threads: Int32(numThreads),
    debug: Int32(debug),
    provider: toCPointer(provider)
  )
}

func sherpaOnnxOfflineSpeakerDiarizationConfig(
  segmentation: SherpaOnnxOfflineSpeakerSegmentationModelConfig,
  embedding: SherpaOnnxSpeakerEmbeddingExtractorConfig,
  clustering: SherpaOnnxFastClusteringConfig,
  minDurationOn: Float = 0.3,
  minDurationOff: Float = 0.5
) -> SherpaOnnxOfflineSpeakerDiarizationConfig {
  return SherpaOnnxOfflineSpeakerDiarizationConfig(
    segmentation: segmentation,
    embedding: embedding,
    clustering: clustering,
    min_duration_on: minDurationOn,
    min_duration_off: minDurationOff
  )
}

struct SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper {
  var start: Float = 0
  var end: Float = 0
  var speaker: Int = 0
}

class SherpaOnnxOfflineSpeakerDiarizationWrapper {
  let impl: OpaquePointer!

  init(
    config: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationConfig>!
  ) {
    impl = SherpaOnnxCreateOfflineSpeakerDiarization(config)
  }

  deinit {
    if let impl {
      SherpaOnnxDestroyOfflineSpeakerDiarization(impl)
    }
  }

  var sampleRate: Int {
    return Int(SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(impl))
  }

  func process(samples: [Float]) -> [SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper] {
    let result = SherpaOnnxOfflineSpeakerDiarizationProcess(
      impl, samples, Int32(samples.count))

    if result == nil {
      return []
    }

    let numSegments = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))

    let p: UnsafePointer<SherpaOnnxOfflineSpeakerDiarizationSegment>? =
      SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result)

    if p == nil {
      SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)
      return []
    }

    var ans: [SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper] = []
    for i in 0..<numSegments {
      ans.append(
        SherpaOnnxOfflineSpeakerDiarizationSegmentWrapper(
          start: p![i].start, end: p![i].end, speaker: Int(p![i].speaker)))
    }

    SherpaOnnxOfflineSpeakerDiarizationDestroySegment(p)
    SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result)

    return ans
  }
}

class SherpaOnnxOnlineStreamWrapper {
  let impl: OpaquePointer!
  init(impl: OpaquePointer!) {
    self.impl = impl
  }

  deinit {
    if let impl {
      SherpaOnnxDestroyOnlineStream(impl)
    }
  }

  func acceptWaveform(samples: [Float], sampleRate: Int = 16000) {
    samples.withUnsafeBufferPointer { buf in
      SherpaOnnxOnlineStreamAcceptWaveform(impl, Int32(sampleRate), buf.baseAddress, Int32(samples.count))
    }
  }

  func inputFinished() {
    SherpaOnnxOnlineStreamInputFinished(impl)
  }
}

class SherpaOnnxSpeakerEmbeddingExtractorWrapper {
  let impl: OpaquePointer!

  init(
    config: UnsafePointer<SherpaOnnxSpeakerEmbeddingExtractorConfig>!
  ) {
    impl = SherpaOnnxCreateSpeakerEmbeddingExtractor(config)
  }

  deinit {
    if let impl {
      SherpaOnnxDestroySpeakerEmbeddingExtractor(impl)
    }
  }

  var dim: Int {
    return Int(SherpaOnnxSpeakerEmbeddingExtractorDim(impl))
  }

  func createStream() -> SherpaOnnxOnlineStreamWrapper {
    let newStream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(impl)
    return SherpaOnnxOnlineStreamWrapper(impl: newStream)
  }

  func isReady(stream: SherpaOnnxOnlineStreamWrapper) -> Bool {
    return SherpaOnnxSpeakerEmbeddingExtractorIsReady(impl, stream.impl) == 1 ? true : false
  }

  func compute(stream: SherpaOnnxOnlineStreamWrapper) -> [Float] {
    if !isReady(stream: stream) {
      return []
    }

    let p = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(impl, stream.impl)

    defer {
      SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(p)
    }

    return [Float](UnsafeBufferPointer(start: p, count: dim))
  }
}