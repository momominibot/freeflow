import Foundation
import AppKit

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/FreeFlow", isDirectory: true)
    static let model = support.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
    static let dictionary = support.appendingPathComponent("dictionary.txt")
    static let learned = support.appendingPathComponent("learned.txt")
    static let snippets = support.appendingPathComponent("snippets.txt")
    static let styles = support.appendingPathComponent("styles.txt")
    static let modes = support.appendingPathComponent("modes.json")
    static let scratchpad = support.appendingPathComponent("scratchpad", isDirectory: true)
    static let history = support.appendingPathComponent("history.txt")
    static let historyJSON = support.appendingPathComponent("history.jsonl")
    static let logs = home.appendingPathComponent("Library/Logs/FreeFlow", isDirectory: true)
    static let takes = support.appendingPathComponent("takes", isDirectory: true)
    static let meetings = support.appendingPathComponent("meetings", isDirectory: true)
    static let workday = support.appendingPathComponent("workday", isDirectory: true)
    static let qwenDir = support.appendingPathComponent("engines/qwen", isDirectory: true)
    static let qwenPython = qwenDir.appendingPathComponent("venv/bin/python")
}

/// Which speech-to-text engine turns your voice into words. Both run on this Mac.
enum SpeechEngine: String, CaseIterable {
    case whisper, qwen

    var title: String {
        switch self {
        case .whisper: return "Whisper large-v3-turbo (default)"
        case .qwen: return "Qwen3-ASR 1.7B (more accurate, test it)"
        }
    }

    var short: String {
        switch self {
        case .whisper: return "Whisper"
        case .qwen: return "Qwen3-ASR"
        }
    }
}

/// Light, dark royal purple, or whatever the Mac is set to.
enum AppearanceChoice: String, CaseIterable {
    case system, light, dark

    var chipTitle: String {
        switch self {
        case .system: return "Match my Mac"
        case .light: return "Light"
        case .dark: return "Dark purple"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Puts the saved choice on every window the app has.
    static func applySaved() { NSApp.appearance = Settings.shared.appearance.nsAppearance }
}

enum TalkKey: String, CaseIterable {
    case rightOption, fn, leftControl, rightCommand, rightControl

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .fn: return "Fn / Globe"
        case .leftControl: return "Left Control (⌃)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }

    var short: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .fn: return "Fn"
        case .leftControl: return "left ⌃"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .fn: return 63
        case .leftControl: return 59
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    /// Device-specific modifier bit, so the left-hand key never triggers dictation.
    var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .fn: return 0x800000
        case .leftControl: return 0x1
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        }
    }
}

enum Language: String, CaseIterable {
    case english = "en", mixed = "zh-en", auto = "auto", chinese = "zh", malay = "ms", indonesian = "id", tamil = "ta", hindi = "hi",
         japanese = "ja", korean = "ko", spanish = "es", french = "fr", german = "de", vietnamese = "vi", thai = "th"

