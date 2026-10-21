import Foundation

struct RecordingItem: Identifiable, Hashable {
    var id: String { fileURL.path }
    let fileURL: URL
    let filename: String
    let createdAt: Date
    let size: Int64
    var duration: TimeInterval
    var transcriptURL: URL?
    var hasTranscript: Bool { transcriptURL != nil }
}

enum PathGuard {
    static let audioExtensions: Set<String> = ["m4a", "wav"]
    static let transcriptExtensions: Set<String> = ["txt", "json"]

    /// A `tmp` directory inside the app’s Application Support folder.
    /// All transient app artifacts (diagnostics, mixdowns, test scratch) go here
    /// instead of the shared system `/tmp`.
    static var appTempDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plume", isDirectory: true)
        let tmp = base.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// Remove leftover mono mixdown WAVs from previous crashed sessions.
    static func cleanStaleTempMixdowns() {
        let fm = FileManager.default
        let tmp = appTempDirectory
        guard let files = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("plume-mix-") && file.pathExtension == "wav" {
            try? fm.removeItem(at: file)
        }
    }

    static func assertUnderSaveFolder(_ url: URL, saveFolder: URL) throws -> URL {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let root = saveFolder.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if resolved.path != root.path && !resolved.path.hasPrefix(rootPath) {
            throw PathError.notAllowed
        }
        return resolved
    }

    static func assertAudioFile(_ url: URL, saveFolder: URL) throws -> URL {
        let resolved = try assertUnderSaveFolder(url, saveFolder: saveFolder)
        let ext = resolved.pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { throw PathError.notAudio }
        return resolved
    }

    static func sidecarURL(for audioURL: URL, ext: String) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension(ext)
    }

    static func resolveRenameTarget(dir: URL, oldURL: URL, newName: String, ext: String, exists: (URL) -> Bool) -> URL {
        var base = newName
        let lowerExt = "." + ext.lowercased()
        if base.lowercased().hasSuffix(lowerExt) {
            base = String(base.dropLast(lowerExt.count))
        }
        var target = dir.appendingPathComponent(base + "." + ext)
        var n = 1
        while exists(target) && target != oldURL {
            target = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return target
    }
}

enum PathError: LocalizedError {
    case notAllowed
    case notAudio

    var errorDescription: String? {
        switch self {
        case .notAllowed: return "Path not allowed"
        case .notAudio: return "Not an audio file"
        }
    }
}
