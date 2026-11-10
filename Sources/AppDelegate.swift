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
    var secs: Double = 0    // how long the person talked, for words per minute
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
    private let bridge = AppBridge()
    private var studio: StudioWindowController?
    private lazy var meetings = MeetingController(
        overlay: overlay,
        transcribe: { [weak self] url, done in self?.transcribeForNotes(url, done) ?? done(.failure(FFError(message: "FreeFlow is closing"))) },
        cleanup: { raw, quiet in
            TextCleaner.clean(raw, removeFillers: false, vocab: Personalization.load().vocab, quiet: quiet)
        })
    private let summarizer = NoteSummarizer()
    private let workday = WorkdayRecorder()
    private let detail = DetailRecorder()
    private let unsent = UnsentCard()
    private let typing = TypingLearner()
    private lazy var files = FileTranscriber(
        transcribe: { [weak self] url, done in self?.transcribeForNotes(url, done) ?? done(.failure(FFError(message: "FreeFlow is closing"))) },
        cleanup: { raw in TextCleaner.clean(raw, removeFillers: false, vocab: Personalization.load().vocab, quiet: false) })

    private enum Mode { case dictate, command }
    private var isRecording = false
    private var mode: Mode = .dictate
    private var handsFree = false
    private var recordStart = Date()
    private var frontApp: String?
    private var consumeNextUp = false
    private var doubleTap = DoubleTapGate()
    private var secondTapItem: DispatchWorkItem?
    private var finishGate = DoubleTapGate()
    private var finishPressAt = Date.distantPast
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

    /// Watches the text box FreeFlow just typed into, to learn from the words you fix.
    private lazy var corrections: CorrectionWatcher = {
        let w = CorrectionWatcher()
        w.onLearned = { [weak self] pairs in self?.announceLearned(pairs) }
        return w
    }()

    private static let tapThreshold: TimeInterval = 0.3
    private static let maxLength: TimeInterval = 20 * 60

    /// Clicking the Dock icon, or opening FreeFlow from Spotlight or Launchpad while it is running, shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openStudio(nil)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        Fonts.registerAll()
        AppearanceChoice.applySaved()
        workday.log = { [weak self] m in self?.log(m) }
        if settings.workdayOn { workday.start() }
        detail.log = { [weak self] m in self?.log(m) }
        detail.apply()
        unsent.log = { [weak self] m in self?.log(m) }
        typing.log = { [weak self] m in self?.log(m) }
        typing.onLearned = { [weak self] pairs in
            if let p = pairs.first { self?.overlay.flash("Learned: \(p.wrong) \u{2192} \(p.right)", seconds: 2.5) }
        }
        if settings.learnFromTyping { typing.start() }
        _ = Personalization.load()
        installMainMenu()
        wireBridge()
        overlay.start()
        meetings.changed = { [weak self] in self?.refreshIcon() }
        meetings.log = { [weak self] m in self?.log(m) }
        meetings.finishedNote = { [weak self] url in self?.summarize(url, quiet: true) }
        files.log = { [weak self] m in self?.log(m) }
        summarizer.log = { [weak self] m in self?.log(m) }
        files.changed = { [weak self] in self?.studio?.model.reload() }
        summarizer.changed = { [weak self] in self?.studio?.model.reload() }
        meetings.start()

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

        // Distributed notifications are held back while a menu-bar app is in the background, unless asked for at once.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleDebug(_:)), name: Notification.Name("com.momominibot.freeflow.debug"),
            object: nil, suspensionBehavior: .deliverImmediately)

        // Check of the whole meeting path inside the real app, which has its own microphone permission:
        //   open -n -a FreeFlow --args --meeting-selftest 25
        if let i = CommandLine.arguments.firstIndex(of: "--meeting-selftest"), i + 1 < CommandLine.arguments.count {
            let secs = Double(CommandLine.arguments[i + 1]) ?? 25
            log("meeting selftest: starting for \(secs)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.meetings.startNow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + secs) { [weak self] in self?.meetings.stop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + secs + 30) { NSApp.terminate(nil) }
        }

        askForPermissions()
        if !settings.seenHome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openStudio(.home) }
        }
    }

    /// Test hooks, only when the debugTriggers setting is on: down, up, tap, command, lock, paste, home:<page>, settings:<tab>,
    /// pill:<state>, meeting:start, meeting:stop, call:zoom, call:none, call:real, workday:on, workday:off, workday:flush,
    /// transform:<id>, file:<path>, summary:<note>.
    @objc private func handleDebug(_ note: Notification) {
        guard settings.debugTriggers else { return }
        switch note.object as? String {
        case "down": self.talkDown(.dictate)
        case "command": self.talkDown(.command)
        case "up": self.talkUp()
        case "tap":
            // A real quick tap of the talk key: down, then up 0.1 s later. The first starts hands-free, the next one finishes.
            self.talkDown(.dictate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.talkUp() }
        case "tap:double":
            // Two quick taps 0.3 s apart, as a real double tap of the talk key would be.
            self.talkDown(.dictate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.talkUp() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.talkDown(.dictate) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.talkUp() }
        case "lock": self.lockHandsFree()
        case "call:zoom": self.meetings.detect = { ("Zoom", "us.zoom.xos") }     // pretend a Zoom call is on, to test the rules
        case "call:none": self.meetings.detect = { nil }
        case "call:real": self.meetings.detect = { MicWatch.currentCall() }
        case "typing:on": self.settings.learnFromTyping = true; self.typing.start()
        case "typing:off": self.settings.learnFromTyping = false; self.typing.stop()
        case "typing:probe": self.log(self.typing.probe())
        case "typing:once:on": self.settings.learnTypingAtOnce = true
        case "typing:once:off": self.settings.learnTypingAtOnce = false
        case "unsent:show": self.unsent.show(text: "Test: this dictation did not reach a text box.", reason: "Shown by the check on this Mac.", onPasteAgain: { Inserter.paste($0) })
        case "unsent:hide": self.unsent.hide()
        case "look":
            // what the arrival check can see in the focused box right now: kinds and lengths only, never the text
            let seen = Inserter.look()
            var desc = "look: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"): \(seen.landing)"
            if let el = seen.element {
                var role: CFTypeRef?, sub: CFTypeRef?
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
                let web = Inserter.isWebContent(el)
                desc += ", role \(role as? String ?? "?"), subrole \(sub as? String ?? "none"), settable \(Inserter.isSettable(el)), web content \(web), value length \(seen.before?.count ?? -1)"
            }
            self.log(desc)
        case "hermes:ping":
            // a real card to the chosen agent with a harmless one-word job, to see the whole route work (runs on the local model)
            DispatchQueue.global().async {
                let r = Hermes.send("FreeFlow connection test (ignore)", "Reply with the single word OK. Do not use any tools and do not change anything. This is only a connection test from FreeFlow.")
                DispatchQueue.main.async {
                    switch r {
                    case .success(let out): self.log("hermes: ping sent. \(out)")
                    case .failure(let e): self.log("hermes: ping FAILED. \(e.message)")
                    }
                }
            }
        case "hermes:check":
            Hermes.check { r in
                switch r {
                case .success(let out): self.log("hermes: connection works. \(out)")
                case .failure(let e): self.log("hermes: connection FAILED. \(e.message)")
                }
            }
        case "gesture:double": self.settings.doubleTapToStart = true; self.doubleTap.expire()
        case "gesture:one": self.settings.doubleTapToStart = false; self.doubleTap.expire()
        case "workday:on": self.settings.workdayOn = true; self.workday.start()
        case "workday:off": self.settings.workdayOn = false; self.workday.stop()
        case "workday:flush": self.workday.flush()
        case "detail:screen:on": self.settings.screenTextOn = true; self.detail.apply()
        case "detail:screen:off": self.settings.screenTextOn = false; self.detail.apply()
        case "detail:typing:on": self.settings.typingDetailOn = true; self.detail.apply()
        case "detail:typing:off": self.settings.typingDetailOn = false; self.detail.apply()
        case "detail:pictures:on": self.settings.keepPictures = true
        case "detail:pictures:off": self.settings.keepPictures = false
        case "detail:snap": self.detail.readNow(force: true)
        case "detail:flush": self.detail.flush()
        case "detail:forget": DetailStore.forgetAll(); self.log("detail: everything forgotten")
        case "meeting:start": self.meetings.startNow()
        case "meeting:stop": self.meetings.stop()
        case "paste":
            self.pending.append(Outcome(text: "Paste test from FreeFlow.", raw: "", mode: "light", app: nil))
            self.pumpDeliveries()
        default:
            // Checks and screenshots: "home:<page>" opens the window, "pill:<state>[:text]" shows the bar.
            guard let cmd = note.object as? String else { break }
            if cmd.hasPrefix("home:") {
                self.openStudio(StudioModel.Page(rawValue: String(cmd.dropFirst(5))) ?? .home)
                self.studio?.model.settingsTab = nil
            } else if cmd.hasPrefix("settings:") {
                self.openStudio(nil)
                self.studio?.model.openSettings(SettingsTab(rawValue: String(cmd.dropFirst(9))) ?? .general)
            } else if cmd.hasPrefix("transform:") {
                if let t = ModeStore.load().transforms.first(where: { $0.id == String(cmd.dropFirst(10)) }) { self.runTransform(t) }
            } else if cmd.hasPrefix("file:") {
                self.startFile(URL(fileURLWithPath: String(cmd.dropFirst(5))))
            } else if cmd.hasPrefix("summary:") {
                self.summarize(Paths.meetings.appendingPathComponent(String(cmd.dropFirst(8))), quiet: false)
            } else if cmd.hasPrefix("pill:") {
                let parts = cmd.dropFirst(5).split(separator: ":", maxSplits: 1).map(String.init)
                self.overlay.preview(parts.first ?? "idle", text: parts.count > 1 ? parts[1] : "")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if workday.running { workday.stop() }
        detail.stopTyping()
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
        if settings.doubleTapToStart { log("talk key: pressed (recording \(isRecording), waiting for a second tap \(doubleTap.waiting), hands-free \(handsFree))") }
        if isRecording, handsFree {
            finishPressAt = Date()
            if settings.doubleTapToStart {
                // Listening hands-free: finishing takes two quick taps as well, so one stray press cannot end the dictation.
                if finishGate.pressBegan(at: Date()) {
                    consumeNextUp = true
                    log("talk key: double tap, finishing")
                    finishRecording()
                }
                return
            }
            consumeNextUp = true
            finishRecording()
            return
        }
        if isRecording, doubleTap.waiting, m == .dictate {
            // The second press of a double tap, while the first quick tap's recording is still open: carry on with it, hands-free.
            secondTapItem?.cancel()
            if doubleTap.pressBegan(at: Date()) {
                handsFree = true
                consumeNextUp = true
                log("talk key: double tap, hands-free is on")
                finishGate.expire()
                overlay.showRecording(hint: "Listening · \(settings.finishPhrase(activeKey)) to finish")
                play("Tink")
                refreshIcon()
                return
            }
            cancelRecording()       // too late to be the second tap: that recording is over; this press starts a new one
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
        finishGate.expire()
        overlay.setHint("Hands-free · \(settings.finishPhrase(activeKey)) to finish")
        play("Tink")
    }

    private var activeKey: TalkKey { mode == .command ? settings.commandKey : settings.talkKey }

    private func talkUp() {
        if settings.doubleTapToStart { log(String(format: "talk key: released after %.2f s", Date().timeIntervalSince(recordStart))) }
        if consumeNextUp {
            consumeNextUp = false
            return
        }
        if isRecording, handsFree, settings.doubleTapToStart {
            // Listening hands-free: a quick tap is the first of the two that finish; a long press (more than half a second) also
            // finishes, so you can never be stuck; anything in between does nothing.
            let held = Date().timeIntervalSince(finishPressAt)
            if held >= 0.6 {
                log("talk key: held while listening, finishing")
                finishRecording()
            } else if held < Self.tapThreshold {
                finishGate.firstTapEnded(at: Date())
                log("talk key: one quick tap while listening, tap again to finish")
            }
            return
        }
        guard isRecording, !handsFree else { return }
        if Date().timeIntervalSince(recordStart) < Self.tapThreshold {
            if settings.tapToToggle, mode == .dictate {
                if settings.doubleTapToStart {
                    // The first of two taps: nothing is typed and no pill is shown. The recording stays open for a moment so a
                    // second press can carry on with it; if none comes, it is dropped.
                    doubleTap.firstTapEnded(at: Date())
                    log("talk key: one quick tap, waiting for a second (double-tap mode)")
                    let started = recordStart
                    let item = DispatchWorkItem { [weak self] in
                        guard let self = self, self.doubleTap.waiting, self.isRecording, self.recordStart == started else { return }
                        self.doubleTap.expire()
                        self.cancelRecording()
                    }
                    secondTapItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + DoubleTapGate.window + 0.05, execute: item)
                    return
                }
                // Quick tap: keep listening until the key is tapped again.
                handsFree = true
                overlay.showRecording(hint: "Listening · tap \(activeKey.short) again to finish")
                play("Tink")
                return
            }
            cancelRecording()
            return
        }
        doubleTap.expire()
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
            log("talk key: the microphone did not start")
            if recorder.lastStartTimedOut {
                log("microphone did not answer within \(Recorder.openTimeout)s: macOS audio looks stuck")
                overlay.flash("The microphone isn't answering. macOS audio is stuck: restart the Mac, or run  sudo killall coreaudiod", seconds: 7)
            } else {
                overlay.flash("Microphone didn't start", seconds: 2)
            }
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
            hint = handsFree ? "Hands-free · \(settings.finishPhrase(settings.talkKey)) to finish" : ""
        }
        if settings.doubleTapToStart, settings.tapToToggle, m == .dictate, !handsFree {
            let started = recordStart
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapThreshold) { [weak self] in
                guard let self = self, self.isRecording, self.recordStart == started else { return }
                self.overlay.showRecording(hint: hint)
            }
        } else {
            overlay.showRecording(hint: hint)
        }
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
        doubleTap.expire()
        finishGate.expire()
        secondTapItem?.cancel()
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
        doubleTap.expire()
        finishGate.expire()
        secondTapItem?.cancel()
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
            let prompt = language == Language.mixed.rawValue ? p.vocab.promptMixed : p.vocab.prompt
            self.server.transcribe(take.url, language: language, prompt: prompt) { result in
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
        // "Note to self ..." goes to the Scratchpad instead of being typed into the app in front.
        if let note = ScratchStore.noteToSelf(base) {
            ScratchStore.create(text: note)
            log("take #\(id) saved to Jots, \(TextCleaner.wordCount(note)) words")
            overlay.flash("Saved to your Jots", seconds: 2.5)
            return done(id, nil, file: take.url, keepOverlay: true)
        }
        let expanded = Snippet.apply(p.snippets, to: base)
        let snippetHit = expanded != base
        base = expanded
        // Off unless asked for: clear slips (a/an, a lowercase "I", a doubled word) are fixed before the text is typed.
        if settings.fixGrammarInDictation, level != .none, !snippetHit {
            HarperEngine.dialect = settings.spellingVariety
            let slipsFixed = GrammarChecker.autoFix(base, words: p.vocab.terms, onlyClear: true)
            if slipsFixed.fixed > 0 {
                log("take #\(id) grammar: \(slipsFixed.fixed) slip(s) fixed")
                base = slipsFixed.text
            }
        }
        let cmd = SpokenCommands.parse(base)
        var outcome = Outcome(text: cmd.text, raw: TextCleaner.raw(raw, quiet: quiet), mode: level.rawValue, app: app, pressEnter: cmd.pressEnter)
        outcome.secs = take.duration

        let style = p.style(for: app)
        let mode = ModeStore.tone(for: app, in: ModeStore.load())
        log("take #\(id) transcribed \(TextCleaner.wordCount(raw)) words, level \(level.rawValue), style \(style.rawValue)")
        guard level == .medium, !snippetHit, style != .plain || mode != nil, ai.cachedAvailable || ai.isAvailable() else {
            if level == .medium, !aiNoted, !ai.cachedAvailable, style != .plain || mode != nil, !snippetHit {
                aiNoted = true
                overlay.flash("Local AI not running · using rule-based clean-up (menu: AI status)", seconds: 3)
            }
            if level == .medium { outcome.mode = "light" }
            return done(id, outcome, file: take.url)
        }
        overlay.showTranscribing(label: "Tidying…")
        let started = Date()
        if let m = mode { log("take #\(id) mode \(m.name)") }
        ai.cleanup(cmd.text, style: style, tone: mode?.prompt, fallback: cmd.text) { text, usedAI in
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
            TakeStore.keep(file, engine: o.engine, heard: o.raw, final: o.text, mode: o.mode,
                           in: settings.takesDir, limit: settings.takesLimit, maxAgeDays: settings.takesDays)
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
            showUnsent(o, reason: "FreeFlow is not allowed to type into apps yet (System Settings › Privacy & Security › Accessibility). The words are copied: press ⌘V where you want them.", copied: true)
            return completion()
        }
        // The result belongs to the app you were in when you spoke. If you have since switched, do not type into the wrong window.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let app = o.app, let front = front, app != front, front != Bundle.main.bundleIdentifier {
            Inserter.copy(o.text)
            overlay.flash("You switched to \(appName(front)) · result copied, press ⌘V where you want it", seconds: 4)
            showUnsent(o, reason: "You switched to \(appName(front)) before it was ready. The words are copied: press ⌘V where you want them.", copied: true)
            return completion()
        }
        // Is there anywhere to type? A list, a button or the desktop in focus is not a text box: say so instead of pasting into nothing.
        let seen = Inserter.look()
        if case .notText = seen.landing {
            showUnsent(o, reason: "Nothing in \(appName(front ?? "")) was ready for typing. Click into a text box, then Paste again.", copied: false)
            return completion()
        }
        // A command replaces the selection, so no leading space; a dictation continues the sentence.
        let text = o.mode == "command" ? o.text : (Inserter.needsLeadingSpace() ? " " + o.text : o.text)
        Inserter.paste(text) {
            let landed = { (arrived: Bool) in
                guard arrived else {
                    self.showUnsent(o, reason: "Nothing arrived in \(self.appName(front ?? "")): the box did not take the paste. Click into it, then Paste again.", copied: false)
                    return completion()
                }
                // Look at the box before Return can clear it, so a fixed word can be learned.
                if o.mode != "command" { self.corrections.begin(pasted: text) }
                if o.pressEnter { Inserter.pressReturn() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: completion)
            }
            // Where the box can be read, check the words really went in (twice, half a second apart); elsewhere, trust the paste.
            if seen.landing == .editable, let el = seen.element, let before = seen.before {
                Inserter.confirmArrival(element: el, before: before, completion: landed)
            } else {
                landed(true)
            }
        }
    }

    /// The card with the words, when they did not reach a text box. The words are in the history either way.
    private func showUnsent(_ o: Outcome, reason: String, copied: Bool) {
        guard settings.unsentPopup else {
            if !copied { Inserter.copy(o.text); overlay.flash("Not typed · copied, press ⌘V where you want it", seconds: 4) }
            return
        }
        unsent.show(text: o.text, reason: reason, alreadyCopied: copied) { text in
            Inserter.paste(text)
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
            self.overlay.flash("FreeFlow is ready · \(self.settings.startPhrase), talk, \(self.settings.doubleTapToStart ? "double-tap" : "tap") again", seconds: 3)
        }
    }

    // MARK: - Menu bar

    /// The two dots and a smile from the Rhythme corner, drawn as a template image so the menu bar tints it.
    private func faceIcon(talking: Bool, flat: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            NSBezierPath(ovalIn: NSRect(x: 3.2, y: 8.4, width: 3.8, height: 3.8)).fill()
            NSBezierPath(ovalIn: NSRect(x: 15.0, y: 8.4, width: 3.8, height: 3.8)).fill()
            if talking {
                NSBezierPath(ovalIn: NSRect(x: 8.9, y: 2.6, width: 4.2, height: 5.8)).fill()
            } else {
                let m = NSBezierPath()
                m.lineWidth = 1.8
                m.lineCapStyle = .round
                if flat {
                    m.move(to: NSPoint(x: 8.8, y: 5.4))
                    m.line(to: NSPoint(x: 13.2, y: 5.4))
                } else {
                    m.move(to: NSPoint(x: 8.0, y: 7.4))
                    m.curve(to: NSPoint(x: 14.0, y: 7.4), controlPoint1: NSPoint(x: 9.2, y: 2.2), controlPoint2: NSPoint(x: 12.8, y: 2.2))
                }
                m.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let image: NSImage?
        if isRecording {
            image = mode == .command ? symbol("wand.and.stars") : faceIcon(talking: true, flat: false)
        } else if inFlight > 0 {
            image = faceIcon(talking: false, flat: true)
        } else if server.lastError != nil {
            image = symbol("mic.slash")
        } else {
            image = faceIcon(talking: false, flat: false)
        }
        image?.accessibilityDescription = "FreeFlow"
        button.image = image
        button.appearsDisabled = !server.isReady && !isRecording
    }

    private func symbol(_ name: String) -> NSImage? {
        let i = NSImage(systemSymbolName: name, accessibilityDescription: "FreeFlow")
        i?.isTemplate = true
        return i
    }

    /// The short line shown in the window and the menu: is it ready, and on which engine.
    private func statusLine() -> (text: String, ok: Bool) {
        if let error = server.lastError { return (error, false) }
        if !server.isReady { return ("Loading \(settings.engine.short)…", false) }
        return ("\(settings.engine.short) · offline, no word limit", true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        ai.refreshAvailability()
        let st = statusLine()
        menu.addItem(info(st.ok ? "Ready · \(settings.engine.short) · runs offline" : "⚠︎ \(st.text)"))
        menu.addItem(info("\(settings.startPhrase.prefix(1).uppercased() + settings.startPhrase.dropFirst()) to start, \(settings.doubleTapToStart ? "double-tap" : "tap") again to finish"))
        menu.addItem(.separator())

        menu.addItem(item("Open FreeFlow", #selector(openHome), symbol: "house"))
        if workday.running { menu.addItem(info("Workday notes are on (Workday page to switch off)")) }
        if detail.screenRunning { menu.addItem(info("Reading the text on my screen is on (Workday page)")) }
        if detail.typingRunning { menu.addItem(info("Noting how I type is on (Workday page)")) }
        if typing.running { menu.addItem(info("Learning from my typing is on (Settings > Data and Privacy)")) }
        if let now = meetings.now {
            menu.addItem(item("Stop meeting notes · \(now.app) \(MeetingFile.stamp(now.seconds))", #selector(stopMeetingNotes), symbol: "stop.circle"))
        } else {
            menu.addItem(item("Take meeting notes now", #selector(startMeetingNotes), symbol: "person.2"))
        }
        let copy = item("Copy last result", #selector(copyLast), symbol: "doc.on.doc")
        copy.isEnabled = lastOutcome != nil
        menu.addItem(copy)
        if let last = lastOutcome, last.mode == "medium", last.raw != last.text {
            menu.addItem(item("Undo AI edit · copy what I said", #selector(undoAI), symbol: "arrow.uturn.backward"))
        }
        if let last = lastOutcome, last.mode != "command", !last.text.isEmpty {
            menu.addItem(item("Correct my last dictation…", #selector(correctLast), symbol: "sparkles"))
        }
        menu.addItem(item("Fix spelling and grammar in selected text", #selector(fixSelection), symbol: "checkmark.seal"))
        let transforms = ModeStore.load().transforms
        do {
            let sub = NSMenu()
            for mode in RewriteMode.writing where mode != .fix {
                let it = item(mode.title, #selector(runRewriteItem(_:)), symbol: mode.symbol)
                it.representedObject = mode.rawValue
                sub.addItem(it)
            }
            // For people who build with AI: rough or spoken notes in, a prompt, plan, bug report or commit message out.
            sub.addItem(.separator())
            sub.addItem(info("For AI builders"))
            for mode in RewriteMode.builders {
                let it = item(mode.title, #selector(runRewriteItem(_:)), symbol: mode.symbol)
                it.representedObject = mode.rawValue
                sub.addItem(it)
            }
            if !transforms.isEmpty {
                sub.addItem(.separator())
                for t in transforms {
                    let it = item(t.name, #selector(runTransformItem(_:)))
                    it.representedObject = t.id
                    sub.addItem(it)
                }
            }
            sub.addItem(.separator())
            sub.addItem(info("Select text in any app first"))
            let top = NSMenuItem(title: "Rewrite selected text", action: nil, keyEquivalent: "")
            if let img = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil) { top.image = img }
            top.submenu = sub
            menu.addItem(top)
        }
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettingsPage), key: ",", symbol: "gearshape"))

        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            menu.addItem(item("Allow microphone…", #selector(openMicSettings), symbol: "mic"))
        }
        if !AXIsProcessTrusted() {
            menu.addItem(item("Allow typing into apps…", #selector(openAccessibilitySettings), symbol: "keyboard"))
        }
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

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        if let name = symbol, let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) { it.image = img }
        return it
    }

    // MARK: - Notes from files and summaries

    /// One piece of audio through the speech engine, for meeting notes and files. Uses the language and dictionary you set.
    private func transcribeForNotes(_ url: URL, _ done: @escaping (Result<String, Error>) -> Void) {
        let p = Personalization.load()
        let lang = settings.language.rawValue
        let prompt = lang == Language.mixed.rawValue ? p.vocab.promptMixed : p.vocab.prompt
        server.transcribe(url, language: lang, prompt: prompt, completion: done)
    }

    private func startFile(_ url: URL) {
        files.start(url) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let note):
                self.overlay.flash("Written down · \(note.deletingPathExtension().lastPathComponent)", seconds: 4)
                self.summarize(note, quiet: true)
            case .failure(let e):
                self.log("file: \(e.localizedDescription)")
                self.overlay.flash(e.localizedDescription, seconds: 6)
            }
        }
    }

    /// Adds a summary to a note. When it runs by itself (`quiet`), a missing AI or a very short note is not worth a message.
    private func summarize(_ url: URL, quiet: Bool) {
        summarizer.summarize(url) { [weak self] reason in
            guard let self = self else { return }
            if let r = reason {
                if !quiet { self.overlay.flash("No summary · \(r)", seconds: 4) }
            } else {
                self.overlay.flash("Summary added to the notes", seconds: 3)
            }
        }
    }

    // MARK: - The window

    @objc private func runTransformItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let t = ModeStore.load().transforms.first(where: { $0.id == id }) else { return }
        runTransform(t)
    }

    /// Puts `text` in place of the selection, or copies it when the app in front cannot be typed into.
    private func replaceSelection(_ text: String, focus: Inserter.Focus, label: String) {
        if focus.editable, AXIsProcessTrusted() {
            Inserter.paste(text) { self.overlay.flash("\(label) · done", seconds: 1.5) }
        } else {
            Inserter.copy(text)
            self.overlay.flash("\(label) · copied, press ⌘V", seconds: 3)
        }
    }

    /// Instant and offline: the first suggestion for every spelling, grammar and punctuation mistake in the selection.
    @objc private func fixSelection() {
        Inserter.readFocus { [weak self] focus in
            guard let self = self else { return }
            guard !focus.selection.isEmpty else { return self.overlay.flash("Select some text first", seconds: 3) }
            HarperEngine.dialect = self.settings.spellingVariety
            let result = GrammarChecker.autoFix(focus.selection, words: Personalization.load().vocab.terms)
            guard result.fixed > 0, result.text != focus.selection else { return self.overlay.flash("Nothing to fix", seconds: 2) }
            self.log("fix selection: \(result.fixed) fixes in \(TextCleaner.wordCount(focus.selection)) words")
            self.replaceSelection(result.text, focus: focus, label: result.fixed == 1 ? "1 fix" : "\(result.fixed) fixes")
        }
    }

    @objc private func runRewriteItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = RewriteMode(rawValue: raw) else { return }
        runRewrite(mode)
    }

    /// One of the built-in rewrites (shorter, friendlier ...) of the selection, refused if it changed a number or one of your words.
    private func runRewrite(_ mode: RewriteMode) {
        guard ai.cachedAvailable || ai.isAvailable() else { return overlay.flash("Rewrites need the local AI (start Ollama)", seconds: 3) }
        Inserter.readFocus { [weak self] focus in
            guard let self = self else { return }
            guard !focus.selection.isEmpty else { return self.overlay.flash("Select some text first, then choose \(mode.title)", seconds: 3) }
            self.overlay.showTranscribing(label: "\(mode.title)…")
            self.ai.rewrite(focus.selection, mode: mode, terms: Personalization.load().vocab.terms) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text) where !text.isEmpty:
                        self.log("rewrite \(mode.rawValue): \(TextCleaner.wordCount(focus.selection)) words in, \(TextCleaner.wordCount(text)) out")
                        self.replaceSelection(text, focus: focus, label: mode.title)
                    case .success:
                        self.overlay.flash("The AI returned nothing", seconds: 2)
                    case .failure(let e):
                        self.overlay.flash("\(mode.title) failed · \(e.localizedDescription)", seconds: 4)
                    }
                }
            }
        }
    }

    /// Applies a saved prompt to the text selected in the app in front, and puts the result in its place.
    private func runTransform(_ t: Transform) {
        guard ai.cachedAvailable || ai.isAvailable() else { return overlay.flash("Rewrites need the local AI (start Ollama)", seconds: 3) }
        Inserter.readFocus { [weak self] focus in
            guard let self = self else { return }
            guard !focus.selection.isEmpty else { return self.overlay.flash("Select some text first, then choose \(t.name)", seconds: 3) }
            self.overlay.showTranscribing(label: "\(t.name)…")
            self.ai.command(t.prompt, selection: focus.selection, context: "") { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text) where !text.isEmpty:
                        self.log("transform \(t.name): \(TextCleaner.wordCount(focus.selection)) words in, \(TextCleaner.wordCount(text)) out")
                        if focus.editable, AXIsProcessTrusted() {
                            Inserter.paste(text) { self.overlay.flash("\(t.name) · done", seconds: 1.5) }
                        } else {
                            Inserter.copy(text)
                            self.overlay.flash("\(t.name) · copied, press ⌘V", seconds: 3)
                        }
                    case .success:
                        self.overlay.flash("The AI returned nothing", seconds: 2)
                    case .failure(let e):
                        self.overlay.flash("\(t.name) failed · \(e.localizedDescription)", seconds: 3)
                    }
                }
            }
        }
    }

    @objc private func openHome() { openStudio(.home) }
    @objc private func startMeetingNotes() { meetings.startNow() }
    @objc private func stopMeetingNotes() { meetings.stop() }
    @objc private func openSettingsPage() { openStudio(nil); studio?.model.openSettings() }

    private func openStudio(_ page: StudioModel.Page?) {
        ai.refreshAvailability()
        if studio == nil { studio = StudioWindowController(bridge: bridge) }
        studio?.show(page: page)
        settings.seenHome = true
    }

    /// Lets the window change settings and ask for things without knowing how the app works inside.
    private func wireBridge() {
        bridge.typingChanged = { [weak self] in
            guard let self = self else { return }
            if self.settings.learnFromTyping { self.typing.start(); self.typing.keepEarlierFixes() } else { self.typing.stop() }
        }
        bridge.workdayChanged = { [weak self] in
            guard let self = self else { return }
            if self.settings.workdayOn { self.workday.start() } else { self.workday.stop() }
        }
        bridge.detailChanged = { [weak self] in self?.detail.apply() }
        bridge.dockChanged = { [weak self] in
            guard let self = self else { return }
            // A Dock icon while the window is open, or all the time when asked for.
            NSApp.setActivationPolicy(self.settings.showInDock || NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } ? .regular : .accessory)
        }
        bridge.hotkeysChanged = { [weak self] in self?.installHotkeys() }
        bridge.engineChosen = { [weak self] e in self?.chooseEngine(e) }
        bridge.cleanupChanged = { [weak self] in
            guard let self = self else { return }
            self.aiNoted = false
            if self.settings.cleanupLevel == .medium { self.ai.warm() }
        }
        bridge.commandModeChanged = { [weak self] in
            guard let self = self else { return }
            self.installHotkeys()
            if self.settings.commandMode { self.ai.warm() }
        }
        bridge.idleBarChanged = { [weak self] in self?.overlay.idleBarChanged() }
        bridge.toggleLogin = { [weak self] in self?.toggleLogin() }
        bridge.correctLast = { [weak self] in self?.correctLast() }
        bridge.forgetLearned = { [weak self] in self?.forgetLearned() }
        bridge.chooseTeamFolder = { [weak self] in self?.chooseTeamFolder() }
        bridge.clearTeamFolder = { [weak self] in self?.clearTeamFolder() }
        bridge.copyMCP = { [weak self] in self?.copyMCPCommand() }
        bridge.copyMCPConfig = { [weak self] in self?.copyMCPConfig() }
        bridge.allowMic = { [weak self] in self?.openMicSettings() }
        bridge.allowAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        bridge.showTakes = { [weak self] in self?.showTakes() }
        bridge.deleteTakes = { [weak self] in self?.deleteTakes() }
        bridge.editStyles = { [weak self] in self?.editStyles() }
        bridge.startMeeting = { [weak self] in self?.meetings.startNow() }
        bridge.stopMeeting = { [weak self] in self?.meetings.stop() }
        bridge.openMeetings = {
            try? FileManager.default.createDirectory(at: Paths.meetings, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Paths.meetings)
        }
        bridge.allowScreenAudio = {
            _ = CGRequestScreenCaptureAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        bridge.meetingNow = { [weak self] in self?.meetings.now }
        bridge.transcribeFile = { [weak self] url in self?.startFile(url) }
        bridge.fileJob = { [weak self] in self?.files.job }
        bridge.summarizeNote = { [weak self] url in self?.summarize(url, quiet: false) }
        bridge.summarizing = { [weak self] in self?.summarizer.running ?? [] }
        bridge.status = { [weak self] in self?.statusLine() ?? ("Starting…", false) }
        bridge.aiReady = { [weak self] in self?.ai.cachedAvailable ?? false }
        bridge.installingQwen = { [weak self] in self?.installingQwen ?? false }
    }

    /// A menu-bar app has no menu bar of its own; this gives its window the usual ⌘C, ⌘V, ⌘W and ⌘Q.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettingsPage), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FreeFlow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quitItem = NSMenuItem(title: "Quit FreeFlow", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    /// Switches the speech engine; picking Qwen the first time installs it.
    private func chooseEngine(_ e: SpeechEngine) {
        guard e != settings.engine || server.lastError != nil else { return }
        if e == .qwen, !WhisperServer.qwenInstalled {
            return installQwen()
        }
        settings.engine = e
        server.switchTo(e)
        overlay.flash("Speech engine: \(e.short)", seconds: 2)
    }

    @objc private func copyLast() {
        if let t = lastOutcome?.text { Inserter.copy(t) }
    }

    @objc private func undoAI() {
        guard let o = lastOutcome else { return }
        Inserter.copy(o.raw)
        overlay.flash("Original words copied · paste with ⌘V", seconds: 3)
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

    @objc private func showTakes() {
        let dir = settings.takesDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func deleteTakes() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Delete all saved recordings?"
        let dir = settings.takesDir
        alert.informativeText = "This removes the audio and the text saved with it from \(dir.path). Other files in that folder are left alone. It can't be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let n = TakeStore.deleteAll(in: dir)
        overlay.flash("Saved recordings deleted (\(n))", seconds: 2)
    }

    private func announceLearned(_ pairs: [Learning.Pair]) {
        let shown = pairs.prefix(2).map { "\($0.wrong) → \($0.right)" }.joined(separator: ", ")
        overlay.flash("Learned: \(shown)\(pairs.count > 2 ? " +\(pairs.count - 2) more" : "")", seconds: 3)
        log("learned \(pairs.count) fix(es) from a correction")
    }

    /// For apps that do not let FreeFlow read the text box, or a fix made later: edit the last dictation here.
    @objc private func correctLast() {
        guard let last = lastOutcome, !last.text.isEmpty, last.mode != "command" else {
            overlay.flash("Nothing dictated yet to correct", seconds: 2)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Correct my last dictation"
        alert.informativeText = "Fix the words that were wrong. FreeFlow remembers them next time. Change a word or two, not the whole sentence."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 110))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.string = last.text
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Learn")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tv
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Saying "this is wrong" in so many words counts double, so a swap can start right away.
        let pairs = Learning.learn(Learning.pairs(original: last.text, edited: tv.string), weight: 2)
        if pairs.isEmpty {
            overlay.flash("Nothing to learn from that change", seconds: 2.5)
        } else {
            announceLearned(pairs)
        }
    }

    @objc private func forgetLearned() {
        let f = LearnedFile.load()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget everything FreeFlow learned?"
        alert.informativeText = "This removes \(f.fixes.count) fixes and \(f.terms.count) words learned from your corrections. Your own dictionary is not touched."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            try? FileManager.default.removeItem(at: Paths.learned)
        }
    }

    @objc private func editStyles() {
        _ = Personalization.load()
        NSWorkspace.shared.open(Paths.styles)
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

    @objc private func clearTeamFolder() {
        settings.teamFolder = nil
        settings.shareUsage = false
    }

    @objc private func copyMCPCommand() {
        let script = (Bundle.main.resourcePath ?? "/Applications/FreeFlow.app/Contents/Resources") + "/freeflow-mcp.py"
        settings.mcpCopied = true
        Inserter.copy("claude mcp add --scope user freeflow -- /usr/bin/env python3 \"\(script)\"")
        overlay.flash("Command copied · paste it in a terminal, then Claude can search your dictations", seconds: 4)
    }

    /// The same server as a JSON entry, for Claude Desktop, Cursor and other apps that read an mcpServers list.
    private func copyMCPConfig() {
        let script = (Bundle.main.resourcePath ?? "/Applications/FreeFlow.app/Contents/Resources") + "/freeflow-mcp.py"
        let entry: [String: Any] = ["mcpServers": ["freeflow": ["command": "/usr/bin/env", "args": ["python3", script]]]]
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            Inserter.copy(text)
            overlay.flash("MCP config copied · add it to your app's MCP settings", seconds: 3.5)
        }
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
        var record: [String: Any] = ["t": iso, "app": o.app ?? "", "mode": o.mode, "raw": o.raw, "text": o.text]
        if o.secs > 0 { record["secs"] = (o.secs * 10).rounded() / 10 }
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
