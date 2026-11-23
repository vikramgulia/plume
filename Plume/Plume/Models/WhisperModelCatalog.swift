import Foundation

/// A Whisper speech model Plume can download and run on the Mac (through sherpa-onnx).
struct WhisperModel: Identifiable, Equatable {
    enum Languages: Equatable {
        case multilingual
        case englishOnly
    }

    let id: String
    let name: String
    let languages: Languages
    /// One-line description for the picker.
    let summary: String
    /// 1 (lowest) to 5 (highest), relative to the other models listed. Speed depends on the Mac.
    let accuracy: Int
    let speed: Int

    let archiveURL: URL
    let archiveBytes: Int64
    let sha256: String
    /// Folder inside the archive and the three files Plume uses (the compressed int8 versions).
    let archiveFolder: String
    let encoderFile: String
    let decoderFile: String
    let tokensFile: String
    /// Disk space the three files take once unpacked.
    let installedBytes: Int64

    var isMultilingual: Bool { languages == .multilingual }

    var archiveMembers: [String] {
        [encoderFile, decoderFile, tokensFile].map { "\(archiveFolder)/\($0)" }
    }
}

enum WhisperModelCatalog {
    private static let releases = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"

    /// The model offered first and pre-selected.
    static let defaultMultilingual = "small"
    static let defaultEnglishOnly = "small.en"

    static let models: [WhisperModel] = [
        WhisperModel(
            id: "base", name: "Base", languages: .multilingual,
            summary: "Small and quick. Fair accuracy; fine for clear speech.",
            accuracy: 2, speed: 4,
            archiveURL: URL(string: releases + "sherpa-onnx-whisper-base.tar.bz2")!,
            archiveBytes: 207_557_382,
            sha256: "911b2083efd7c0dca2ac3b358b75222660dc09fb716d64fbfc417ba6c99ff3de",
            archiveFolder: "sherpa-onnx-whisper-base",
            encoderFile: "base-encoder.int8.onnx", decoderFile: "base-decoder.int8.onnx", tokensFile: "base-tokens.txt",
            installedBytes: 160_609_290),
        WhisperModel(
            id: "small", name: "Small", languages: .multilingual,
            summary: "Good accuracy in about 100 languages. The recommended starting point.",
            accuracy: 3, speed: 3,
            archiveURL: URL(string: releases + "sherpa-onnx-whisper-small.tar.bz2")!,
            archiveBytes: 639_387_718,
            sha256: "486a46afbb7ba798507190ffe02fea2dd726049af212e774537efac6afb210a6",
            archiveFolder: "sherpa-onnx-whisper-small",
            encoderFile: "small-encoder.int8.onnx", decoderFile: "small-decoder.int8.onnx", tokensFile: "small-tokens.txt",
            installedBytes: 375_485_327),
        WhisperModel(
            id: "small.en", name: "Small (English only)", languages: .englishOnly,
            summary: "Same size as Small, a little more accurate for English, but English only.",
            accuracy: 4, speed: 3,
            archiveURL: URL(string: releases + "sherpa-onnx-whisper-small.en.tar.bz2")!,
            archiveBytes: 635_693_775,
            sha256: "0cdba2b8aaab69e04847f3427cc9709574112e67913a1a84b7fec3a8729faa9a",
            archiveFolder: "sherpa-onnx-whisper-small.en",
            encoderFile: "small.en-encoder.int8.onnx", decoderFile: "small.en-decoder.int8.onnx", tokensFile: "small.en-tokens.txt",
            installedBytes: 375_501_079),
        WhisperModel(
            id: "medium", name: "Medium", languages: .multilingual,
            summary: "High accuracy in about 100 languages. Large download and slower than Small.",
            accuracy: 4, speed: 2,
            archiveURL: URL(string: releases + "sherpa-onnx-whisper-medium.tar.bz2")!,
            archiveBytes: 1_931_372_882,
            sha256: "614b1172557049069d846c29d9399640bce83a4dd6c580decebd9ce2a4f32c33",
            archiveFolder: "sherpa-onnx-whisper-medium",
            encoderFile: "medium-encoder.int8.onnx", decoderFile: "medium-decoder.int8.onnx", tokensFile: "medium-tokens.txt",
            installedBytes: 946_072_270),
        WhisperModel(
            id: "medium.en", name: "Medium (English only)", languages: .englishOnly,
            summary: "Same size as Medium, a little more accurate for English, but English only.",
            accuracy: 4, speed: 2,
            archiveURL: URL(string: releases + "sherpa-onnx-whisper-medium.en.tar.bz2")!,
            archiveBytes: 1_905_872_689,
            sha256: "73d95c169a410b5f23a79f8901374b26e0a16a09ea7f02b5e1db983f4cdfdd67",
            archiveFolder: "sherpa-onnx-whisper-medium.en",
            encoderFile: "medium.en-encoder.int8.onnx", decoderFile: "medium.en-decoder.int8.onnx", tokensFile: "medium.en-tokens.txt",
            installedBytes: 946_086_998),
        WhisperModel(
            id: "turbo", name: "Turbo", languages: .multilingual,
            summary: "Close to the best Whisper accuracy in about 100 languages. Needs about 1 GB of disk space.",
            accuracy: 5, speed: 2,
            archiveURL: URL(string: releases + "sherpa-onnx-whisper-turbo.tar.bz2")!,
            archiveBytes: 563_790_207,
            sha256: "b11acbbcd660b44a8e0df33724feb5aaa709cf65668f2823d59f656312544f22",
            archiveFolder: "sherpa-onnx-whisper-turbo",
            encoderFile: "turbo-encoder.int8.onnx", decoderFile: "turbo-decoder.int8.onnx", tokensFile: "turbo-tokens.txt",
            installedBytes: 1_036_613_791),
    ]

    static func model(id: String) -> WhisperModel? {
        models.first { $0.id == id }
    }
}
