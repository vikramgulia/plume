import SwiftUI
import AppKit

/// The floating live-captions window: a dark strip at the bottom centre of the screen that stays
/// above other apps (including full-screen ones) and can be dragged anywhere.
@MainActor
final class CaptionPanelController {
    static let shared = CaptionPanelController()
    private var panel: NSPanel?

    func show(service: LiveCaptionService, onOpenApp: @escaping () -> Void) {
        if panel == nil {
            let size = NSSize(width: 680, height: 150)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.minSize = NSSize(width: 360, height: 90)
            panel.contentView = NSHostingView(rootView: CaptionPanelView(service: service, onOpenApp: onOpenApp, onClose: { [weak self] in self?.hide() }))
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 60))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }
}

/// The caption lines, newest at the bottom. `maxLines` limits how many are shown.
struct CaptionLinesView: View {
    let lines: [CaptionLine]
    var maxLines: Int? = nil
    var onDark = true

    private var shown: [CaptionLine] {
        guard let maxLines else { return lines }
        return Array(lines.suffix(maxLines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if lines.isEmpty {
                Text("Listening…").foregroundStyle(onDark ? Color.white.opacity(0.5) : Color.secondary)
            }
            ForEach(shown) { line in
                (Text(line.source.label + "  ")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(line.source == .you ? Color.cyan : Color.orange)
                 + Text(line.text)
                    .foregroundStyle(line.isFinal ? (onDark ? Color.white : Color.primary)
                                                  : (onDark ? Color.white.opacity(0.55) : Color.secondary)))
                    .id(line.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CaptionPanelView: View {
    @ObservedObject var service: LiveCaptionService
    var onOpenApp: () -> Void
    var onClose: () -> Void
    @State private var appIsActive = NSApp.isActive

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Live captions", systemImage: "captions.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                // Only useful when another app is in front.
                if !appIsActive {
                    Button(action: onOpenApp) {
                        Label("Open Plume", systemImage: "arrow.up.forward.app")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Go to the recording screen")
                }
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide captions (recording continues)")
            }
            .foregroundStyle(.white.opacity(0.7))

            ScrollViewReader { proxy in
                ScrollView {
                    CaptionLinesView(lines: service.log.lines)
                }
                .onChange(of: service.log) { _ in
                    if let last = service.log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .font(.title3)
        }
        .padding(12)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appIsActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appIsActive = false }
    }
}
