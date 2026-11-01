import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let server = WhisperServer()
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private let overlay = Overlay()
    private var statusItem: NSStatusItem!

    private var isRecording = false
    private var handsFree = false
    private var recordStart = Date()
    private var consumeNextUp = false
    private var maxLengthItem: DispatchWorkItem?

    // Results are pasted in the order they were spoken, even if two are transcribing at once.
    private var nextId = 0
    private var nextToDeliver = 0
    private var finished: [Int: String] = [:]
    private var inFlight = 0
    private var lastTranscript = ""
    private var axTimer: Timer?

    private static let tapThreshold: TimeInterval = 0.3
    private static let maxLength: TimeInterval = 6 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        Vocabulary.ensureFile()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        hotkey.key = settings.talkKey
        hotkey.onDown = { [weak self] in self?.talkDown() }
        hotkey.onUp = { [weak self] in self?.talkUp() }
        hotkey.onKeyDown = { [weak self] code in self?.otherKey(code) }
        hotkey.onLock = { [weak self] in self?.lockHandsFree() }
        hotkey.install()

        recorder.onLevel = { [weak self] level in self?.overlay.level(level) }
        server.onStateChange = { [weak self] in self?.refreshIcon() }
        server.start()

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.momominibot.freeflow.debug"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, self.settings.debugTriggers else { return }
            switch note.object as? String {
            case "down": self.talkDown()
            case "up": self.talkUp()
            case "lock": self.lockHandsFree()
            default: break
            }
        }

        askForPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    // MARK: - Talk key

    private func talkDown() {
        if isRecording, handsFree {
            consumeNextUp = true
            finishRecording()
            return
        }
        guard !isRecording else { return }
        startRecording(handsFree: false)
    }

    /// Shift tapped while holding the talk key. Releasing the talk key then keeps recording;
    /// tapping the talk key again finishes. (Double-tapping Option is avoided on purpose:
    /// the Claude desktop app uses it for Quick Entry.)
    private func lockHandsFree() {
        guard isRecording, !handsFree else { return }
        handsFree = true
        consumeNextUp = true
        overlay.setHint("Hands-free · tap \(settings.talkKey.short) to finish")
        play("Tink")
    }

    private func talkUp() {
        if consumeNextUp {
            consumeNextUp = false
            return
        }
        guard isRecording, !handsFree else { return }
        if Date().timeIntervalSince(recordStart) < Self.tapThreshold {
            cancelRecording()
            return
        }
        finishRecording()
    }

    private func otherKey(_ code: UInt16) {
        guard isRecording else { return }
        if code == 53 {
            cancelRecording()
            overlay.flash("Cancelled", seconds: 1)
        } else if !handsFree {
            // The talk key was being used as part of a shortcut, not to dictate.
            cancelRecording()
        }
    }

    // MARK: - Recording

    private func startRecording(handsFree: Bool) {
        if let error = server.lastError {
            overlay.flash(error, seconds: 3)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            overlay.flash("Microphone is blocked · allow it from the menu bar icon", seconds: 3)
            return
        }
        guard recorder.start() else {
            overlay.flash("Microphone didn't start", seconds: 2)
            return
        }
        isRecording = true
        self.handsFree = handsFree
        recordStart = Date()
        overlay.showRecording(hint: handsFree ? "Hands-free · tap \(settings.talkKey.short) to finish" : "")
        refreshIcon()

        if handsFree {
            play("Tink")
        } else {
            let started = recordStart
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapThreshold) { [weak self] in
                guard let self = self, self.isRecording, self.recordStart == started else { return }
                self.play("Tink")
            }
        }
        let limit = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.finishRecording()
        }
        maxLengthItem = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxLength, execute: limit)
    }

    private func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        handsFree = false
        maxLengthItem?.cancel()
        recorder.cancel()
        if inFlight == 0 { overlay.hide() } else { overlay.showTranscribing() }
        refreshIcon()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        handsFree = false
        maxLengthItem?.cancel()
        play("Pop")
        let id = nextId
        nextId += 1
        inFlight += 1
        overlay.showTranscribing()
        refreshIcon()

        recorder.stop(tail: 0.15) { [weak self] take in
            guard let self = self else { return }
            if take.duration < 0.35 {
                return self.done(id, text: "", file: take.url)
            }
            if take.peakDb < -50 {
                self.overlay.flash("Didn't hear anything · check your mic", seconds: 2)
                return self.done(id, text: "", file: take.url, keepOverlay: true)
            }
            let vocab = Vocabulary.load()
            let removeFillers = self.settings.removeFillers
            self.server.transcribe(take.url, language: self.settings.language.rawValue, prompt: vocab.prompt) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let raw):
                        let text = TextCleaner.clean(raw, removeFillers: removeFillers, vocab: vocab, quiet: take.peakDb < -30)
                        self.done(id, text: text, file: take.url)
                    case .failure(let error):
                        self.log("transcription failed: \(error.localizedDescription)")
                        self.overlay.flash("Couldn't transcribe · \(error.localizedDescription)", seconds: 3)
                        self.done(id, text: "", file: take.url, keepOverlay: true)
                    }
                }
            }
        }
    }

    private func done(_ id: Int, text: String, file: URL, keepOverlay: Bool = false) {
        try? FileManager.default.removeItem(at: file)
        inFlight -= 1
        finished[id] = text
        var delivered = false
        var copiedOnly = false
        while let next = finished.removeValue(forKey: nextToDeliver) {
            nextToDeliver += 1
            guard !next.isEmpty else { continue }
            copiedOnly = !deliver(next)
            delivered = true
        }
        if copiedOnly {
            overlay.flash("Copied · press ⌘V to paste (allow Accessibility to type automatically)", seconds: 3)
        } else if !isRecording, inFlight == 0, !keepOverlay {
            overlay.hide()
        }
        if delivered || inFlight == 0 { refreshIcon() }
    }

    /// Returns false when the text could only be copied to the clipboard.
    private func deliver(_ text: String) -> Bool {
        lastTranscript = text
        settings.addWords(TextCleaner.wordCount(text))
        appendHistory(text)
        guard AXIsProcessTrusted() else {
            Inserter.copy(text)
            return false
        }
        Inserter.paste(Inserter.needsLeadingSpace() ? " " + text : text)
        return true
    }

    // MARK: - Permissions

    private func askForPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.askForAccessibility() }
            }
        } else {
            askForAccessibility()
        }
    }

    private func askForAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        watchForAccessibility()
    }

    private func watchForAccessibility() {
        axTimer?.invalidate()
        axTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self, AXIsProcessTrusted() else { return }
            timer.invalidate()
            self.hotkey.install()
            self.refreshIcon()
            self.overlay.flash("FreeFlow is ready · hold \(self.settings.talkKey.short) and talk", seconds: 3)
        }
    }

    // MARK: - Menu bar

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        if isRecording {
            name = "waveform.circle.fill"
        } else if inFlight > 0 {
            name = "ellipsis.circle"
        } else if server.lastError != nil {
            name = "mic.slash"
        } else {
            name = "mic"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "FreeFlow")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !server.isReady && !isRecording
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let key = settings.talkKey

        let status: String
        if let error = server.lastError {
            status = "⚠︎ \(error)"
        } else if !server.isReady {
            status = "Loading speech model…"
        } else {
            status = "Ready · runs offline, no word limit"
        }
        menu.addItem(info(status))
        menu.addItem(info("Hold \(key.short) to talk · tap ⇧ while holding for hands-free"))
        menu.addItem(.separator())

        let f = NumberFormatter()
        f.numberStyle = .decimal
        let today = f.string(from: NSNumber(value: settings.wordsToday)) ?? "0"
        let total = f.string(from: NSNumber(value: settings.wordsTotal)) ?? "0"
        menu.addItem(info("Words today: \(today) · all time: \(total)"))
        let copy = item("Copy last transcript", #selector(copyLast))
        copy.isEnabled = !lastTranscript.isEmpty
        menu.addItem(copy)
        menu.addItem(.separator())

        let keyMenu = NSMenu()
        for k in TalkKey.allCases {
            let it = item(k.title, #selector(pickKey(_:)))
            it.representedObject = k.rawValue
            it.state = k == key ? .on : .off
            keyMenu.addItem(it)
        }
        if key == .fn {
            keyMenu.addItem(.separator())
            keyMenu.addItem(info("Tip: Keyboard settings › Press 🌐 key to › Do Nothing"))
        }
        menu.addItem(submenu("Talk key", keyMenu))

        let langMenu = NSMenu()
        for l in Language.allCases {
            let it = item(l.title, #selector(pickLanguage(_:)))
            it.representedObject = l.rawValue
            it.state = l == settings.language ? .on : .off
            langMenu.addItem(it)
        }
        menu.addItem(submenu("Language", langMenu))

        let fillers = item("Remove filler words (um, uh)", #selector(toggleFillers))
        fillers.state = settings.removeFillers ? .on : .off
        menu.addItem(fillers)
        let sounds = item("Start and stop sounds", #selector(toggleSounds))
        sounds.state = settings.sounds ? .on : .off
        menu.addItem(sounds)
        menu.addItem(item("Edit dictionary…", #selector(editDictionary)))
        menu.addItem(item("Open history", #selector(openHistory)))
        menu.addItem(.separator())

        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(item("Allow microphone…", #selector(openMicSettings)))
        }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Allow typing into apps (Accessibility)…", #selector(openAccessibilitySettings)))
        }
        let login = item("Open at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit FreeFlow", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = menu
        return it
    }

    @objc private func copyLast() {
        Inserter.copy(lastTranscript)
    }

    @objc private func pickKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = TalkKey(rawValue: raw) else { return }
        settings.talkKey = k
        hotkey.key = k
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Language(rawValue: raw) else { return }
        settings.language = l
    }

    @objc private func toggleFillers() { settings.removeFillers.toggle() }
    @objc private func toggleSounds() { settings.sounds.toggle() }

    @objc private func editDictionary() {
        Vocabulary.ensureFile()
        NSWorkspace.shared.open(Paths.dictionary)
    }

    @objc private func openHistory() {
        if !FileManager.default.fileExists(atPath: Paths.history.path) {
            FileManager.default.createFile(atPath: Paths.history.path, contents: nil)
        }
        NSWorkspace.shared.open(Paths.history)
    }

    @objc private func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAccessibilitySettings() {
        askForAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            overlay.flash("Couldn't change the login setting", seconds: 2)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Helpers

    private func play(_ name: String) {
        guard settings.sounds, let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }

    private func appendHistory(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let line = "\(f.string(from: Date()))  \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Paths.history) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: Paths.history)
        }
    }

    private func log(_ message: String) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let url = Paths.logs.appendingPathComponent("freeflow.log")
        let line = "\(Date())  \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}
