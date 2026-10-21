import SwiftUI

struct LevelMeter: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(height: 8)
        }
    }
}

struct PermissionRow: View {
    let ok: Bool
    let label: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !ok {
                Button("Enable", action: action)
                    .font(.caption)
            }
        }
    }
}

struct ToastBanner: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
            .padding(.top, 8)
    }
}

func formatElapsed(_ t: TimeInterval) -> String {
    let s = Int(t)
    let hh = s / 3600
    let mm = (s % 3600) / 60
    let ss = s % 60
    return String(format: "%02d:%02d:%02d", hh, mm, ss)
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatBytes(_ n: Int64) -> String {
    let mb = Double(n) / (1024 * 1024)
    if mb < 1 { return String(format: "%.0f KB", Double(n) / 1024) }
    return String(format: "%.1f MB", mb)
}
