import SwiftUI
import AppKit

@MainActor
final class PillController {
    static let shared = PillController()

    private var panel: NSPanel?
    private var hosting: NSHostingView<PillView>?
    private var model = PillModel()

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hide()
        }
    }

    func setElapsed(_ t: TimeInterval) {
        model.elapsed = t
    }

    private func show() {
        if panel == nil {
            let view = PillView(model: model)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 180, height: 40)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hosting
            panel.isMovableByWindowBackground = true
            if let saved = PreferencesStore.shared.pillPosition {
                panel.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
            } else if let screen = NSScreen.main {
                let x = screen.visibleFrame.midX - 90
                let y = screen.visibleFrame.maxY - 80
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            self.panel = panel
            self.hosting = hosting
        }
        panel?.orderFrontRegardless()
    }

    private func hide() {
        if let panel {
            PreferencesStore.shared.pillPosition = CGPoint(x: panel.frame.origin.x, y: panel.frame.origin.y)
        }
        panel?.orderOut(nil)
    }
}

final class PillModel: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

struct PillView: View {
    @ObservedObject var model: PillModel
    var onStop: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
            Text(formatElapsed(model.elapsed))
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.white)
            Button {
                NotificationCenter.default.post(name: .plumeStopRecording, object: nil)
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }
}

extension Notification.Name {
    static let plumeStopRecording = Notification.Name("plumeStopRecording")
    static let plumeStartRecording = Notification.Name("plumeStartRecording")
}
