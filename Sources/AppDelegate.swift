import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

/// One finished dictation or command, ready to paste.
struct Outcome {
    var text: String
    var raw: String
    var mode: String        // none, light, medium, command
    var app: String?
    var pressEnter = false
    var copyOnly = false    // Command Mode result with no editable field: show and copy instead of pasting
    var engine = ""         // which speech engine heard it, for saved recordings
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let server = WhisperServer()
    private let recorder = Recorder()
    private let hotkey = HotkeyMonitor()
    private let commandHotkey = HotkeyMonitor()
    private let overlay = Overlay()
    private let ai = Rewriter.shared
    private var statusItem: NSStatusItem!

    private enum Mode { case dictate, command }
    private var isRecording = false
    private var mode: Mode = .dictate
    private var handsFree = false
    private var recordStart = Date()
    private var frontApp: String?
    private var consumeNextUp = false
    private var maxLengthItem: DispatchWorkItem?
    private var warnItem: DispatchWorkItem?

    // Results are pasted in the order they were spoken, even if two are transcribing at once.
    private var nextId = 0
    private var nextToDeliver = 0
    private var finished: [Int: Outcome] = [:]
    private var pending: [Outcome] = []
    private var delivering = false
    private var overlayHeld = false
    private var inFlight = 0
    private var lastOutcome: Outcome?
    private var axTimer: Timer?
    private var aiNoted = false
    private var installingQwen = false

    private static let tapThreshold: TimeInterval = 0.3
    private static let maxLength: TimeInterval = 20 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        _ = Personalization.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        hotkey.onDown = { [weak self] in self?.talkDown(.dictate) }
        hotkey.onUp = { [weak self] in self?.talkUp() }
        hotkey.onKeyDown = { [weak self] code in self?.otherKey(code) }
        hotkey.onLock = { [weak self] in self?.lockHandsFree() }
        commandHotkey.onDown = { [weak self] in self?.talkDown(.command) }
        commandHotkey.onUp = { [weak self] in self?.talkUp() }
        commandHotkey.onLock = { [weak self] in self?.lockHandsFree() }
        installHotkeys()

        recorder.onLevel = { [weak self] level in self?.overlay.level(level) }
        server.onStateChange = { [weak self] in self?.refreshIcon() }
        server.switchTo(settings.engine)
        if settings.cleanupLevel == .medium || settings.commandMode { ai.warm() }
        Timer.scheduledTimer(withTimeInterval: 25 * 60, repeats: true) { [weak self] _ in
            guard let self = self, self.settings.cleanupLevel == .medium || self.settings.commandMode else { return }
            self.ai.warm()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.momominibot.freeflow.debug"), object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, self.settings.debugTriggers else { return }
            switch note.object as? String {
            case "down": self.talkDown(.dictate)
            case "command": self.talkDown(.command)
            case "up": self.talkUp()
            case "lock": self.lockHandsFree()
            case "paste":
                self.pending.append(Outcome(text: "Paste test from FreeFlow.", raw: "", mode: "light", app: nil))
                self.pumpDeliveries()
            default: break
            }
        }

        askForPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    private func installHotkeys() {
        hotkey.key = settings.talkKey
        hotkey.install()
        commandHotkey.remove()
        if settings.commandMode, settings.commandKey != settings.talkKey {
            commandHotkey.key = settings.commandKey
            commandHotkey.install()
        }
    }

    // MARK: - Talk key

    private func talkDown(_ m: Mode) {
        if isRecording, handsFree {
            consumeNextUp = true
            finishRecording()
            return
        }
        guard !isRecording else { return }
        startRecording(m, handsFree: false)
    }

    /// Shift tapped while holding the talk key. Releasing the talk key then keeps recording;
    /// tapping the talk key again finishes. (Double-tapping Option is avoided on purpose:
    /// the Claude desktop app uses it for Quick Entry.)
    private func lockHandsFree() {
        guard isRecording, !handsFree else { return }
        handsFree = true
        consumeNextUp = true
        overlay.setHint("Hands-free · tap \(activeKey.short) to finish")
        play("Tink")
    }

