import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class AppState: ObservableObject {
    let preferences = PreferencesStore.shared
    let recording = RecordingService()
    let library = RecordingLibrary()
    let permissions = PermissionsService()
    let transcription = TranscriptionService()
    let hotKeys = GlobalHotKeyService()
    let liveCaptions = LiveCaptionService()

    @Published var selectedTab: Tab = .home
    @Published var toast: String?
    @Published var highlightRecordingPath: String?

    enum Tab: Hashable {
        case home, recordings, settings
    }

    private var cancellables = Set<AnyCancellable>()

    init() {
        PathGuard.cleanStaleTempMixdowns()
        library.startWatching()
        Task { await permissions.refresh() }

        // Bubble child ObservableObject changes so views observing AppState refresh.
        recording.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        library.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        permissions.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        transcription.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)

        hotKeys.onAction = { [weak self] action in
            Task { @MainActor in await self?.handleHotKey(action) }
        }
        preferences.$toggleRecordingShortcut
            .sink { [weak self] shortcut in self?.applyShortcut(shortcut, for: .toggleRecording) }
            .store(in: &cancellables)
        preferences.$voiceNoteShortcut
            .sink { [weak self] shortcut in self?.applyShortcut(shortcut, for: .voiceNote) }
            .store(in: &cancellables)

        recording.onNotice = { [weak self] message in
            Task { @MainActor in self?.showToast(message) }
        }

        recording.onUnexpectedStop = { [weak self] url in
            Task { @MainActor in await self?.finishRecording(url, interrupted: true) }
        }

        recording.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                PillController.shared.setVisible(state == .recording && (self?.preferences.showFloatingPill ?? true))
            }
            .store(in: &cancellables)

        liveCaptions.onProblem = { [weak self] message in
            Task { @MainActor in self?.showToast(message) }
        }
        liveCaptions.objectWillChange.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        recording.onLiveAudio = { [weak self] data, source in
            self?.liveCaptions.feed(data, source: source)
        }
        recording.$state
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    if state == .recording, self.preferences.liveCaptions {
                        await self.startLiveCaptions()
                    } else if state != .recording {
                        CaptionPanelController.shared.hide()
                        await self.liveCaptions.stop()
                    }
                }
            }
            .store(in: &cancellables)

        recording.$elapsed
            .receive(on: RunLoop.main)
            .sink { elapsed in
                PillController.shared.setElapsed(elapsed)
            }
            .store(in: &cancellables)
    }

    func startLiveCaptions() async {
        let sources: [CaptionSource] = recording.mode == .voiceNote ? [.you] : [.others, .you]
        await liveCaptions.start(sources: sources, language: preferences.transcriptionLanguage)
        if liveCaptions.isRunning { showCaptionPanel() }
    }

    func showCaptionPanel() {
        CaptionPanelController.shared.show(service: liveCaptions) { [weak self] in self?.openRecordingScreen() }
    }

    /// Brings Plume's window to the front on the Home (recording) screen.
    func openRecordingScreen() {
        selectedTab = .home
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }

    func startRecording() async {
        await permissions.refresh()
        if permissions.screenStatus == .denied {
            showToast("Screen Recording permission required")
            permissions.openScreenRecordingSettings()
            return
        }
        let mic = await permissions.requestMicrophone()
        await recording.start(withMicrophone: mic)
        if let err = recording.lastError {
            showToast(err)
        }
    }

    /// Saves any recording still in progress. Waits out a stop that is already underway.
    func finalizeRecordingForQuit() async {
        switch recording.state {
        case .recording:
            _ = await recording.stop()
        case .stopping:
            var waited = 0
            while recording.state == .stopping && waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
        case .idle:
            break
        }
    }

    private func applyShortcut(_ shortcut: Shortcut?, for action: HotKeyAction) {
        if !hotKeys.set(shortcut, for: action), let shortcut {
            showToast("\(shortcut.displayString) is already in use. Pick another shortcut in Settings.")
        }
    }

    /// A global shortcut stops whatever is recording, or starts the recording it is bound to.
    private func handleHotKey(_ action: HotKeyAction) async {
        switch recording.state {
        case .recording:
            await stopRecording()
            NSSound(named: "Pop")?.play()
        case .idle:
            switch action {
            case .toggleRecording: await startRecording()
            case .voiceNote: await startVoiceNote()
            }
            if recording.state == .recording { NSSound(named: "Tink")?.play() }
        case .stopping:
            break
        }
    }

    /// Records the microphone only (no system audio, no Screen Recording permission).
    func startVoiceNote() async {
        guard await permissions.requestMicrophone() else {
            showToast("Microphone permission required")
            permissions.openMicrophoneSettings()
            return
        }
        await recording.start(withMicrophone: true, mode: .voiceNote)
        if let err = recording.lastError {
            showToast(err)
        }
    }

    func stopRecording() async {
        let url = await recording.stop()
        await finishRecording(url)
    }

    private func finishRecording(_ url: URL?, interrupted: Bool = false) async {
        await library.reload()
        if let url {
            if preferences.autoTranscribe {
                transcription.start(url)
            }
            if interrupted {
                let reason = recording.lastError ?? "capture stopped"
                showToast("Recording stopped (\(reason)). What was captured is saved.")
                return
            }
            showToast("Recording saved")
        }
        if let err = recording.lastError {
            showToast(err)
        }
    }
}
