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
    /// Bumped when the colourway changes so the bar is drawn again with the new colours.
    @Published var look = 0
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
        .id(m.look)
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
            KittyFace(mood: .sleepy).frame(width: 28, height: 24)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(
                    Capsule().fill(LinearGradient(colors: [RT.night, RT.night2], startPoint: .leading, endPoint: .trailing).opacity(0.78))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
                )
        case .listening:
            HStack(spacing: 11) {
                KittyFace(mood: .talk(m.level)).frame(width: 40, height: 34)
                Bars(levels: m.levels).frame(width: 104, height: 22)
                if !m.text.isEmpty {
                    Text(m.text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.lilac2).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(shell)
        case .working:
            HStack(spacing: 11) {
                KittyFace(mood: .smile).frame(width: 40, height: 34)
                Dots()
                if !m.text.isEmpty {
                    Text(m.text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.lilac2).lineLimit(1)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(shell)
        case .meeting:
            HStack(spacing: 10) {
                KittyFace(mood: .sleepy).frame(width: 38, height: 32)
                PulseDot()
                Text(m.text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.lilac2).lineLimit(1)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(shell)
        case .message:
            HStack(alignment: .center, spacing: 11) {
                KittyFace(mood: .smile).frame(width: 40, height: 34)
                Text(m.text).font(Fonts.sans(13, .semibold)).foregroundColor(RT.cream)
                    .lineLimit(3).multilineTextAlignment(.leading)
                    .frame(width: Self.textWidth(m.text), alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(shell)
        }
    }
}

/// The kitten on the floating bar (10 Nov 2026, the owner asked for it cuter than the flat white head): a cream face with soft round ears
/// and pink insides, big eyes with a shine, a pink nose and a little "w" mouth that opens as you talk. Asleep, the eyes are closed curves.
/// No cheek blush (the owner's rule for the cats). Drawn, not a picture, so the mouth can follow the microphone.
struct KittyFace: View {
    enum Mood { case smile, sleepy, talk(CGFloat) }
    var mood: Mood = .smile

    private static let fur = Color(red: 1.0, green: 0.97, blue: 0.93)
    private static let earPink = Color(red: 1.0, green: 0.76, blue: 0.84)
    private static let nose = Color(red: 0.98, green: 0.56, blue: 0.69)
    private static let ink = Color(red: 0.23, green: 0.15, blue: 0.29)

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * y) }
            func ear(_ a: CGPoint, _ tip: CGPoint, _ b: CGPoint) -> Path {
                Path { p in
                    p.move(to: a)
                    p.addQuadCurve(to: tip, control: CGPoint(x: (a.x + tip.x) / 2 - (b.x - a.x) * 0.10, y: (a.y + tip.y) / 2))
                    p.addQuadCurve(to: b, control: CGPoint(x: (tip.x + b.x) / 2, y: (tip.y + b.y) / 2 - h * 0.02))
                    p.closeSubpath()
                }
            }
            // ears, then their pink insides
            ctx.fill(ear(pt(0.08, 0.50), pt(0.15, 0.02), pt(0.46, 0.24)), with: .color(Self.fur))
            ctx.fill(ear(pt(0.92, 0.50), pt(0.85, 0.02), pt(0.54, 0.24)), with: .color(Self.fur))
            ctx.fill(ear(pt(0.17, 0.40), pt(0.19, 0.14), pt(0.38, 0.27)), with: .color(Self.earPink))
            ctx.fill(ear(pt(0.83, 0.40), pt(0.81, 0.14), pt(0.62, 0.27)), with: .color(Self.earPink))
            // the round head, wider than tall
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.02, y: h * 0.18, width: w * 0.96, height: h * 0.80)), with: .color(Self.fur))

            let eyeY: CGFloat = 0.56, eyeX: CGFloat = 0.30, r = min(w, h) * 0.105
            switch mood {
            case .sleepy:
                for x in [eyeX, 1 - eyeX] {
                    var p = Path()
                    p.move(to: CGPoint(x: w * x - r * 1.1, y: h * eyeY))
                    p.addQuadCurve(to: CGPoint(x: w * x + r * 1.1, y: h * eyeY), control: CGPoint(x: w * x, y: h * eyeY + r * 1.4))
                    ctx.stroke(p, with: .color(Self.ink), style: StrokeStyle(lineWidth: max(1.2, r * 0.45), lineCap: .round))
                }
            default:
                for x in [eyeX, 1 - eyeX] {
                    let c = CGPoint(x: w * x, y: h * eyeY)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 1.1, width: r * 2, height: r * 2.2)), with: .color(Self.ink))
                    let s = r * 0.42                                                    // the shine
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.85, width: s * 2, height: s * 2)), with: .color(.white))
                }
            }

            // nose
            let n = pt(0.5, 0.67), nw = w * 0.055
            ctx.fill(Path { p in
                p.move(to: CGPoint(x: n.x - nw, y: n.y - nw * 0.55))
                p.addQuadCurve(to: CGPoint(x: n.x + nw, y: n.y - nw * 0.55), control: CGPoint(x: n.x, y: n.y - nw * 1.0))
                p.addQuadCurve(to: CGPoint(x: n.x, y: n.y + nw * 0.65), control: CGPoint(x: n.x + nw * 0.7, y: n.y + nw * 0.1))
                p.addQuadCurve(to: CGPoint(x: n.x - nw, y: n.y - nw * 0.55), control: CGPoint(x: n.x - nw * 0.7, y: n.y + nw * 0.1))
            }, with: .color(Self.nose))

            // the "w" mouth; talking opens a small pink mouth under it
            let line = max(1.1, min(w, h) * 0.05)
            let mw = w * 0.085, my = n.y + nw * 0.65
            var mouth = Path()
            mouth.move(to: CGPoint(x: n.x - mw * 2, y: my + h * 0.015))
            mouth.addQuadCurve(to: CGPoint(x: n.x, y: my), control: CGPoint(x: n.x - mw, y: my + h * 0.10))
            mouth.addQuadCurve(to: CGPoint(x: n.x + mw * 2, y: my + h * 0.015), control: CGPoint(x: n.x + mw, y: my + h * 0.10))
            if case .talk(let level) = mood, level > 0.04 {
                let open = min(1, level) * h * 0.16 + h * 0.03
                ctx.fill(Path(ellipseIn: CGRect(x: n.x - mw * 0.9, y: my + h * 0.03, width: mw * 1.8, height: open)), with: .color(Self.nose))
            }
            ctx.stroke(mouth, with: .color(Self.ink), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))

            // a whisker each side, faint
            for side in [-1.0, 1.0] as [CGFloat] {
                var p = Path()
                p.move(to: CGPoint(x: n.x + side * w * 0.20, y: n.y + h * 0.02))
                p.addLine(to: CGPoint(x: n.x + side * w * 0.40, y: n.y - h * 0.02))
                ctx.stroke(p, with: .color(Self.ink.opacity(0.28)), style: StrokeStyle(lineWidth: max(0.8, line * 0.7), lineCap: .round))
            }
        }
        .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
        .accessibilityHidden(true)
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
        NotificationCenter.default.addObserver(forName: .freeflowLookChanged, object: nil, queue: .main) { [weak self] _ in self?.model.look += 1 }
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
