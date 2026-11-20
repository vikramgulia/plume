import SwiftUI
import AppKit
import Speech
import AVFoundation

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var prefs: PreferencesStore
    @ObservedObject private var speakers = SpeakerLibrary.shared
    @State private var languages: [Locale] = []
    @State private var assetStatus: AssetInventory.Status?
    @State private var installing = false
    @State private var installError: String?
    @State private var samplePlayer: AVAudioPlayer?
    @State private var playingID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.title3.weight(.semibold))

                group("Output") {
                    row("Save Folder", prefs.saveFolder.path) {
                        Button("Choose…") { chooseFolder() }
                    }
                    Divider()
                    row("Output Format", "M4A is smaller; WAV is lossless") {
                        Picker("", selection: $prefs.format) {
                            Text("M4A").tag(AudioFormat.m4a)
                            Text("WAV").tag(AudioFormat.wav)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }

                group("Transcription") {
                    Toggle("Auto-transcribe After Recording", isOn: $prefs.autoTranscribe)
                    Text("Runs locally on your Mac — no cloud")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("Language")
                        Spacer()
                        Picker("", selection: $prefs.transcriptionLanguage) {
                            ForEach(languages, id: \.identifier) { locale in
                                Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                    .tag(locale.identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        .onChange(of: prefs.transcriptionLanguage) { _ in
                            Task { await refreshAssets() }
                        }
                    }
                    Text(assetStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if assetStatus == .supported {
                        Button(installing ? "Installing…" : "Install language assets") {
                            Task { await installAssets() }
                        }
                        .disabled(installing)
                    }
                    if let installError {
                        Text(installError).font(.caption).foregroundStyle(.red)
                    }
                }

                group("General") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { prefs.launchAtLogin },
                        set: { enabled in
                            prefs.launchAtLogin = enabled
                            if #available(macOS 13.0, *) {
                                try? LoginItemService.setEnabled(enabled)
                            }
                        }
                    ))
                    Divider()
                    Toggle("Floating Pill While Recording", isOn: $prefs.showFloatingPill)
                    Divider()
                    Toggle("Open in Finder After Stop", isOn: $prefs.openInFinderAfter)
                    Divider()
                    HStack {
                        Text("Theme")
                        Spacer()
                        Picker("", selection: $prefs.theme) {
                            Text("System").tag(AppTheme.system)
                            Text("Light").tag(AppTheme.light)
                            Text("Dark").tag(AppTheme.dark)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }

                group("Shortcuts") {
                    row("Start / Stop Recording", "Works from any app") {
                        ShortcutRecorder(shortcut: $prefs.toggleRecordingShortcut, other: prefs.voiceNoteShortcut)
                    }
                    Divider()
                    row("Voice Note", "Start / stop a microphone-only note") {
                        ShortcutRecorder(shortcut: $prefs.voiceNoteShortcut, other: prefs.toggleRecordingShortcut)
                    }
                }

                group("Permissions") {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Screen Recording")
                            Text(app.permissions.screenStatus == .granted ? "Granted" : "Not granted")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Settings") { app.permissions.openScreenRecordingSettings() }
                    }
                    Divider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Microphone")
                            Text(app.permissions.micGranted ? "Granted" : "Not granted")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Request") {
                            Task { await app.permissions.requestMicrophoneOrOpenSettings() }
                        }
                    }
                }

                group("Speakers") {
                    if speakers.profiles().isEmpty {
                        Text("Remembered voices appear here after your first transcribed meeting. Voice profiles stay on this Mac.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(speakers.profiles()) { profile in
                            HStack {
                                Image(systemName: "person.wave.2.fill")
                                    .foregroundStyle(.secondary)
                                TextField("Name", text: Binding(
                                    get: { profile.name },
                                    set: { speakers.rename(id: profile.id, to: $0) }
                                ))
                                .textFieldStyle(.plain)
                                Spacer()
                                if speakers.sampleURL(for: profile) != nil {
                                    Button {
                                        toggleSample(profile)
                                    } label: {
                                        Image(systemName: playingID == profile.id ? "pause.circle.fill" : "play.circle.fill")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                Button {
                                    stopPlayer()
                                    speakers.remove(id: profile.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                group("About") {
                    HStack {
                        Image(systemName: "info.circle")
                        Text("Plume")
                        Text("v1.0.0").foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, 8)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await app.permissions.refresh() }
        }
        .task {
            await app.permissions.refresh()
            languages = await app.transcription.supportedLocales()
            await refreshAssets()
        }
    }

    private var assetStatusText: String {
        switch assetStatus {
        case .installed: return "Installed — ready to transcribe on this Mac"
        case .supported: return "Not installed yet — install before first transcription"
        case .downloading: return "Downloading…"
        case .unsupported: return "Unsupported on this Mac"
        case nil: return "Checking…"
        @unknown default: return "Checking…"
        }
    }

    private func refreshAssets() async {
        assetStatus = await app.transcription.assetStatus()
    }

    private func toggleSample(_ profile: SpeakerProfile) {
        if playingID == profile.id {
            stopPlayer()
            return
        }
        guard let url = speakers.sampleURL(for: profile),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        stopPlayer()
        player.play()
        samplePlayer = player
        playingID = profile.id
        DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.05) {
            if playingID == profile.id {
                stopPlayer()
            }
        }
    }

    private func stopPlayer() {
        samplePlayer?.stop()
        samplePlayer = nil
        playingID = nil
    }

    private func installAssets() async {
        installing = true
        installError = nil
        do {
            try await app.transcription.installAssets()
            await refreshAssets()
        } catch {
            installError = error.localizedDescription
        }
        installing = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            prefs.saveFolder = url
            app.library.startWatching()
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func row<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            trailing()
        }
    }
}
