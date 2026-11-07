import AppKit
import AVFoundation
import ApplicationServices

/// Watches one held key. Needs Accessibility permission to see keys pressed in other apps.
final class HotkeyMonitor {
    var key: TalkKey = .rightOption { didSet { isDown = false } }
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onKeyDown: ((UInt16) -> Void)?
    /// Shift tapped while the key is held: lock into hands-free mode.
    var onLock: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    func install() {
        remove()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            self?.handle(e)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            self?.handle(e)
            return e
        }) { monitors.append(l) }
    }

    func remove() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown { onKeyDown?(e.keyCode); return }
        if isDown, e.keyCode == 56 || e.keyCode == 60, e.modifierFlags.contains(.shift) {
            onLock?()
            return
        }
        guard e.keyCode == key.keyCode else { return }
        let down = (e.modifierFlags.rawValue & key.deviceMask) != 0
        if down, !isDown {
            isDown = true
            onDown?()
        } else if !down, isDown {
            isDown = false
            onUp?()
        }
    }
}

/// Records 16 kHz mono WAV, the format whisper.cpp wants, and reports a live level.
final class Recorder {
    struct Take {
        let url: URL
        let duration: TimeInterval
        let peakDb: Float
    }

    private final class Session {
        let recorder: AVAudioRecorder
        var timer: Timer?
        var peak: Float = -160
        let started = Date()
        init(_ r: AVAudioRecorder) { recorder = r }
    }

    var onLevel: ((Float) -> Void)?
    private var current: Session?

    func start() -> Bool {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FreeFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        r.isMeteringEnabled = true
        guard r.record() else { return false }
        let s = Session(r)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self, weak s] _ in
            guard let s = s else { return }
            self?.meter(s)
        }
        RunLoop.main.add(t, forMode: .common)
        s.timer = t
        current = s
        return true
    }

    /// Keeps recording for `tail` seconds so the last word is not clipped, then hands back the file.
    func stop(tail: TimeInterval, completion: @escaping (Take) -> Void) {
        guard let s = current else { return }
        current = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + tail) {
            self.meter(s, report: false)
            let duration = Date().timeIntervalSince(s.started)
            s.timer?.invalidate()
            s.recorder.stop()
            completion(Take(url: s.recorder.url, duration: duration, peakDb: s.peak))
        }
    }

    func cancel() {
        guard let s = current else { return }
        current = nil
        s.timer?.invalidate()
        s.recorder.stop()
        try? FileManager.default.removeItem(at: s.recorder.url)
    }

    private func meter(_ s: Session, report: Bool = true) {
        s.recorder.updateMeters()
        s.peak = max(s.peak, s.recorder.peakPower(forChannel: 0))
        guard report else { return }
        let avg = s.recorder.averagePower(forChannel: 0)
        onLevel?(max(0, min(1, (avg + 55) / 45)))
    }
}

/// Puts text into whatever app has focus, then gives the user's clipboard back.
enum Inserter {
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Pastes, then gives the clipboard back and calls `completion`. Callers run one paste at a time.
    static func paste(_ text: String, completion: @escaping () -> Void = {}) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: transient)
        let mine = pb.changeCount
        postShortcut(key: 9) // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if pb.changeCount == mine {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
            completion()
        }
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Presses Return, for "press enter" at the end of a dictation.
    static func pressReturn() {
        let src = CGEventSource(stateID: .combinedSessionState)
        DispatchQueue.global(qos: .userInteractive).async {
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
            usleep(15_000)
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    /// What the user has selected and what is around the cursor, for Command Mode.
    /// Reads through Accessibility first; when the app does not expose its selection, copies it with ⌘C and restores the clipboard.
    struct Focus {
        var selection = ""
        var context = ""
        var editable = false
    }

    static func readFocus(completion: @escaping (Focus) -> Void) {
        var f = Focus()
        if let el = focusedElement() {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            // A web page is AXWebArea too, but only an editable field should receive a paste.
            f.editable = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) || isSettable(el)
            var sel: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success, let s = sel as? String {
                f.selection = s
            }
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &val) == .success, let v = val as? String {
                f.context = String(v.suffix(6000))
            }
        }
        if !f.selection.isEmpty { return completion(f) }
        // Fall back to ⌘C: many Electron and browser fields do not expose AXSelectedText.
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        postShortcut(key: 8) // ⌘C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if pb.changeCount != before, let s = pb.string(forType: .string), !s.isEmpty {
                f.selection = s
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
            completion(f)
        }
    }

    /// True when the character before the cursor is not whitespace, so a space is needed.
    static func needsLeadingSpace() -> Bool {
        guard let el = focusedElement() else { return false }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return false }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range), range.location > 0 else { return false }

        var before: String?
        var r = CFRange(location: range.location - 1, length: 1)
        if let param = AXValueCreate(.cfRange, &r) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString,
                                                          param, &out) == .success {
                before = out as? String
            }
        }
        if before == nil {
            var valueRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
               let value = valueRef as? String {
                let ns = value as NSString
                if range.location <= ns.length {
                    before = ns.substring(with: NSRange(location: range.location - 1, length: 1))
                }
            }
        }
        guard let c = before?.last else { return false }
        return !c.isWhitespace && !"([{\"'“‘/-".contains(c)
    }

    // MARK: - Internals

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.15)
        return el
    }

    private static func isSettable(_ el: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    /// Sends ⌘+key the way a real keyboard does. On current macOS a lone "key with Command flag" event is
    /// ignored by many apps; pressing Command itself first, then the key, then releasing both, is not.
    private static func postShortcut(key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let leftCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        func send(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.global(qos: .userInteractive).async {
            send(55, down: true, flags: leftCommand)
            usleep(15_000)
            send(key, down: true, flags: leftCommand)
            usleep(15_000)
            send(key, down: false, flags: leftCommand)
            usleep(15_000)
            send(55, down: false, flags: [])
        }
    }
}
