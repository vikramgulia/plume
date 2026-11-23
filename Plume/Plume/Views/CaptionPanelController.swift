import SwiftUI
import AppKit

/// The floating live-captions window: a dark strip at the bottom centre of the screen that stays
/// above other apps (including full-screen ones) and can be dragged anywhere.
@MainActor
final class CaptionPanelController {
    static let shared = CaptionPanelController()
    private var panel: NSPanel?

    func show(service: LiveCaptionService) {
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
            panel.contentView = NSHostingView(rootView: CaptionPanelView(service: service, onClose: { [weak self] in self?.hide() }))
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

struct CaptionPanelView: View {
    @ObservedObject var service: LiveCaptionService
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Live captions", systemImage: "captions.bubble")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(service.log.plainText, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy captions")
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide captions (recording continues)")
            }
            .foregroundStyle(.white.opacity(0.7))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if service.log.lines.isEmpty {
                            Text("Listening…").foregroundStyle(.white.opacity(0.5))
                        }
                        ForEach(service.log.lines) { line in
                            (Text(line.source.label + "  ")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(line.source == .you ? Color.cyan : Color.orange)
                             + Text(line.text)
                                .foregroundStyle(line.isFinal ? Color.white : Color.white.opacity(0.55)))
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: service.log) { _ in
                    if let last = service.log.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .font(.title3)
        }
        .padding(12)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
    }
}
