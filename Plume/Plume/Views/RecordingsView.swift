import SwiftUI
import AVFoundation
import Combine
import AppKit

struct RecordingsView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var sort: RecordingSort = .newest
    @State private var selection: String?

    /// Below this width the compact card list is used; wider windows get list and detail side by side.
    private static let wideThreshold: CGFloat = 760

    private var visible: [RecordingItem] {
        sort.sorted(RecordingSort.filter(app.library.recordings, query: query))
    }

    private var selected: RecordingItem? {
        visible.first { $0.id == selection }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                header
                if app.library.recordings.isEmpty {
                    emptyState
                } else if visible.isEmpty {
                    Text("No recordings match \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if geo.size.width >= Self.wideThreshold {
                    wideLayout
                } else {
                    compactList
                }
            }
        }
        .task { await app.library.reload() }
        .onAppear { applyHighlight(); ensureSelection() }
        .onChange(of: visible.map(\.id)) { _ in ensureSelection() }
        .onChange(of: app.highlightRecordingPath) { _ in applyHighlight() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Recordings")
                .font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 200)
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(RecordingSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort recordings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "folder")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No recordings yet.")
                .foregroundStyle(.secondary)
            Text("Hit record to start.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var compactList: some View {
        List {
            ForEach(visible) { rec in
                RecordingRowView(item: rec)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(visible) { rec in
                    RecordingListRow(item: rec).tag(rec.id)
                }
            }
            .listStyle(.inset)
            .frame(width: 300)

            Divider()

            if let selected {
                RecordingRowView(item: selected, expanded: true) { renamed in
                    selection = renamed.id
                }
                .id(selected.id)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                Text("Select a recording")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Open the recording picked from the menu bar's Recent Recordings.
    private func applyHighlight() {
        if let path = app.highlightRecordingPath, visible.contains(where: { $0.id == path }) {
            selection = path
        }
    }

    /// Keep something selected: the first recording when the selection is gone (deleted, filtered out).
    private func ensureSelection() {
        if selected == nil { selection = visible.first?.id }
    }
}

/// One line in the wide layout's list.
struct RecordingListRow: View {
    let item: RecordingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.filename.hasPrefix("Voice note") ? "mic.fill" : "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(item.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(formatDuration(item.duration))
                if item.hasTranscript {
                    Image(systemName: "text.alignleft")
                        .help("Has a transcript")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
        }
        .padding(.vertical, 2)
    }
}

struct RecordingRowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var speakers = SpeakerLibrary.shared
    let item: RecordingItem
    /// The wide layout's detail pane: the transcript grows to fill the available height.
    var expanded = false
    var onRenamed: ((RecordingItem) -> Void)?
    @State private var renaming = false
    @State private var name = ""
    @State private var transcriptOpen = false
    @State private var transcriptText = ""
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playing = false
    @State private var playFailed = false
    @State private var progressTick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if renaming {
                    TextField("Name", text: $name, onCommit: commitRename)
                    Button("Save") { commitRename() }
                    Button("Cancel") { renaming = false }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("·")
                            Text(formatDuration(item.duration))
                            Text("·")
                            Text(formatBytes(item.size))
                            if item.hasTranscript {
                                Text("· transcript")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Open in Finder") { app.library.revealInFinder(item.fileURL) }
                        Button(item.hasTranscript ? "Re-transcribe" : "Transcribe") {
                            app.transcription.start(item.fileURL)
                        }
                        if item.hasTranscript {
                            Button("Reload transcript") { loadTranscript() }
                        }
                        Button("Rename") {
                            name = item.fileURL.deletingPathExtension().lastPathComponent
                            renaming = true
                        }
                        Divider()
                        Button("Delete…", role: .destructive) {
                            try? app.library.delete(item)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                }
            }

            if let player = audioPlayer {
                HStack(spacing: 8) {
                    Button {
                        if player.isPlaying {
                            player.pause()
                            playing = false
                        } else {
                            player.play()
                            playing = true
                        }
                    } label: {
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    Slider(
                        value: Binding(
                            get: { _ = progressTick; return player.currentTime },
                            set: { player.currentTime = $0 }
                        ),
                        in: 0...max(player.duration, 0.1)
                    )
                    Text(formatDuration(max(player.duration - player.currentTime, 0)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
                    progressTick += 1
                    if playing, !player.isPlaying { playing = false }
                }
            } else if playFailed {
                Text("Can't play this file — it may be incomplete or unsupported.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Button("Play") {
                    do {
                        let p = try AVAudioPlayer(contentsOf: item.fileURL)
                        p.prepareToPlay()
                        p.play()
                        audioPlayer = p
                        playing = true
                        playFailed = false
                    } catch {
                        playFailed = true
                    }
                }
                .font(.caption)
            }

            let job = app.transcription.status(for: item.fileURL)
            if job.status == .queued || job.status == .installingLocale || job.status == .transcribing || job.status == .diarizing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    if job.status == .installingLocale {
                        Text("Preparing language…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if job.status == .diarizing {
                        Text("Identifying speakers…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if job.progress >= 0 {
                        Text("Transcribing… \(Int(job.progress))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: job.progress, total: 100)
                    } else {
                        Text("Transcribing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if job.status == .error, let err = job.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            if transcriptOpen {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Transcript").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(transcriptText, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        if let t = item.transcriptURL {
                            Button { app.library.revealInFinder(t) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless)
                        }
                        Button { transcriptOpen = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                    ScrollView {
                        Text(transcriptText)
                            .font(expanded ? .callout : .caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: expanded ? 200 : nil, maxHeight: expanded ? CGFloat.infinity : 120)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxHeight: expanded ? CGFloat.infinity : nil, alignment: .top)
        .onReceive(app.transcription.$jobs) { jobs in
            if jobs[item.fileURL.path]?.status == .complete, !transcriptOpen {
                loadTranscript()
            }
        }
        .onReceive(speakers.objectWillChange) { _ in
            if transcriptOpen {
                refreshTranscriptDisplay()
            }
        }
        .task {
            if item.hasTranscript, !transcriptOpen {
                loadTranscript()
            }
        }
    }

    private func commitRename() {
        if let updated = try? app.library.rename(item, to: name) {
            onRenamed?(updated)
        }
        renaming = false
    }

    /// Load transcript text. Prefer the JSON sidecar because it carries speakerIds,
    /// so we can re-render with current SpeakerLibrary names (renames reflect live).
    private func loadTranscript() {
        if let text = liveTranscriptText() ?? app.library.readTranscript(for: item) {
            transcriptText = text
            transcriptOpen = true
        } else if let job = app.transcription.jobs[item.fileURL.path], let url = job.transcriptURL,
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            transcriptText = text
            transcriptOpen = true
        }
        Task { await app.library.reload() }
    }

    private func refreshTranscriptDisplay() {
        if let text = liveTranscriptText() ?? app.library.readTranscript(for: item) {
            transcriptText = text
        }
    }

    private func liveTranscriptText() -> String? {
        let jsonURL = PathGuard.sidecarURL(for: item.fileURL, ext: "json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              let doc = try? JSONDecoder().decode(TranscriptDocument.self, from: data) else {
            return nil
        }
        let profiles = SpeakerLibrary.shared.profiles()
        let segments = doc.segments.map { seg -> LabeledSegment in
            if let sid = seg.speakerId, let uuid = UUID(uuidString: sid),
               let profile = profiles.first(where: { $0.id == uuid }) {
                return LabeledSegment(start: seg.start, end: seg.end, speakerId: seg.speakerId, speaker: profile.name, text: seg.text)
            }
            return seg
        }
        return TranscriptionService.renderLabeledText(segments)
    }
}
