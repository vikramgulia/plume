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

        recording.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                PillController.shared.setVisible(state == .recording && (self?.preferences.showFloatingPill ?? true))
            }
            .store(in: &cancellables)

        recording.$elapsed
            .receive(on: RunLoop.main)
            .sink { elapsed in
                PillController.shared.setElapsed(elapsed)
            }
            .store(in: &cancellables)
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

    func stopRecording() async {
        let url = await recording.stop()
        await library.reload()
        if let url {
            showToast("Recording saved")
            if preferences.autoTranscribe {
                transcription.start(url)
            }
        }
        if let err = recording.lastError {
            showToast(err)
        }
    }
}
