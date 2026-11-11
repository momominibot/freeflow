import AppKit
import SwiftUI

/// The cats' strip above the Studio window (10 Nov 2026): outside the app, on the desktop, sitting on the window's top edge. A
/// transparent window with nothing in it but the cats and their toys (CatRunner.swift), attached to the Studio window as a child so it
/// moves with it and stays in front of it and behind everything that is in front of it. It follows the window as it is moved or resized,
/// goes when the window is minimised, full screen or closed, and is not shown when there are fewer than `least` points between the top of
/// the window and the top of the screen (then the cats walk along the top bar inside the window instead: `onPerched` tells the window).
///
/// A transparent window would catch every click on its whole area, so the cats' strip lets clicks through everywhere except where
/// something is (the cats, the ball, the wand, the bowl, a biscuit, a pile): a timer looks at where the pointer is and switches
/// `ignoresMouseEvents` to match, and while you are holding something the whole strip is yours.
final class CatPerch: NSObject {
    static let want: CGFloat = 116          // how tall the strip is when there is room
    static let least: CGFloat = 60          // and the least room above the window for it to be shown at all
    static let sideInset: CGFloat = 16      // the window's top corners are round: the cats keep to the flat part

    let state = CatRunnerState.shared          // the same one the toy box in the window throws things onto
    var onPerched: ((Bool) -> Void)?
    private(set) var perched = false
    private weak var window: NSWindow?
    private let panel: PerchPanel
    private var host: PerchHostingView?
    private var scale: CGFloat = 1              // how much bigger than the usual the cats are drawn now (Settings > Cat size)
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?

    init(window: NSWindow) {
        self.window = window
        panel = PerchPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.want),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        scale = Settings.shared.catSize.scale
        let host = PerchHostingView(rootView: CatRunner(state: state, floorInset: 1, scale: scale))
        host.sizingOptions = []
        panel.contentView = host
        self.host = host

        let nc = NotificationCenter.default
        let names: [NSNotification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                                            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                                            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                            NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification]
        for n in names {
            observers.append(nc.addObserver(forName: n, object: window, queue: .main) { [weak self] _ in self?.layout() })
        }
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() })
        observers.append(nc.addObserver(forName: .freeflowLookChanged, object: nil, queue: .main) { [weak self] _ in self?.layout() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o); NSWorkspace.shared.notificationCenter.removeObserver(o) }
        poll?.invalidate()
    }

    /// Where the strip goes for a window frame on a screen's usable area, or nil when there is not enough room above the window.
    static func frame(window f: NSRect, usable vf: NSRect) -> NSRect? {
        let room = vf.maxY - f.maxY
        guard room >= least else { return nil }
        let h = min(want, room)
        return NSRect(x: f.minX + sideInset, y: f.maxY - 1, width: max(120, f.width - 2 * sideInset), height: h + 1)       // 1 point of overlap: the paws stand on the edge
    }

    /// Shows, moves or hides the strip to match the window and the settings.
    func layout() {
        guard let w = window else { return hide() }
        let s = Settings.shared
        // a new Cat size in Settings: the same strip, drawn bigger or smaller (the strip's own window keeps its size, so nothing moves)
        let k = s.catSize.scale
        if k != scale, let h = host { scale = k; h.rootView = CatRunner(state: state, floorInset: 1, scale: k) }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard s.catTheme, s.catRunner, !reduce, w.isVisible, !w.isMiniaturized, !w.styleMask.contains(.fullScreen),
              w.occlusionState.contains(.visible), let screen = w.screen ?? NSScreen.main,
              let f = Self.frame(window: w.frame, usable: screen.visibleFrame) else { return hide() }
        if panel.frame != f { panel.setFrame(f, display: true) }
        if panel.parent == nil { w.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        startPolling()
        setPerched(true)
    }

    func hide() {
        poll?.invalidate(); poll = nil
        if let p = panel.parent { p.removeChildWindow(panel) }
        panel.orderOut(nil)
        setPerched(false)
    }

    private func setPerched(_ on: Bool) {
        guard on != perched else { return }
        perched = on
        onPerched?(on)
    }

    /// The pointer is over something: take the click. Anywhere else: let it through to whatever is under the strip.
    private func startPolling() {
        guard poll == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.follow() }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func follow() {
        guard panel.isVisible, let content = panel.contentView else { return }
        // while a button is down on something that is held, the drag must keep coming even when the pointer leaves the strip
        if state.held != .none && NSEvent.pressedMouseButtons != 0 { panel.ignoresMouseEvents = false; return }
        let p = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let k = max(state.scale, 0.1)          // the cats are played in smaller or bigger points than the screen's: the pointer must be in theirs
        let inView = CGPoint(x: p.x / k, y: (content.bounds.height - p.y) / k)
        let hot = state.hotRects().contains { $0.contains(inView) }
        if panel.ignoresMouseEvents == hot { panel.ignoresMouseEvents = !hot }
    }
}

/// A window that never becomes key or main (the Studio window stays the one you are working in) and may sit anywhere on the screen.
private final class PerchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The first click on the strip is a click on a toy, not just a click that brings the window forward.
private final class PerchHostingView: NSHostingView<CatRunner> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
