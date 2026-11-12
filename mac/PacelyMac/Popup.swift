import SwiftUI
import AppKit

enum PopupKind: String {
    case before, start, end, focusEnd, test
}

struct PopupInfo {
    let kind: PopupKind
    let heading: String
    let title: String
    let detail: String
    let emoji: String
    let color: String
    let plan: Planned?
    let next: Planned?
}

/// A calm floating card in the top-right corner. It never steals your keyboard focus.
@MainActor
final class PopupController {
    static let shared = PopupController()
    private var panel: NSPanel?

    func show(_ info: PopupInfo) {
        close()
        let view = PopupView(info: info) { [weak self] in self?.close() }
        let host = NSHostingView(rootView: view)
        let size = NSSize(width: 380, height: 210)
        host.frame = NSRect(origin: .zero, size: size)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = host
        let fitted = host.fittingSize
        if fitted.height > 50 { p.setContentSize(NSSize(width: size.width, height: fitted.height)) }

        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width - 16, y: vf.maxY - p.frame.height - 16))
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 1
        }
        panel = p
        if Store.sound { NSSound(named: NSSound.Name("Glass"))?.play() }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PopupView: View {
    let info: PopupInfo
    let close: () -> Void
    @ObservedObject private var model = MacModel.shared

    private var tint: Color { Color(hex: info.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(info.emoji)
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
                    .background(tint, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.heading.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.secondary)
                    Text(info.title)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(2)
                    Text(info.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
            HStack(spacing: 8) {
                buttons
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var buttons: some View {
        switch info.kind {
        case .start:
            if let p = info.plan {
                Button("Start focus") { model.startFocus(p); close() }
                    .buttonStyle(.borderedProminent).tint(tint)
                Button("Snooze 5 min") { model.snooze(info); close() }
                if p.canTick {
                    Button("Done ✓") { Task { await model.markDone(p) }; close() }
                }
            }
        case .before:
            Button("OK") { close() }.buttonStyle(.borderedProminent).tint(tint)
            Button("Snooze 5 min") { model.snooze(info); close() }
        case .end:
            if let p = info.plan, p.canTick {
                Button("Done ✓") { Task { await model.markDone(p) }; close() }
                    .buttonStyle(.borderedProminent).tint(tint)
            }
            Button("I need 10 more min") { Task { await model.shift(minutes: 10) }; close() }
            Button("OK") { close() }
        case .focusEnd, .test:
            Button("OK") { close() }.buttonStyle(.borderedProminent).tint(tint)
        }
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        if !(s.count == 6 && Scanner(string: s).scanHexInt64(&v)) { v = 0x7CB8F0 }
        self.init(red: Double((v >> 16) & 0xFF) / 255.0, green: Double((v >> 8) & 0xFF) / 255.0, blue: Double(v & 0xFF) / 255.0)
    }
}
