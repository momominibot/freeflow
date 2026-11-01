import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/FreeFlow", isDirectory: true)
    static let model = support.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin")
    static let dictionary = support.appendingPathComponent("dictionary.txt")
    static let history = support.appendingPathComponent("history.txt")
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
    case english = "en", auto = "auto", chinese = "zh", malay = "ms"

    var title: String {
        switch self {
        case .english: return "English"
        case .auto: return "Auto-detect"
        case .chinese: return "Chinese (中文)"
        case .malay: return "Malay"
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

    var language: Language {
        get { Language(rawValue: d.string(forKey: "language") ?? "") ?? .english }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    var removeFillers: Bool {
        get { d.object(forKey: "removeFillers") as? Bool ?? true }
        set { d.set(newValue, forKey: "removeFillers") }
    }

    var sounds: Bool {
        get { d.object(forKey: "sounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "sounds") }
    }

    var debugTriggers: Bool { d.bool(forKey: "debugTriggers") }

    var wordsTotal: Int { d.integer(forKey: "wordsTotal") }

    var wordsToday: Int {
        d.string(forKey: "wordsDay") == Self.today ? d.integer(forKey: "wordsToday") : 0
    }

    func addWords(_ n: Int) {
        let today = wordsToday
        d.set(Self.today, forKey: "wordsDay")
        d.set(today + n, forKey: "wordsToday")
        d.set(wordsTotal + n, forKey: "wordsTotal")
    }

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
