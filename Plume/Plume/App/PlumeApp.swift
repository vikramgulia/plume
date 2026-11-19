import SwiftUI
import AppKit

@main
struct PlumeApp: App {
    @StateObject private var appState = AppState()
    @ObservedObject private var prefs = PreferencesStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(prefs)
                .frame(minWidth: 400, idealWidth: 400, minHeight: 560, idealHeight: 560)
                .preferredColorScheme(colorScheme)
                .onAppear {
                    appDelegate.appState = appState
                    NSApp.setActivationPolicy(.regular)
                }
                .onReceive(NotificationCenter.default.publisher(for: .plumeStopRecording)) { _ in
                    Task { await appState.stopRecording() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .plumeStartRecording)) { _ in
                    Task { await appState.startRecording() }
                }
        }
        .defaultSize(width: 400, height: 560)

        MenuBarExtra("Plume", systemImage: appState.recording.state == .recording ? "record.circle.fill" : "waveform.circle") {
            Button(appState.recording.state == .recording
                   ? "Stop Recording (\(formatElapsed(appState.recording.elapsed)))"
                   : "Start Recording") {
                Task {
                    if appState.recording.state == .recording {
                        await appState.stopRecording()
                    } else {
                        await appState.startRecording()
                    }
                }
            }
            Button("Start Voice Note") {
                Task { await appState.startVoiceNote() }
            }
            .disabled(appState.recording.state != .idle)
            Divider()
            Menu("Recent Recordings") {
                ForEach(Array(appState.library.recordings.prefix(5))) { rec in
                    Button(rec.filename) {
                        appState.selectedTab = .recordings
                        appState.highlightRecordingPath = rec.fileURL.path
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                if appState.library.recordings.isEmpty {
                    Text("No recordings")
                }
            }
            Button("Open Save Folder") {
                NSWorkspace.shared.open(prefs.saveFolder)
            }
            Divider()
            Button("Show Plume") {
                NSApp.activate(ignoringOtherApps: true)
                for w in NSApp.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) }
            }
            Toggle("Floating Pill", isOn: $prefs.showFloatingPill)
            Button("Settings…") {
                appState.selectedTab = .settings
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Plume") { NSApp.terminate(nil) }
        }
    }

    private var colorScheme: ColorScheme? {
        switch prefs.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Finish and save an in-progress recording before quitting, so the file is playable.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, appState.recording.state != .idle else { return .terminateNow }
        Task { @MainActor in
            await appState.finalizeRecordingForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack(alignment: .top) {
            // macOS 26 renders these tabs as Liquid Glass segments in the window toolbar.
            TabView(selection: $app.selectedTab) {
                Tab("Home", systemImage: "mic.fill", value: AppState.Tab.home) { HomeView().readableWidth() }
                Tab("Recordings", systemImage: "list.bullet", value: AppState.Tab.recordings) { RecordingsView() }
                Tab("Settings", systemImage: "gearshape", value: AppState.Tab.settings) { SettingsView().readableWidth() }
            }

            if let toast = app.toast {
                ToastBanner(message: toast)
            }
        }
    }
}