    private var activeKey: TalkKey { mode == .command ? settings.commandKey : settings.talkKey }

    private func talkUp() {
        if consumeNextUp {
            consumeNextUp = false
            return
        }
        guard isRecording, !handsFree else { return }
        if Date().timeIntervalSince(recordStart) < Self.tapThreshold {
            if settings.tapToToggle, mode == .dictate {
                // Quick tap: keep listening until the key is tapped again.
                handsFree = true
                overlay.showRecording(hint: "Listening · tap \(activeKey.short) again to finish")
                play("Tink")
                return
            }
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

    private func startRecording(_ m: Mode, handsFree: Bool) {
        if let error = server.lastError {
            overlay.flash(error, seconds: 3)
            return
        }
        if m == .command, !ai.cachedAvailable, !ai.isAvailable() {
            overlay.flash("Command Mode needs the local AI · start Ollama (menu: AI status)", seconds: 3)
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
        mode = m
        self.handsFree = handsFree
        recordStart = Date()
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let hint: String
        if m == .command {
            hint = "Command · say what to do with the selected text"
        } else {
            hint = handsFree ? "Hands-free · tap \(settings.talkKey.short) to finish" : ""
        }
        overlay.showRecording(hint: hint)
        refreshIcon()

        if handsFree || m == .command {
            play("Tink")
        } else {
            let started = recordStart
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapThreshold) { [weak self] in
                guard let self = self, self.isRecording, self.recordStart == started else { return }
                self.play("Tink")
            }
        }
        let warn = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.overlay.setHint("One minute left in this dictation")
        }
        warnItem = warn
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxLength - 60, execute: warn)
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
        warnItem?.cancel()
        recorder.cancel()
        if inFlight == 0 { overlay.hide() } else { overlay.showTranscribing() }
        refreshIcon()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        handsFree = false
        maxLengthItem?.cancel()
        warnItem?.cancel()
        play("Pop")
        let id = nextId
        nextId += 1
        inFlight += 1
        let m = mode
        let app = frontApp
        overlay.showTranscribing()
        refreshIcon()

        recorder.stop(tail: 0.15) { [weak self] take in
            guard let self = self else { return }
            self.log(String(format: "take #%d %@ %.1fs peak %.0f dB app %@", id, m == .command ? "command" : "dictation",
                            take.duration, take.peakDb, app ?? "?"))
            if take.duration < 0.35 {
                return self.done(id, nil, file: take.url)
            }
            if take.peakDb < -50 {
                self.overlay.flash("Didn't hear anything · check your mic", seconds: 2)
                return self.done(id, nil, file: take.url, keepOverlay: true)
            }
            let p = Personalization.load()
            if let e = p.teamError { self.overlay.flash(e, seconds: 2) }
            let language = m == .command ? "en" : self.settings.language.rawValue
            self.server.transcribe(take.url, language: language, prompt: p.vocab.prompt) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let raw):
                        if m == .command {
                            self.runCommand(id, raw: raw, app: app, take: take, personalization: p)
                        } else {
                            self.process(id, raw: raw, app: app, take: take, personalization: p)
                        }
                    case .failure(let error):
                        self.log("transcription failed: \(error.localizedDescription)")
                        self.overlay.flash("Couldn't transcribe · \(error.localizedDescription)", seconds: 3)
                        self.done(id, nil, file: take.url, keepOverlay: true)
                    }
                }
            }
        }
    }

    /// Dictation pipeline: rules, snippets, spoken commands, then the AI pass when it applies.
    private func process(_ id: Int, raw: String, app: String?, take: Recorder.Take, personalization p: Personalization) {
        let quiet = take.peakDb < -30
        let level = settings.cleanupLevel
        let light = TextCleaner.clean(raw, removeFillers: settings.removeFillers, vocab: p.vocab, quiet: quiet)
        var base = level == .none ? TextCleaner.raw(raw, quiet: quiet) : light
        if base.isEmpty { return done(id, nil, file: take.url) }
        let expanded = Snippet.apply(p.snippets, to: base)
        let snippetHit = expanded != base
        base = expanded
        let cmd = SpokenCommands.parse(base)
        var outcome = Outcome(text: cmd.text, raw: TextCleaner.raw(raw, quiet: quiet), mode: level.rawValue, app: app, pressEnter: cmd.pressEnter)

        let style = p.style(for: app)
        log("take #\(id) transcribed \(TextCleaner.wordCount(raw)) words, level \(level.rawValue), style \(style.rawValue)")
        guard level == .medium, !snippetHit, style != .plain, ai.cachedAvailable || ai.isAvailable() else {
            if level == .medium, !aiNoted, !ai.cachedAvailable, style != .plain, !snippetHit {
                aiNoted = true
                overlay.flash("Local AI not running · using rule-based clean-up (menu: AI status)", seconds: 3)
            }
            if level == .medium { outcome.mode = "light" }
            return done(id, outcome, file: take.url)
        }
        overlay.showTranscribing(label: "Tidying…")
        let started = Date()
        ai.cleanup(cmd.text, style: style, fallback: cmd.text) { text, usedAI in
            DispatchQueue.main.async {
                self.log(String(format: "take #%d ai %@ in %.2fs", id, usedAI ? "used" : "fallback", Date().timeIntervalSince(started)))
                outcome.text = text
                if !usedAI { outcome.mode = "light" }
                if !usedAI, let e = self.ai.lastError { self.log("ai cleanup fell back: \(e)") }
                self.done(id, outcome, file: take.url)
            }
        }
    }

    /// Command Mode: the spoken words are an instruction; the selection (or surrounding text) is what it acts on.
    private func runCommand(_ id: Int, raw: String, app: String?, take: Recorder.Take, personalization p: Personalization) {
        let instruction = TextCleaner.clean(raw, removeFillers: true, vocab: p.vocab, quiet: take.peakDb < -30)
        guard TextCleaner.wordCount(instruction) >= 1 else { return done(id, nil, file: take.url) }
        overlay.showTranscribing(label: "Working on it…")
        Inserter.readFocus { focus in
            self.ai.command(instruction, selection: focus.selection, context: focus.context) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text) where !text.isEmpty:
                        var o = Outcome(text: text, raw: instruction, mode: "command", app: app)
                        // Nowhere to type (a web page, a PDF, the desktop): show the answer and copy it instead of pasting.
                        o.copyOnly = !focus.editable
                        self.done(id, o, file: take.url)
                    case .success:
                        self.overlay.flash("The AI returned nothing", seconds: 2)
                        self.done(id, nil, file: take.url, keepOverlay: true)
                    case .failure(let e):
                        self.overlay.flash("Command failed · \(e.localizedDescription)", seconds: 3)
                        self.done(id, nil, file: take.url, keepOverlay: true)
                    }
                }
            }
        }
    }

    private func done(_ id: Int, _ outcome: Outcome?, file: URL, keepOverlay: Bool = false) {
        if settings.keepTakes, var o = outcome, !o.text.isEmpty {
            o.engine = settings.engine.rawValue
            TakeStore.keep(file, engine: o.engine, heard: o.raw, final: o.text, mode: o.mode)
        }
        try? FileManager.default.removeItem(at: file)
        inFlight -= 1
        finished[id] = outcome ?? Outcome(text: "", raw: "", mode: "none", app: nil)
        while let next = finished.removeValue(forKey: nextToDeliver) {
            nextToDeliver += 1
            guard !next.text.isEmpty else { continue }
            pending.append(next)
        }
        if keepOverlay { overlayHeld = true }
        pumpDeliveries()
        settle()
    }

    /// Hides the pill once nothing is recording, transcribing, pasting or flashing a message.
    private func settle() {
        if !isRecording, inFlight == 0, pending.isEmpty, !delivering, !overlay.isFlashing, !overlayHeld {
            overlay.hide()
        }
        overlayHeld = false
        refreshIcon()
    }

    /// Pastes one result at a time. Two ⌘V in flight at once would share one clipboard and overwrite each other.
    private func pumpDeliveries() {
        guard !delivering, !pending.isEmpty else { return }
        delivering = true
        let o = pending.removeFirst()
        deliver(o) { [weak self] in
            guard let self = self else { return }
            self.delivering = false
            if self.pending.isEmpty { self.settle() } else { self.pumpDeliveries() }
        }
    }

    private func deliver(_ o: Outcome, completion: @escaping () -> Void) {
        lastOutcome = o
        settings.addWords(TextCleaner.wordCount(o.text), app: o.app)
        appendHistory(o)
        TeamFolder.shareUsage()
        let preview = o.text.prefix(70).replacingOccurrences(of: "\n", with: " ")
        if o.copyOnly {
            Inserter.copy(o.text)
            overlay.flash("Copied: \(preview)", seconds: 4)
            return completion()
        }
        guard AXIsProcessTrusted() else {
            Inserter.copy(o.text)
            overlay.flash("Copied · press ⌘V to paste (allow Accessibility to type automatically)", seconds: 3)
            return completion()
        }
        // The result belongs to the app you were in when you spoke. If you have since switched, do not type into the wrong window.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let app = o.app, let front = front, app != front, front != Bundle.main.bundleIdentifier {
            Inserter.copy(o.text)
            overlay.flash("You switched to \(appName(front)) · result copied, press ⌘V where you want it", seconds: 4)
            return completion()
        }
        // A command replaces the selection, so no leading space; a dictation continues the sentence.
        let text = o.mode == "command" ? o.text : (Inserter.needsLeadingSpace() ? " " + o.text : o.text)
        Inserter.paste(text) {
            if o.pressEnter { Inserter.pressReturn() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: completion)
        }
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
            self.installHotkeys()
            self.refreshIcon()
            self.overlay.flash("FreeFlow is ready · tap \(self.settings.talkKey.short), talk, tap again", seconds: 3)
        }
    }

    // MARK: - Menu bar

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let name: String
        if isRecording {
            name = mode == .command ? "wand.and.stars" : "waveform.circle.fill"
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
        ai.refreshAvailability()
        let key = settings.talkKey

        let status: String
        if let error = server.lastError {
            status = "⚠︎ \(error)"
        } else if !server.isReady {
            status = "Loading \(settings.engine.short)…"
        } else {
            status = "Ready · \(settings.engine.short) · runs offline, no word limit"
        }
        menu.addItem(info(status))
        menu.addItem(info("Tap \(key.short) to start, tap again to finish · or hold to talk"))
        if settings.commandMode {
            menu.addItem(info("Hold \(settings.commandKey.short) and say what to do with selected text"))
        }
        let aiOK = ai.cachedAvailable
        menu.addItem(info(aiOK ? "AI status: local \(settings.aiModel) ready" : "AI status: Ollama not running · AI clean-up and commands are off"))
        menu.addItem(.separator())

        let f = NumberFormatter()
        f.numberStyle = .decimal
        let today = f.string(from: NSNumber(value: settings.wordsToday)) ?? "0"
        let total = f.string(from: NSNumber(value: settings.wordsTotal)) ?? "0"
        menu.addItem(info("Words today: \(today) · all time: \(total)"))
        let apps = settings.topApps(5)
        if !apps.isEmpty {
            let appMenu = NSMenu()
            for (id, n) in apps {
                appMenu.addItem(info("\(appName(id)): \(f.string(from: NSNumber(value: n)) ?? "0")"))
            }
            menu.addItem(submenu("Top apps", appMenu))
        }
        let copy = item("Copy last result", #selector(copyLast))
        copy.isEnabled = lastOutcome != nil
        menu.addItem(copy)
        if let last = lastOutcome, last.mode == "medium", last.raw != last.text {
            menu.addItem(item("Undo AI edit · copy what you actually said", #selector(undoAI)))
        }
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
        let tapItem = item("Tap to start and stop", #selector(toggleTapMode))
        tapItem.state = settings.tapToToggle ? .on : .off
        menu.addItem(tapItem)

        let engineMenu = NSMenu()
        for e in SpeechEngine.allCases {
            let it = item(e.title, #selector(pickEngine(_:)))
            it.representedObject = e.rawValue
            it.state = e == settings.engine ? .on : .off
            engineMenu.addItem(it)
        }
        engineMenu.addItem(.separator())
        if installingQwen {
            engineMenu.addItem(info("Installing the Qwen engine… (about 5 GB, a few minutes)"))
        } else if !WhisperServer.qwenInstalled {
            engineMenu.addItem(info("Picking Qwen downloads it once (about 5 GB). Nothing is uploaded."))
        }
        let keep = item("Keep my recordings on this Mac (to compare engines)", #selector(toggleKeepTakes))
        keep.state = settings.keepTakes ? .on : .off
        engineMenu.addItem(keep)
        engineMenu.addItem(item("Show saved recordings", #selector(showTakes)))
        engineMenu.addItem(item("Delete saved recordings", #selector(deleteTakes)))
        menu.addItem(submenu("Speech engine", engineMenu))

        let cmdMenu = NSMenu()
        let cmdOn = item("Command Mode on", #selector(toggleCommandMode))
        cmdOn.state = settings.commandMode ? .on : .off
        cmdMenu.addItem(cmdOn)
        cmdMenu.addItem(.separator())
        for k in TalkKey.allCases where k != key {
            let it = item(k.title, #selector(pickCommandKey(_:)))
            it.representedObject = k.rawValue
            it.state = k == settings.commandKey ? .on : .off
            cmdMenu.addItem(it)
        }
        cmdMenu.addItem(.separator())
        cmdMenu.addItem(info("Select text, hold the key, say \"make this shorter\""))
        cmdMenu.addItem(info("No selection: say \"reply saying I'll be there at 3\""))
        menu.addItem(submenu("Command Mode", cmdMenu))

        let langMenu = NSMenu()
        for l in Language.allCases {
            let it = item(l.title, #selector(pickLanguage(_:)))
            it.representedObject = l.rawValue
            it.state = l == settings.language ? .on : .off
            langMenu.addItem(it)
        }
        menu.addItem(submenu("Language", langMenu))

        let cleanMenu = NSMenu()
        for c in CleanupLevel.allCases {
            let it = item(c.title, #selector(pickCleanup(_:)))
            it.representedObject = c.rawValue
            it.state = c == settings.cleanupLevel ? .on : .off
            cleanMenu.addItem(it)
        }
        cleanMenu.addItem(.separator())
        cleanMenu.addItem(info("Medium uses the app you're in: formal in Mail, casual in Slack"))
        cleanMenu.addItem(item("Edit styles by app…", #selector(editStyles)))
        menu.addItem(submenu("Auto cleanup", cleanMenu))

        let fillers = item("Remove filler words (um, uh)", #selector(toggleFillers))
        fillers.state = settings.removeFillers ? .on : .off
        menu.addItem(fillers)
        let sounds = item("Start and stop sounds", #selector(toggleSounds))
        sounds.state = settings.sounds ? .on : .off
        menu.addItem(sounds)
        menu.addItem(.separator())

        menu.addItem(item("Teach a word…", #selector(teachWord)))
        menu.addItem(item("Edit dictionary…", #selector(editDictionary)))
        menu.addItem(item("Edit snippets…", #selector(editSnippets)))
        menu.addItem(item("Open history", #selector(openHistory)))

        let teamMenu = NSMenu()
        if let team = settings.teamFolderURL {
            teamMenu.addItem(info("Folder: \(team.path.replacingOccurrences(of: Paths.home.path, with: "~"))"))
            teamMenu.addItem(item("Open team folder", #selector(openTeamFolder)))
            teamMenu.addItem(item("Choose a different folder…", #selector(chooseTeamFolder)))
            teamMenu.addItem(item("Stop using the team folder", #selector(clearTeamFolder)))
            teamMenu.addItem(.separator())
            let share = item("Share my word counts with the team", #selector(toggleShareUsage))
            share.state = settings.shareUsage ? .on : .off
            teamMenu.addItem(share)
            let usage = TeamFolder.teamUsage()
            if !usage.isEmpty {
                teamMenu.addItem(.separator())
                for (name, today, total) in usage {
                    teamMenu.addItem(info("\(name): \(f.string(from: NSNumber(value: today)) ?? "0") today · \(f.string(from: NSNumber(value: total)) ?? "0") total"))
                }
            }
        } else {
            teamMenu.addItem(info("Share a dictionary, snippets and styles with your team"))
            teamMenu.addItem(info("Pick any folder everyone syncs: iCloud Drive, Dropbox, the NAS"))
            teamMenu.addItem(item("Choose team folder…", #selector(chooseTeamFolder)))
        }
        menu.addItem(submenu("Team", teamMenu))
        menu.addItem(item("Connect to Claude Code (copies the command)", #selector(copyMCPCommand)))
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

    private func appName(_ bundleId: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId
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
        if let t = lastOutcome?.text { Inserter.copy(t) }
    }

    @objc private func undoAI() {
        guard let o = lastOutcome else { return }
        Inserter.copy(o.raw)
        overlay.flash("Original words copied · paste with ⌘V", seconds: 3)
    }

    @objc private func pickKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = TalkKey(rawValue: raw) else { return }
        settings.talkKey = k
        if settings.commandKey == k {
            settings.commandKey = TalkKey.allCases.first { $0 != k } ?? .rightControl
        }
        installHotkeys()
    }

    @objc private func pickCommandKey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = TalkKey(rawValue: raw) else { return }
        settings.commandKey = k
        installHotkeys()
    }

    @objc private func toggleTapMode() { settings.tapToToggle.toggle() }

    @objc private func pickEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = SpeechEngine(rawValue: raw),
              e != settings.engine || server.lastError != nil else { return }
        if e == .qwen, !WhisperServer.qwenInstalled {
            return installQwen()
        }
        settings.engine = e
        server.switchTo(e)
        overlay.flash("Speech engine: \(e.short)", seconds: 2)
    }

    /// Runs scripts/install-qwen-engine.sh (bundled) once: a private Python env plus the model download.
    private func installQwen() {
        guard !installingQwen else { return }
        guard WhisperServer.qwenScript != nil,
              let script = Bundle.main.url(forResource: "install-qwen-engine", withExtension: "sh") else {
            return overlay.flash("Qwen installer missing from this build", seconds: 3)
        }
        installingQwen = true
        overlay.flash("Installing the Qwen engine · about 5 GB, a few minutes", seconds: 4)
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let logURL = Paths.logs.appendingPathComponent("qwen-install.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.installingQwen = false
                if proc.terminationStatus == 0, WhisperServer.qwenInstalled {
                    self.settings.engine = .qwen
                    self.server.switchTo(.qwen)
                    self.overlay.flash("Qwen engine installed · loading it now", seconds: 3)
                } else {
                    self.overlay.flash("Qwen install failed · see ~/Library/Logs/FreeFlow/qwen-install.log", seconds: 5)
                }
            }
        }
        do { try p.run() } catch {
            installingQwen = false
            overlay.flash("Couldn't start the Qwen installer", seconds: 3)
        }
    }

    @objc private func toggleKeepTakes() { settings.keepTakes.toggle() }

    @objc private func showTakes() {
        try? FileManager.default.createDirectory(at: Paths.takes, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.takes)
    }

    @objc private func deleteTakes() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete all saved recordings?"
        alert.informativeText = "This removes the audio and the text saved with it. It can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: Paths.takes)
        overlay.flash("Saved recordings deleted", seconds: 2)
    }

    @objc private func toggleCommandMode() {
        settings.commandMode.toggle()
        installHotkeys()
        if settings.commandMode { ai.warm() }
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let l = Language(rawValue: raw) else { return }
        settings.language = l
    }

    @objc private func pickCleanup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = CleanupLevel(rawValue: raw) else { return }
        settings.cleanupLevel = c
        aiNoted = false
        if c == .medium { ai.warm() }
    }

    @objc private func toggleFillers() { settings.removeFillers.toggle() }
    @objc private func toggleSounds() { settings.sounds.toggle() }
    @objc private func toggleShareUsage() {
        settings.shareUsage.toggle()
        if settings.shareUsage { TeamFolder.shareUsage() }
    }

    @objc private func teachWord() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Teach FreeFlow a word"
        alert.informativeText = "A name, product or term Whisper keeps getting wrong. For a forced swap write  wrong => right"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Ranklore   or   Rank Lore => Ranklore"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            Vocabulary.add(field.stringValue)
        }
    }

    @objc private func editDictionary() {
        Vocabulary.ensureFile()
        NSWorkspace.shared.open(Paths.dictionary)
    }

    @objc private func editSnippets() {
        _ = Personalization.load()
        NSWorkspace.shared.open(Paths.snippets)
    }

    @objc private func editStyles() {
        _ = Personalization.load()
        NSWorkspace.shared.open(Paths.styles)
    }

    @objc private func openHistory() {
        if !FileManager.default.fileExists(atPath: Paths.history.path) {
            FileManager.default.createFile(atPath: Paths.history.path, contents: nil)
        }
        NSWorkspace.shared.open(Paths.history)
    }

    @objc private func chooseTeamFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Pick a folder your whole team syncs (iCloud Drive, Dropbox, the NAS). FreeFlow keeps team-dictionary.txt, team-snippets.txt and team-styles.txt there."
        if panel.runModal() == .OK, let url = panel.url {
            settings.teamFolder = url.path
            TeamFolder.prepare(url)
            overlay.flash("Team folder set · \(url.lastPathComponent)", seconds: 2)
        }
    }

    @objc private func openTeamFolder() {
        guard let url = settings.teamFolderURL else { return }
        TeamFolder.prepare(url)
        NSWorkspace.shared.open(url)
    }

    @objc private func clearTeamFolder() {
        settings.teamFolder = nil
        settings.shareUsage = false
    }

    @objc private func copyMCPCommand() {
        let script = (Bundle.main.resourcePath ?? "/Applications/FreeFlow.app/Contents/Resources") + "/freeflow-mcp.py"
        Inserter.copy("claude mcp add --scope user freeflow -- /usr/bin/env python3 \"\(script)\"")
        overlay.flash("Command copied · paste it in a terminal, then Claude can search your dictations", seconds: 4)
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

    private func appendHistory(_ o: Outcome) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        append(Paths.history, "\(f.string(from: Date()))  \(o.text.replacingOccurrences(of: "\n", with: " ⏎ "))\n")
        let iso = ISO8601DateFormatter().string(from: Date())
        let record: [String: Any] = ["t": iso, "app": o.app ?? "", "mode": o.mode, "raw": o.raw, "text": o.text]
        if let data = try? JSONSerialization.data(withJSONObject: record), let line = String(data: data, encoding: .utf8) {
            append(Paths.historyJSON, line + "\n")
        }
    }

    private func append(_ url: URL, _ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private func log(_ message: String) {
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        append(Paths.logs.appendingPathComponent("freeflow.log"), "\(Date())  \(message)\n")
    }
}