    var title: String {
        switch self {
        case .english: return "English"
        case .mixed: return "English + Chinese (mixed)"
        case .auto: return "Auto-detect"
        case .chinese: return "Chinese (中文)"
        case .malay: return "Malay"
        case .indonesian: return "Indonesian"
        case .tamil: return "Tamil (தமிழ்)"
        case .hindi: return "Hindi (हिन्दी)"
        case .japanese: return "Japanese (日本語)"
        case .korean: return "Korean (한국어)"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .vietnamese: return "Vietnamese"
        case .thai: return "Thai"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Workday notes: which app and window you are in, kept on this Mac for 14 days. Off until you switch it on.
    var workdayOn: Bool {
        get { d.bool(forKey: "workdayOn") }
        set { d.set(newValue, forKey: "workdayOn") }
    }

    /// Seconds between looks at the front window (5 by default).
    var workdayInterval: TimeInterval {
        get { let v = d.double(forKey: "workdayInterval"); return v >= 1 ? min(v, 60) : 5 }
        set { d.set(newValue, forKey: "workdayInterval") }
    }

    /// Deeper workday notes, each off until switched on (see Detail.swift): the words on the front window, how you type, small pictures.
    var screenTextOn: Bool {
        get { d.bool(forKey: "screenTextOn") }
        set { d.set(newValue, forKey: "screenTextOn") }
    }
    var typingDetailOn: Bool {
        get { d.bool(forKey: "typingDetailOn") }
        set { d.set(newValue, forKey: "typingDetailOn") }
    }
    var keepPictures: Bool {
        get { d.bool(forKey: "keepPictures") }
        set { d.set(newValue, forKey: "keepPictures") }
    }
    /// Seconds between reads of the front window's text (2 minutes by default).
    var detailInterval: TimeInterval {
        get { let v = d.double(forKey: "detailInterval"); return v >= 1 ? min(v, 900) : 120 }
        set { d.set(newValue, forKey: "detailInterval") }
    }

    var appearance: AppearanceChoice {
        get { AppearanceChoice(rawValue: d.string(forKey: "appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "appearance") }
    }

    var talkKey: TalkKey {
        get { TalkKey(rawValue: d.string(forKey: "talkKey") ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "talkKey") }
    }

    /// Quick tap starts hands-free dictation, next tap ends it. Holding still works as push-to-talk.
    var tapToToggle: Bool {
        get { d.object(forKey: "tapToToggle") as? Bool ?? true }
        set { d.set(newValue, forKey: "tapToToggle") }
    }

    /// A Dock icon all the time, not only while the window is open. Off by default (FreeFlow lives in the menu bar).
    var showInDock: Bool {
        get { d.bool(forKey: "showInDock") }
        set { d.set(newValue, forKey: "showInDock") }
    }

    /// Start hands-free with two quick taps of the talk key instead of one (so a single accidental press does nothing).
    var doubleTapToStart: Bool {
        get { d.bool(forKey: "doubleTapToStart") }
        set { d.set(newValue, forKey: "doubleTapToStart") }
    }

    /// When a dictation cannot be typed into a text box, show a card with the words and a Copy button. On unless switched off.
    var unsentPopup: Bool {
        get { d.object(forKey: "unsentPopup") as? Bool ?? true }
        set { d.set(newValue, forKey: "unsentPopup") }
    }

    /// How to start, in words: "tap Fn" or "double-tap Fn".
    var startPhrase: String { doubleTapToStart ? "double-tap \(talkKey.short)" : "tap \(talkKey.short)" }

    /// How to finish a hands-free dictation: in double-tap mode it takes two quick taps too, so one stray press cannot end it.
    func finishPhrase(_ key: TalkKey) -> String { doubleTapToStart ? "double-tap \(key.short)" : "tap \(key.short)" }

    var engine: SpeechEngine {
        get { SpeechEngine(rawValue: d.string(forKey: "engine") ?? "") ?? .whisper }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }

    /// Opt-in: keep each recording and what was heard, on this Mac only, to compare engines.
    var keepTakes: Bool {
        get { d.bool(forKey: "keepTakes") }
        set { d.set(newValue, forKey: "keepTakes") }
    }

    /// Which Hermes agent gets the briefs: Levi builds scripts and scheduled tasks, Eren hands it to whoever fits. Both run on this
    /// Mac's own model, so nothing in the notes leaves it.
    static let hermesAgents: [(id: String, name: String)] = [("levi", "Levi"), ("eren", "Eren")]
    var hermesAgent: String {
        get { let v = d.string(forKey: "hermesAgent") ?? "levi"; return Settings.hermesAgents.contains { $0.id == v } ? v : "levi" }
        set { d.set(newValue, forKey: "hermesAgent") }
    }

    /// How many recordings to keep (the newest), how many days to keep them (0 = no age limit), and where (empty = FreeFlow's own folder).
    static let takesLimitChoices = [25, 100, 500, 2000]
    static let takesDaysChoices = [0, 7, 30, 90]
    var takesLimit: Int {
        get { let v = d.integer(forKey: "takesLimit"); return v > 0 ? v : 100 }
        set { d.set(newValue, forKey: "takesLimit") }
    }
    var takesDays: Int {
        get { max(0, d.integer(forKey: "takesDays")) }
        set { d.set(newValue, forKey: "takesDays") }
    }
    var takesFolderPath: String {
        get { d.string(forKey: "takesFolder") ?? "" }
        set { if newValue.isEmpty { d.removeObject(forKey: "takesFolder") } else { d.set(newValue, forKey: "takesFolder") } }
    }
    var takesDir: URL {
        let p = (takesFolderPath as NSString).expandingTildeInPath
        return p.isEmpty ? Paths.takes : URL(fileURLWithPath: p, isDirectory: true)
    }

    /// Learn words from the corrections you make to text FreeFlow typed. On by default; the pairs stay in learned.txt.
    /// Learn from fixes made in your own typing, not only in text FreeFlow typed. Off until you switch it on.
    var learnFromTyping: Bool {
        get { d.bool(forKey: "learnFromTyping") }
        set { d.set(newValue, forKey: "learnFromTyping") }
    }

    /// Keep a fix of your own typing the first time you make it, when it is clearly a spelling fix. On by default; off means
    /// every fix must be seen twice.
    var learnTypingAtOnce: Bool {
        get { d.object(forKey: "learnTypingAtOnce") as? Bool ?? true }
        set { d.set(newValue, forKey: "learnTypingAtOnce") }
    }

    /// Fixes seen once so far (the same fix must be seen twice before it is kept): a spelling and how many times.
    var typingSeenRaw: [String: Any] {
        get { d.dictionary(forKey: "typingSeen") ?? [:] }
        set { d.set(newValue, forKey: "typingSeen") }
    }

    /// How many fixes were learned each day, to show whether you need fewer over time.
    var fixesByDay: [String: Int] { Settings.counts(d.dictionary(forKey: "fixesByDay") ?? [:]) }
    func addFixes(_ n: Int) {
        guard n > 0 else { return }
        var m = fixesByDay
        m[Self.today, default: 0] += n
        // keep about two months
        if m.count > 70 { for k in m.keys.sorted().prefix(m.count - 70) { m[k] = nil } }
        d.set(m, forKey: "fixesByDay")
    }

    var learnFromFixes: Bool {
        get { d.object(forKey: "learnFromFixes") as? Bool ?? true }
        set { d.set(newValue, forKey: "learnFromFixes") }
    }

    /// Command Mode key. Held alone, like the talk key, never a chord.
    var commandKey: TalkKey {
        get { TalkKey(rawValue: d.string(forKey: "commandKey") ?? "") ?? .rightControl }
        set { d.set(newValue.rawValue, forKey: "commandKey") }
    }

    var commandMode: Bool {
        get { d.object(forKey: "commandMode") as? Bool ?? true }
        set { d.set(newValue, forKey: "commandMode") }
    }

    var language: Language {
        get { Language(rawValue: d.string(forKey: "language") ?? "") ?? .english }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    var cleanupLevel: CleanupLevel {
        get { CleanupLevel(rawValue: d.string(forKey: "cleanupLevel") ?? "") ?? .medium }
        set { d.set(newValue.rawValue, forKey: "cleanupLevel") }
    }

    var aiModel: String {
        get { d.string(forKey: "aiModel") ?? "qwen3.5:9b" }
        set { d.set(newValue, forKey: "aiModel") }
    }

    var removeFillers: Bool {
        get { d.object(forKey: "removeFillers") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeFillers") }
    }

    var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }

    var teamFolder: String? {
        get { d.string(forKey: "teamFolder") }
        set { d.set(newValue, forKey: "teamFolder") }
    }

    var teamFolderURL: URL? {
        guard let p = teamFolder, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    var shareUsage: Bool {
        get { d.bool(forKey: "shareUsage") }
        set { d.set(newValue, forKey: "shareUsage") }
    }

    /// What FreeFlow does when it notices you are in a call: nothing, ask, or start taking notes after a short countdown.
    var meetingMode: MeetingMode {
        get { MeetingMode(rawValue: d.string(forKey: "meetingMode") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "meetingMode") }
    }

    /// Also write down the other people (what the Mac plays). Needs Screen & System Audio Recording.
    var meetingOthers: Bool {
        get { d.object(forKey: "meetingOthers") as? Bool ?? true }
        set { d.set(newValue, forKey: "meetingOthers") }
    }

    /// Seconds before an automatic start, so you can say no. Wispr uses 10.
    var meetingCountdown: Int {
        get { max(3, min(60, d.object(forKey: "meetingCountdown") as? Int ?? 10)) }
        set { d.set(newValue, forKey: "meetingCountdown") }
    }

    /// Length of each piece sent to the speech engine. 30 seconds; shorter only for checks.
    var meetingChunkSeconds: Double {
        let v = d.double(forKey: "meetingChunkSeconds")
        return v >= 5 ? v : 30
    }

    /// The small resting bar at the bottom of the screen, like Wispr's. On by default.
    var showIdleBar: Bool {
        get { d.object(forKey: "showIdleBar") as? Bool ?? true }
        set { d.set(newValue, forKey: "showIdleBar") }
    }

    /// Set once the command that lets Claude Code search your dictations has been copied (a step in the setup list).
    var mcpCopied: Bool {
        get { d.bool(forKey: "mcpCopied") }
        set { d.set(newValue, forKey: "mcpCopied") }
    }

    /// Your name, for the greeting and the team list. Starts from the Mac's full name.
    var firstName: String {
        get {
            if let v = d.string(forKey: "firstName") { return v }
            return Settings.guessFirstName(full: NSFullUserName(), account: NSUserName())
        }
        set { d.set(newValue, forKey: "firstName") }
    }

    var lastName: String {
        get {
            if let v = d.string(forKey: "lastName") { return v }
            let parts = NSFullUserName().split(separator: " ")
            return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
        }
        set { d.set(newValue, forKey: "lastName") }
    }

    /// Tips and banners the user has closed.
    func isDismissed(_ key: String) -> Bool { (d.stringArray(forKey: "dismissed") ?? []).contains(key) }
    func dismiss(_ key: String) { d.set(Array(Set((d.stringArray(forKey: "dismissed") ?? []) + [key])), forKey: "dismissed") }

    /// Back to zero, after the history is deleted.
    func resetUsage() {
        for k in ["wordsTotal", "wordsToday", "wordsDay", "wordsByApp"] { d.removeObject(forKey: k) }
    }

    /// The window opens by itself the first time, then only when you ask for it.
    var seenHome: Bool {
        get { d.bool(forKey: "seenHome") }
        set { d.set(newValue, forKey: "seenHome") }
    }

    var debugTriggers: Bool { d.bool(forKey: "debugTriggers") }

    // MARK: - Usage

    var wordsTotal: Int { d.integer(forKey: "wordsTotal") }

    var wordsToday: Int {
        d.string(forKey: "wordsDay") == Self.today ? d.integer(forKey: "wordsToday") : 0
    }

    func addWords(_ n: Int, app: String?) {
        let today = wordsToday
        d.set(Self.today, forKey: "wordsDay")
        d.set(today + n, forKey: "wordsToday")
        d.set(wordsTotal + n, forKey: "wordsTotal")
        if let app = app, !app.isEmpty {
            var byApp = wordsByApp
            byApp[app, default: 0] += n
            d.set(byApp, forKey: "wordsByApp")
        }
    }

    /// The first word of the Mac's full name, unless that name is only the account name typed in lower case ("michiyomimi"),
    /// which is not a name to greet someone by.
    static func guessFirstName(full: String, account: String) -> String {
        let name = full.trimmingCharacters(in: .whitespaces)
        guard let first = name.split(separator: " ").first.map(String.init), !first.isEmpty else { return "" }
        if name == name.lowercased(), name.lowercased() == account.lowercased() { return "" }
        return first
    }

    /// Words per app. A count that was saved as text ("33") still counts, so one odd entry never wipes the rest.
    var wordsByApp: [String: Int] { Settings.counts(d.dictionary(forKey: "wordsByApp") ?? [:]) }

    static func counts(_ raw: [String: Any]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in raw {
            if let n = v as? Int { out[k] = n }
            else if let s = v as? String, let n = Int(s.trimmingCharacters(in: .whitespaces)) { out[k] = n }
        }
        return out
    }

    func topApps(_ n: Int) -> [(String, Int)] {
        let byApp = wordsByApp
        return byApp.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}


/// Opt-in saved recordings, for comparing speech engines on your own voice. Local only.
enum TakeStore {
    /// A file FreeFlow wrote: 20261109-185331-01-whisper.wav or .json. Anything else in the folder is never touched.
    static func isTakeFile(_ name: String) -> Bool {
        name.range(of: #"^\d{8}-\d{6}-\d{2}-[A-Za-z0-9_.-]+\.(wav|json)$"#, options: .regularExpression) != nil
    }

    /// Removes every recording FreeFlow wrote in the folder (the folder itself and other files stay). The number removed.
    @discardableResult
    static func deleteAll(in dir: URL) -> Int {
        let fm = FileManager.default
        var n = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where isTakeFile(name) {
            if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil, name.hasSuffix(".wav") { n += 1 }
        }
        return n
    }

    /// Copies a finished take and what each stage produced next to it, keeping the newest `limit`, and nothing older than
    /// `maxAgeDays` days when that is above 0.
    static func keep(_ file: URL, engine: String, heard: String, final: String, mode: String,
                     in dir: URL = Paths.takes, limit: Int = 100, maxAgeDays: Int = 0, now: Date = Date()) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        // time, then a counter, then the engine: names sort in the order the takes were made
        var n = 1
        var stem = f.string(from: now) + String(format: "-%02d-", n) + engine
        while fm.fileExists(atPath: dir.appendingPathComponent(stem + ".wav").path) {
            n += 1
            stem = f.string(from: now) + String(format: "-%02d-", n) + engine
        }
        try? fm.copyItem(at: file, to: dir.appendingPathComponent(stem + ".wav"))
        let meta: [String: Any] = ["engine": engine, "heard": heard, "final": final, "mode": mode]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent(stem + ".json"))
        }
        let wavs = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { isTakeFile($0) && $0.hasSuffix(".wav") }.sorted()
        func drop(_ wav: String) {
            let base = (wav as NSString).deletingPathExtension
            try? fm.removeItem(at: dir.appendingPathComponent(base + ".wav"))
            try? fm.removeItem(at: dir.appendingPathComponent(base + ".json"))
        }
        for old in wavs.dropLast(max(1, limit)) { drop(old) }
        if maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
            for name in wavs where (f.date(from: String(name.prefix(15))) ?? .distantFuture) < cutoff { drop(name) }
        }
    }
}
