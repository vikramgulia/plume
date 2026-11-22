import Foundation
import CryptoKit

enum ModelInstallState: Equatable {
    case notInstalled
    /// Fraction from 0 to 1.
    case downloading(Double)
    case verifying
    case unpacking
    case installed
    case failed(String)
}

enum ModelInstallError: LocalizedError {
    case notEnoughSpace(needed: Int64)
    case badResponse(Int)
    case checksumMismatch
    case extractionFailed(String)
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed):
            return "Not enough free disk space. About \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) is needed."
        case .badResponse(let code):
            return "The download server answered with an error (\(code))."
        case .checksumMismatch:
            return "The downloaded file did not match its checksum, so it was discarded. Try again."
        case .extractionFailed(let detail):
            return "Could not unpack the model: \(detail)"
        case .missingFile(let name):
            return "The model archive is missing \(name)."
        }
    }
}

/// Downloads, verifies and keeps Whisper models in Application Support. Nothing is downloaded
/// unless `startInstall` is called, which the app only does after the user agrees.
@MainActor
final class WhisperModelStore: ObservableObject {
    static let shared = WhisperModelStore()

    @Published private(set) var states: [String: ModelInstallState] = [:]

    let root: URL
    private var tasks: [String: Task<Void, Never>] = [:]

    init(root: URL = WhisperModelStore.defaultRoot) {
        self.root = root
        refresh()
    }

    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plume/Models/whisper", isDirectory: true)
    }

    // MARK: Installed models

    func directory(for model: WhisperModel) -> URL {
        root.appendingPathComponent(model.id, isDirectory: true)
    }

    /// Fixed names inside a model's folder, whatever the archive called them.
    func files(for model: WhisperModel) -> (encoder: URL, decoder: URL, tokens: URL) {
        let dir = directory(for: model)
        return (dir.appendingPathComponent("encoder.int8.onnx"),
                dir.appendingPathComponent("decoder.int8.onnx"),
                dir.appendingPathComponent("tokens.txt"))
    }

    func isInstalled(_ model: WhisperModel) -> Bool {
        let f = files(for: model)
        let fm = FileManager.default
        return [f.encoder, f.decoder, f.tokens].allSatisfy { fm.fileExists(atPath: $0.path) }
    }

    var installedModels: [WhisperModel] {
        WhisperModelCatalog.models.filter(isInstalled)
    }

    func state(for model: WhisperModel) -> ModelInstallState {
        states[model.id] ?? (isInstalled(model) ? .installed : .notInstalled)
    }

    /// Re-reads what is on disk (keeps downloads that are in progress).
    func refresh() {
        for model in WhisperModelCatalog.models where tasks[model.id] == nil {
            states[model.id] = isInstalled(model) ? .installed : .notInstalled
        }
    }

    func remove(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        try? FileManager.default.removeItem(at: directory(for: model))
        states[model.id] = .notInstalled
    }

    // MARK: Install

    func startInstall(_ model: WhisperModel) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        states[model.id] = .downloading(0)
        tasks[model.id] = Task { [weak self] in
            await self?.install(model)
        }
    }

    func cancelInstall(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
    }

    private func install(_ model: WhisperModel) async {
        let fm = FileManager.default
        let work = root.appendingPathComponent(".downloads/\(model.id)", isDirectory: true)
        defer {
            try? fm.removeItem(at: work)
            tasks[model.id] = nil
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            // The archive and the unpacked files exist side by side for a moment.
            let needed = model.archiveBytes + model.installedBytes + 100_000_000
            if let free = Self.freeSpace(at: root), free < needed {
                throw ModelInstallError.notEnoughSpace(needed: needed)
            }

            let archive = work.appendingPathComponent("model.tar.bz2")
            let id = model.id
            let downloader = FileDownloader(destination: archive) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .downloading(let last)? = self.states[id], fraction - last >= 0.005 || fraction >= 1 else { return }
                    self.states[id] = .downloading(fraction)
                }
            }
            try await downloader.run(model.archiveURL)
            try Task.checkCancellation()

            states[model.id] = .verifying
            let expected = model.sha256
            let actual = try await Task.detached(priority: .utility) { try Self.sha256(of: archive) }.value
            guard actual == expected else { throw ModelInstallError.checksumMismatch }
            try Task.checkCancellation()

            states[model.id] = .unpacking
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            let members = model.archiveMembers
            try await Task.detached(priority: .utility) {
                try Self.extract(archive: archive, members: members, into: unpacked)
            }.value
            try Task.checkCancellation()

            let final = directory(for: model)
            try? fm.removeItem(at: final)
            try fm.createDirectory(at: final, withIntermediateDirectories: true)
            let target = files(for: model)
            let pairs: [(String, URL)] = [(model.encoderFile, target.encoder), (model.decoderFile, target.decoder), (model.tokensFile, target.tokens)]
            for (name, destination) in pairs {
                let source = unpacked.appendingPathComponent("\(model.archiveFolder)/\(name)")
                guard fm.fileExists(atPath: source.path) else { throw ModelInstallError.missingFile(name) }
                try fm.moveItem(at: source, to: destination)
            }
            states[model.id] = .installed
        } catch is CancellationError {
            states[model.id] = isInstalled(model) ? .installed : .notInstalled
        } catch let error as URLError where error.code == .cancelled {
            states[model.id] = isInstalled(model) ? .installed : .notInstalled
        } catch {
            try? fm.removeItem(at: directory(for: model))
            states[model.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Helpers (also used by the tests)

    nonisolated static func freeSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// SHA-256 of a file as lowercase hex, read in chunks so large models stay out of memory.
    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unpacks only `members` from a .tar.bz2 into `directory` with the system `tar`.
    nonisolated static func extract(archive: URL, members: [String], into directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path] + members
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: message, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ModelInstallError.extractionFailed(detail.isEmpty ? "tar exited with \(process.terminationStatus)" : detail)
        }
    }
}

/// Downloads one file with progress, to `destination`.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                self.session = session
                lock.unlock()
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            self.lock.lock()
            let session = self.session
            self.lock.unlock()
            session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ModelInstallError.badResponse(http.statusCode)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(error) }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
