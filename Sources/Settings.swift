import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/FreeFlow", isDirectory: true)
    static let model = support.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
    static let dictionary = support.appendingPathComponent("dictionary.txt")
    static let snippets = support.appendingPathComponent("snippets.txt")
    static let styles = support.appendingPathComponent("styles.txt")
    static let history = support.appendingPathComponent("history.txt")
    static let historyJSON = support.appendingPathComponent("history.jsonl")
    static let logs = home.appendingPathComponent("Library/Logs/FreeFlow", isDirectory: true)
}

enum TalkKey: String, CaseIterable {
    case rightOption, fn, rightCommand, rightControl

    var title: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .fn: return "Fn / Globe"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        }
    }

    var short: String {
        switch self {
        case .rightOption: return "right ⌥"
        case .fn: return "Fn"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .fn: return 63
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    /// Device-specific modifier bit, so the left-hand key never triggers dictation.
    var deviceMask: UInt {
        switch self {
        case .rightOption: return 0x40
        case .fn: return 0x800000
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        }
    }
}

enum Language: String, CaseIterable {
    case english = "en", auto = "auto", chinese = "zh", malay = "ms", indonesian = "id", tamil = "ta", hindi = "hi",
         japanese = "ja", korean = "ko", spanish = "es", french = "fr", german = "de", vietnamese = "vi", thai = "th"

    var title: String {
        switch self {
        case .english: return "English"
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

    var talkKey: TalkKey {
        get { TalkKey(rawValue: d.string(forKey: "talkKey") ?? "") ?? .rightOption }
        set { d.set(newValue.rawValue, forKey: "talkKey") }
    }

    /// Quick tap starts hands-free dictation, next tap ends it. Holding still works as push-to-talk.
    var tapToToggle: Bool {
        get { d.object(forKey: "tapToToggle") as? Bool ?? true }
        set { d.set(newValue, forKey: "tapToToggle") }
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
            var byApp = d.dictionary(forKey: "wordsByApp") as? [String: Int] ?? [:]
            byApp[app, default: 0] += n
            d.set(byApp, forKey: "wordsByApp")
        }
    }

    func topApps(_ n: Int) -> [(String, Int)] {
        let byApp = d.dictionary(forKey: "wordsByApp") as? [String: Int] ?? [:]
        return byApp.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
