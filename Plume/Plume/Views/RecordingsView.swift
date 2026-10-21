import SwiftUI
import AVFoundation
import Combine
import AppKit

struct RecordingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recordings")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 8)

            if app.library.recordings.isEmpty {
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
            } else {
                List {
                    ForEach(app.library.recordings) { rec in
                        RecordingRowView(item: rec)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .task { await app.library.reload() }
    }
}

struct RecordingRowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var speakers = SpeakerLibrary.shared
    let item: RecordingItem
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
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
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
        _ = try? app.library.rename(item, to: name)
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
