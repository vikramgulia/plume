import Foundation
import AVFoundation
import AppKit
import CoreMedia

@MainActor
final class RecordingLibrary: ObservableObject {
    @Published var recordings: [RecordingItem] = []
    @Published var errorMessage: String?

    private var source: DispatchSourceFileSystemObject?
    private var folderFD: Int32 = -1
    private let prefs = PreferencesStore.shared

    func startWatching() {
        stopWatching()
        let folder = prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folderFD = open(folder.path, O_EVTONLY)
        guard folderFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: folderFD, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in await self?.reload() }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.folderFD, fd >= 0 { close(fd) }
            self?.folderFD = -1
        }
        source = src
        src.resume()
        Task { await reload() }
    }

    func stopWatching() {
        source?.cancel()
        source = nil
    }

    func reload() async {
        let folder = prefs.saveFolder
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            recordings = []
            return
        }
        let audio = files.filter { PathGuard.audioExtensions.contains($0.pathExtension.lowercased()) }
        var items: [RecordingItem] = []
        for url in audio {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let transcript = findTranscript(for: url)
            let duration = await duration(of: url)
            items.append(RecordingItem(
                fileURL: url,
                filename: url.lastPathComponent,
                createdAt: values?.contentModificationDate ?? Date(),
                size: Int64(values?.fileSize ?? 0),
                duration: duration,
                transcriptURL: transcript
            ))
        }
        recordings = items.sorted { $0.createdAt > $1.createdAt }
    }

    private func findTranscript(for audio: URL) -> URL? {
        for ext in PathGuard.transcriptExtensions {
            let side = PathGuard.sidecarURL(for: audio, ext: ext)
            if FileManager.default.fileExists(atPath: side.path) { return side }
        }
        return nil
    }

    private func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            return CMTimeGetSeconds(d)
        } catch {
            return 0
        }
    }

    func delete(_ item: RecordingItem) throws {
        let url = try PathGuard.assertAudioFile(item.fileURL, saveFolder: prefs.saveFolder)
        for ext in PathGuard.transcriptExtensions {
            let side = PathGuard.sidecarURL(for: url, ext: ext)
            try? FileManager.default.removeItem(at: side)
        }
        try FileManager.default.removeItem(at: url)
        recordings.removeAll { $0.id == item.id }
    }

    func rename(_ item: RecordingItem, to newName: String) throws -> RecordingItem {
        let old = try PathGuard.assertAudioFile(item.fileURL, saveFolder: prefs.saveFolder)
        let ext = old.pathExtension
        let target = PathGuard.resolveRenameTarget(
            dir: old.deletingLastPathComponent(),
            oldURL: old,
            newName: newName,
            ext: ext,
            exists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        try FileManager.default.moveItem(at: old, to: target)
        for extName in PathGuard.transcriptExtensions {
            let oldSide = PathGuard.sidecarURL(for: old, ext: extName)
            let newSide = PathGuard.sidecarURL(for: target, ext: extName)
            if FileManager.default.fileExists(atPath: oldSide.path) {
                try? FileManager.default.moveItem(at: oldSide, to: newSide)
            }
        }
        let updated = RecordingItem(
            fileURL: target,
            filename: target.lastPathComponent,
            createdAt: item.createdAt,
            size: item.size,
            duration: item.duration,
            transcriptURL: findTranscript(for: target)
        )
        if let idx = recordings.firstIndex(where: { $0.id == item.id }) {
            recordings[idx] = updated
        }
        return updated
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func readTranscript(for item: RecordingItem) -> String? {
        guard let t = item.transcriptURL else { return nil }
        return try? String(contentsOf: t, encoding: .utf8)
    }
}
