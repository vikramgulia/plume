import Foundation
import AppKit

enum RecordingState: String {
    case idle
    case recording
    case stopping
}

@MainActor
final class RecordingService: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var systemLevel: Float = 0
    @Published var micLevel: Float = 0
    @Published var lastError: String?
    @Published var lastOutputURL: URL?

    /// Non-fatal problems while recording (for example the microphone stopped).
    var onNotice: ((String) -> Void)?

    /// Called when capture fails mid-recording and the partial recording was saved.
    var onUnexpectedStop: ((URL?) -> Void)?

    private let prefs = PreferencesStore.shared
    private var systemCapture: AnyObject?
    private var micCapture: MicCapture?
    private var writer: AudioFileWriter?
    private var timer: Timer?
    private var startedAt: Date?
    private var withMic = false
    private var outputURL: URL?
    private var starting = false
    private var stopRequestedDuringStart = false
    private var receivedSystemAudio = false

    func start(withMicrophone: Bool) async {
        guard state == .idle, !starting else { return }
        starting = true
        defer { starting = false }
        lastError = nil
        stopRequestedDuringStart = false
        receivedSystemAudio = false
        withMic = withMicrophone

        let folder = prefs.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Self.timestamp()
        let ext = prefs.format.fileExtension
        let url = folder.appendingPathComponent("Recording \(stamp).\(ext)")
        outputURL = url

        guard #available(macOS 13.0, *) else {
            lastError = "Plume requires macOS 13 or later"
            return
        }

        let capture = SystemAudioCapture()
        systemCapture = capture
        let mic = MicCapture()
        micCapture = mic

        var captureError: Error?

        capture.onError = { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                captureError = err
                if self.state == .recording && !self.starting {
                    // Already recording: keep what was captured instead of deleting it.
                    let url = await self.stop()
                    self.lastError = err.localizedDescription
                    self.onUnexpectedStop?(url)
                } else if self.state != .stopping {
                    self.lastError = err.localizedDescription
                    self.failCleanup()
                }
            }
        }

        // Recording begins as soon as capture is running (or the first audio arrives),
        // not only once something is playing; a silent source is padded with silence.
        capture.onStarted = { [weak self] in
            Task { @MainActor in self?.beginRecording(to: url) }
        }

        capture.onPCM = { [weak self] data, level in
            Task { @MainActor in
                guard let self else { return }
                self.systemLevel = level
                self.receivedSystemAudio = true
                if self.writer == nil { self.beginRecording(to: url) }
                self.writer?.appendSystem(data)
            }
        }

        if withMicrophone {
            mic.onError = { [weak self] err in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.micLevel = 0
                    self.onNotice?("Microphone stopped (\(err.localizedDescription)). System audio is still recording.")
                }
            }
            mic.onPCM = { [weak self] data, level in
                Task { @MainActor in
                    self?.micLevel = level
                    self?.writer?.appendMic(data)
                }
            }
            do {
                try mic.start()
            } catch {
                lastError = "Microphone unavailable: \(error.localizedDescription)"
                withMic = false
            }
        }

        capture.start()

        // Give ScreenCaptureKit up to 15 seconds to start capturing.
        for _ in 0..<150 {
            if state == .recording || captureError != nil || stopRequestedDuringStart { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if stopRequestedDuringStart {
            stopRequestedDuringStart = false
            failCleanup()
            return
        }

        if state != .recording {
            if captureError == nil && lastError == nil {
                lastError = "Could not start capturing system audio. Check the Screen Recording permission."
            }
            failCleanup()
        }
    }

    /// Creates the writer and flips the UI to recording. Safe to call more than once.
    private func beginRecording(to url: URL) {
        guard writer == nil, state == .idle, starting, url == outputURL else { return }
        do {
            let w = AudioFileWriter()
            try w.start(format: prefs.format, output: url)
            writer = w
            state = .recording
            startedAt = Date()
            elapsed = 0
            startTimer()
            Diag.log("REC writer created, state=.recording")
        } catch {
            Diag.log("REC writer start failed: \(error.localizedDescription)")
            lastError = error.localizedDescription
            failCleanup()
            return
        }
        // Bluetooth devices often stop delivering when their audio profile switches
        // at capture start; give the mic one kick if it is still silent shortly after.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.state == .recording, self.withMic,
                  let mic = self.micCapture, !mic.hasDeliveredFrames else { return }
            Diag.log("REC mic has no frames — kicking restart")
            mic.restart()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.state == .recording, !self.receivedSystemAudio else { return }
            Diag.log("REC no system audio received after 10s (nothing playing, or capture is silent)")
        }
    }

    func stop() async -> URL? {
        if starting {
            stopRequestedDuringStart = true
            return nil
        }
        guard state == .recording else { return lastOutputURL }
        Diag.log("REC stop requested")
        state = .stopping
        timer?.invalidate()
        timer = nil

        if #available(macOS 13.0, *) {
            (systemCapture as? SystemAudioCapture)?.stop()
        }
        micCapture?.stop()

        do {
            try await writer?.finish()
        } catch {
            lastError = error.localizedDescription
        }
        writer = nil
        systemCapture = nil
        micCapture = nil
        state = .idle
        systemLevel = 0
        micLevel = 0

        let url = outputURL
        lastOutputURL = url
        if prefs.openInFinderAfter, let url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        return url
    }

    private func failCleanup() {
        if #available(macOS 13.0, *) {
            (systemCapture as? SystemAudioCapture)?.stop()
        }
        micCapture?.stop()
        writer?.cancel()
        writer = nil
        systemCapture = nil
        micCapture = nil
        state = .idle
        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private static func timestamp() -> String {
        let c = Calendar.current
        let d = Date()
        let y = c.component(.year, from: d)
        let mo = String(format: "%02d", c.component(.month, from: d))
        let day = String(format: "%02d", c.component(.day, from: d))
        let h = String(format: "%02d", c.component(.hour, from: d))
        let mi = String(format: "%02d", c.component(.minute, from: d))
        let s = String(format: "%02d", c.component(.second, from: d))
        return "\(y)-\(mo)-\(day) \(h).\(mi).\(s)"
    }
}