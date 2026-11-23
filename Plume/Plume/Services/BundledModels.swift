import Foundation

/// Finds small model files that ship inside the app (and in `extraResources/` for development builds).
enum BundledModels {
    nonisolated static func url(for file: String) -> URL? {
        let fm = FileManager.default
        func find(_ dir: URL) -> URL? {
            let candidate = dir.appendingPathComponent(file)
            return fm.fileExists(atPath: candidate.path) ? candidate : nil
        }
        // Release builds: Resources/diarization-models (also holds the speech detector).
        if let res = Bundle.main.resourceURL, let found = find(res.appendingPathComponent("diarization-models")) {
            return found
        }
        // Development and test checkouts: walk up from the build products to the repo's extraResources.
        var probe = Bundle.main.bundleURL
        for _ in 0..<8 {
            probe = probe.deletingLastPathComponent()
            if let found = find(probe.appendingPathComponent("extraResources/diarization-models")) {
                return found
            }
        }
        return find(URL(fileURLWithPath: "extraResources/diarization-models"))
    }

    nonisolated static var sileroVAD: URL? { url(for: "silero_vad.onnx") }
}
