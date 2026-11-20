import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Plume")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(app.recording.state == .recording
                     ? (app.recording.mode == .voiceNote ? "● Voice note" : "● Recording")
                     : "Idle")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(app.recording.state == .recording
                                       ? Color.red.opacity(0.2)
                                       : Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(app.recording.state == .recording ? .red : .secondary)
            }

            if let err = app.recording.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            Button {
                Task {
                    if app.recording.state == .recording {
                        await app.stopRecording()
                    } else {
                        await app.startRecording()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 112, height: 112)
                        .shadow(color: .red.opacity(0.4), radius: 12)
                    Image(systemName: app.recording.state == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            if app.recording.state == .recording {
                Text(formatElapsed(app.recording.elapsed))
                    .font(.system(.title2, design: .monospaced))
                    .padding(.top, 8)
            } else {
                Button {
                    Task { await app.startVoiceNote() }
                } label: {
                    Label("Record voice note", systemImage: "mic")
                }
                .buttonStyle(.bordered)
                .disabled(app.recording.state != .idle)
                .help("Record only your microphone. No Screen Recording permission needed.")
            }

            Spacer()

            VStack(spacing: 10) {
                if app.recording.mode != .voiceNote || app.recording.state == .idle {
                    LevelMeter(label: "System", level: app.recording.systemLevel)
                }
                LevelMeter(label: "Mic", level: app.recording.micLevel)
            }

            VStack(spacing: 6) {
                PermissionRow(
                    ok: app.permissions.screenStatus == .granted,
                    label: "Screen Recording",
                    action: { app.permissions.openScreenRecordingSettings() }
                )
                PermissionRow(
                    ok: app.permissions.micGranted,
                    label: "Microphone",
                    action: { Task { await app.permissions.requestMicrophoneOrOpenSettings() } }
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .padding(.top, 8)
        .task { await app.permissions.refresh() }
        // Pick up a change made in System Settings as soon as the user comes back to Plume.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await app.permissions.refresh() }
        }
    }
}
