import AppKit

/// Rolling bars that follow the microphone level, with a red recording dot.
final class LevelView: NSView {
    private var levels = [CGFloat](repeating: 0, count: 18)

    func push(_ v: CGFloat) {
        levels.removeFirst()
        levels.append(v)
        needsDisplay = true
    }

    func reset() {
        levels = [CGFloat](repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: (h - 8) / 2, width: 8, height: 8)).fill()
        NSColor.white.withAlphaComponent(0.92).setFill()
        var x: CGFloat = 16
        for v in levels {
            let bh = max(3, min(h, v * h))
            NSBezierPath(roundedRect: NSRect(x: x, y: (h - bh) / 2, width: 3, height: bh), xRadius: 1.5, yRadius: 1.5).fill()
            x += 5.5
        }
    }
}

/// A panel that can never take keyboard focus, so it cannot pull focus away from the app you are typing in.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The small pill at the bottom of the screen while you talk.
final class Overlay {
    private let panel: OverlayPanel
    private let bars = LevelView(frame: NSRect(x: 0, y: 0, width: 115, height: 22))
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var hideItem: DispatchWorkItem?
    private let height: CGFloat = 40

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: height))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.appearance = NSAppearance(named: .vibrantDark)
        box.wantsLayer = true
        box.layer?.cornerRadius = height / 2
        box.layer?.masksToBounds = true
        panel.contentView = box

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.appearance = NSAppearance(named: .vibrantDark)
        [bars, label, spinner].forEach { box.addSubview($0) }
    }

    func showRecording(hint: String) {
        cancelHide()
        bars.reset()
        bars.isHidden = false
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.stringValue = hint
        layoutAndShow()
    }

    func setHint(_ text: String) {
        label.stringValue = text
        layoutAndShow()
    }

    func level(_ v: Float) {
        bars.push(CGFloat(v))
    }

    func showTranscribing(label text: String = "Transcribing…") {
        cancelHide()
        bars.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        label.stringValue = text
        layoutAndShow()
    }

    func flash(_ text: String, seconds: Double = 1.8) {
        cancelHide()
        bars.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        label.stringValue = text
        layoutAndShow()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// True while a timed message is on screen, so callers do not hide it early.
    var isFlashing: Bool { hideItem != nil }

    func hide() {
        cancelHide()
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func cancelHide() {
        hideItem?.cancel()
        hideItem = nil
    }

    private func layoutAndShow() {
        let pad: CGFloat = 16, gap: CGFloat = 10
        var x = pad
        if !bars.isHidden {
            bars.frame.origin = NSPoint(x: x, y: (height - bars.frame.height) / 2)
            x += bars.frame.width + gap
        }
        if !spinner.isHidden {
            spinner.frame = NSRect(x: x, y: (height - 16) / 2, width: 16, height: 16)
            x += 16 + gap
        }
        label.isHidden = label.stringValue.isEmpty
        if !label.isHidden {
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x, y: (height - label.frame.height) / 2)
            x += label.frame.width + gap
        }
        let width = x - gap + pad
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.minY + 24, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }
}
