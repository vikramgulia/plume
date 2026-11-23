import SwiftUI

private func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Five-dot rating used for accuracy and speed.
private struct Rating: View {
    let label: String
    let value: Int
    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            ForEach(1...5, id: \.self) { i in
                Circle()
                    .fill(i <= value ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) out of 5")
    }
}

/// Lists the Whisper models with their quality and size, and lets the user pick, download or delete them.
/// Nothing is downloaded until the user presses Download and confirms.
struct WhisperModelsView: View {
    @EnvironmentObject var prefs: PreferencesStore
    @ObservedObject var store: WhisperModelStore = .shared
    @State private var pendingDownload: WhisperModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(WhisperModelCatalog.models) { model in
                modelRow(model)
                if model.id != WhisperModelCatalog.models.last?.id { Divider() }
            }
        }
        .confirmationDialog(
            pendingDownload.map { "Download \($0.name)?" } ?? "",
            isPresented: Binding(get: { pendingDownload != nil }, set: { if !$0 { pendingDownload = nil } }),
            titleVisibility: .visible
        ) {
            if let model = pendingDownload {
                Button("Download \(sizeText(model.archiveBytes))") {
                    store.startInstall(model)
                    prefs.whisperModelID = model.id
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            if let model = pendingDownload {
                Text("Plume will download \(sizeText(model.archiveBytes)) from GitHub and keep \(sizeText(model.installedBytes)) on this Mac. Your audio is never uploaded.")
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModel) -> some View {
        let state = store.state(for: model)
        let selected = prefs.whisperModelID == model.id
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name).fontWeight(.medium)
                if selected, state == .installed {
                    Text("In use").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                Spacer()
                action(for: model, state: state, selected: selected)
            }
            Text(model.summary).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Rating(label: "Accuracy", value: model.accuracy)
                Rating(label: "Speed", value: model.speed)
                Text("\(sizeText(model.archiveBytes)) download · \(sizeText(model.installedBytes)) on disk")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if case .downloading(let p) = state {
                ProgressView(value: p)
            } else if state == .verifying || state == .unpacking {
                ProgressView().controlSize(.small)
            }
            if case .failed(let message) = state {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func action(for model: WhisperModel, state: ModelInstallState, selected: Bool) -> some View {
        switch state {
        case .installed:
            HStack {
                if !selected {
                    Button("Use") { prefs.whisperModelID = model.id }
                }
                Button("Delete", role: .destructive) { store.remove(model) }
            }
            .controlSize(.small)
        case .downloading:
            Button("Cancel") { store.cancelInstall(model) }.controlSize(.small)
        case .verifying, .unpacking:
            Text("Installing…").font(.caption).foregroundStyle(.secondary)
        case .notInstalled, .failed:
            Button("Download") { pendingDownload = model }.controlSize(.small)
        }
    }
}

/// Shown once, the first time Plume opens: offers to download Whisper, and says what happens if not.
struct WhisperOfferSheet: View {
    @EnvironmentObject var prefs: PreferencesStore
    @ObservedObject var store: WhisperModelStore = .shared
    @State private var englishOnly = false

    private var model: WhisperModel {
        WhisperModelCatalog.model(id: englishOnly ? WhisperModelCatalog.defaultEnglishOnly : WhisperModelCatalog.defaultMultilingual)!
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Better transcripts with Whisper")
                .font(.title3.weight(.semibold))
            Text("Plume can transcribe with OpenAI's Whisper model running entirely on your Mac. It is noticeably more accurate than Apple's built-in speech recognition, which Plume uses until you download a model — Apple's works, but it is not as good.")
                .fixedSize(horizontal: false, vertical: true)

            Picker("Languages", selection: $englishOnly) {
                Text("Multilingual (about 100 languages)").tag(false)
                Text("English only").tag(true)
            }
            .pickerStyle(.radioGroup)

            Text(englishOnly
                 ? "English only is a little more accurate for English, but cannot transcribe other languages. It is the same size."
                 : "Multilingual handles meetings in other languages, and is only slightly less accurate for English. It is the same size.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Download: \(sizeText(model.archiveBytes)) once, from GitHub. Takes \(sizeText(model.installedBytes)) on this Mac. Your recordings are never uploaded.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Not Now") { prefs.whisperOfferHandled = true }
                Spacer()
                Button("Download \(model.name)") {
                    prefs.whisperModelID = model.id
                    prefs.transcriptionEngineID = "whisper"
                    prefs.whisperOfferHandled = true
                    store.startInstall(model)
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("You can change this any time in Settings → Transcription.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 420)
    }
}
