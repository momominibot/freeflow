import AppKit
import SwiftUI

/// What the floating bar is showing right now.
final class PillModel: ObservableObject {
    enum Kind { case idle, listening, working, message, meeting }
    @Published var kind: Kind = .idle
    @Published var text = ""
    @Published var command = false
    @Published var levels = [CGFloat](repeating: 0, count: 18)
    @Published var level: CGFloat = 0
}

/// The Wispr-style bar at the bottom of the screen: a small plum pill with a face, live bars while you talk,
/// bouncing dots while it works, and a short line when it has something to tell you.
struct PillView: View {
    @ObservedObject var m: PillModel
    static let size = CGSize(width: 560, height: 150)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: m.kind)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: m.text)
    }

    /// How wide a message needs to be, up to 400 points, so a short message gives a short pill.
    private static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont(name: "Manrope-SemiBold", size: 13) ?? NSFont.systemFont(ofSize: 13, weight: .semibold)
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return min(400, ceil(w) + 2)
    }

    private var shell: some View {
        RoundedRectangle(cornerRadius: 21, style: .continuous)
            .fill(LinearGradient(colors: [RT.night, RT.night2], startPoint: .topLeading, endPoint: .bottomTrailing).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.30), radius: 14, y: 6)
    }

    @ViewBuilder
    private var pill: some View {
        switch m.kind {
        case .idle:
            Face(mood: .sleepy, color: RT.pillLilac.opacity(0.9))
                .frame(width: 24)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(
                    Capsule().fill(LinearGradient(colors: [RT.night, RT.night2], startPoint: .leading, endPoint: .trailing).opacity(0.78))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                )
        case .listening:
            HStack(spacing: 11) {
                Face(mood: .talk(m.level), color: RT.cream).frame(width: 36)
                Bars(levels: m.levels).frame(width: 104, height: 22)
                if !m.text.isEmpty {
                    Text(m.text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.lilac2).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(shell)
        case .working:
            HStack(spacing: 11) {
                Face(mood: .smile, color: RT.cream).frame(width: 36)
                Dots()
                if !m.text.isEmpty {
                    Text(m.text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.lilac2).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(shell)
        case .meeting:
            HStack(spacing: 10) {
                Face(mood: .sleepy, color: RT.cream).frame(width: 34)
                PulseDot()
                Text(m.text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.lilac2).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(shell)
        case .message:
            HStack(alignment: .center, spacing: 11) {
                Face(mood: .smile, color: RT.cream).frame(width: 36)
                Text(m.text).font(Fonts.sans(13, .semibold)).foregroundColor(RT.cream)
                    .lineLimit(3).multilineTextAlignment(.leading)
                    .frame(width: Self.textWidth(m.text), alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(shell)
        }
    }
}

/// Rolling bars that follow the microphone, lilac fading to blush.
struct Bars: View {
    let levels: [CGFloat]
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let shade = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [RT.pillLilac, RT.pillBlush]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
            for (i, v) in levels.enumerated() {
                let h = max(3.5, min(size.height, v * size.height))
                let r = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: w / 2), with: shade)
            }
        }
    }
}

/// A soft blush dot that breathes while meeting notes are being taken.
struct PulseDot: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let k = 0.5 + 0.5 * sin(t * 2.4)
            Circle().fill(RT.pillBlush)
                .frame(width: 8, height: 8)
                .opacity(0.55 + 0.45 * k)
                .scaleEffect(0.85 + 0.2 * k)
        }
        .frame(width: 10, height: 10)
    }
}

/// Three dots that bounce one after another while a dictation is being worked on.
struct Dots: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    let phase = sin(t * 5.2 - Double(i) * 0.9)
                    Circle().fill(i == 1 ? RT.pillBlush : RT.pillLilac)
                        .frame(width: 6.5, height: 6.5)
                        .offset(y: CGFloat(-3.2 * max(0, phase)))
                }
            }
            .frame(width: 32, height: 16)
        }
    }
}

/// A panel that can never take keyboard focus, so it cannot pull focus away from the app you are typing in.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bar at the bottom of the screen. Same calls as before; only the look changed.
final class Overlay {
    private let panel: OverlayPanel
    private let model = PillModel()
    private var hideItem: DispatchWorkItem?
    private var shown = false
    private var meetingText: String?

    init() {
        let size = PillView.size
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(m: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.place() }
    }

    /// Shows the small resting bar when it is switched on in Settings.
    func start() {
        if Settings.shared.showIdleBar { rest() }
    }

    func showRecording(hint: String) {
        cancelHide()
        model.levels = [CGFloat](repeating: 0, count: model.levels.count)
        model.level = 0
        model.command = hint.hasPrefix("Command")
        model.text = hint
        model.kind = .listening
        present()
    }

    func setHint(_ text: String) {
        model.text = text
        if model.kind == .idle { model.kind = .listening }
        present()
    }

    func level(_ v: Float) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { [weak self] in self?.level(v) } }
        guard model.kind == .listening else { return }
        let x = CGFloat(v)
        // Rise fast, fall slowly, so the bars and the mouth look calm rather than twitchy.
        let shown = max(x, model.level * 0.72)
        model.level = shown
        var l = model.levels
        l.removeFirst()
        l.append(shown)
        model.levels = l
    }

    func showTranscribing(label text: String = "Transcribing…") {
        cancelHide()
        model.text = text
        model.kind = .working
        present()
    }

    func flash(_ text: String, seconds: Double = 1.8) {
        cancelHide()
        model.text = text
        model.kind = .message
        present()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// True while a timed message is on screen, so callers do not hide it early.
    var isFlashing: Bool { hideItem != nil }

    /// Shows "Meeting notes · 12:41" in the bar while a call is being written down; nil when it is over.
    func setMeeting(_ text: String?) {
        meetingText = text
        guard model.kind == .idle || model.kind == .meeting else { return }
        if let t = text {
            model.text = t
            model.kind = .meeting
            present()
        } else {
            hide()
        }
    }

    func hide() {
        cancelHide()
        if let t = meetingText {
            model.text = t
            model.kind = .meeting
            present()
        } else if Settings.shared.showIdleBar {
            rest()
        } else {
            model.kind = .idle
            panel.orderOut(nil)
            shown = false
        }
    }

    /// Called when the idle-bar switch changes.
    func idleBarChanged() {
        guard model.kind == .idle else { return }
        hide()
    }

    /// For checks and screenshots: put the bar in a given state.
    func preview(_ state: String, text: String = "") {
        cancelHide()
        switch state {
        case "idle": model.kind = .idle
        case "listening":
            model.text = text
            model.kind = .listening
            var wave: [CGFloat] = []
            for i in 0..<18 {
                let a = sin(Double(i) * 0.7)
                let b = cos(Double(i) * 0.27)
                wave.append(CGFloat(0.12 + 0.7 * abs(a * b)))
            }
            model.levels = wave
            model.level = 0.55
        case "working": model.text = text.isEmpty ? "Transcribing…" : text; model.kind = .working
        case "meeting": model.text = text.isEmpty ? "Meeting notes · 12:41" : text; model.kind = .meeting
        default: model.text = text; model.kind = .message
        }
        present()
    }

    private func rest() {
        model.text = ""
        model.kind = .idle
        present()
    }

    private func cancelHide() {
        hideItem?.cancel()
        hideItem = nil
    }

    private func present() {
        place()
        panel.orderFrontRegardless()
        shown = true
    }

    private func place() {
        let size = PillView.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + 6, width: size.width, height: size.height), display: true)
    }
}
