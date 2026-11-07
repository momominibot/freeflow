import AppKit
import Foundation

/// A spoken cue that expands to saved text, like Wispr Flow's Snippets.
struct Snippet {
    let cue: String
    let expansion: String
    let regex: NSRegularExpression

    init?(cue: String, expansion: String) {
        let words = cue.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !words.isEmpty, !expansion.isEmpty else { return nil }
        let pattern = "(?i)(?<![\\p{L}\\p{N}])" + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[^\\p{L}\\p{N}]+") + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.cue = cue
        self.expansion = expansion
        self.regex = re
    }

    static let template = """
    # FreeFlow snippets
    # Say the cue, get the expansion.  cue => expansion
    # Use \\n for a new line inside the expansion. Lines starting with # are ignored.
    # Cues are matched on whole words, ignoring case and punctuation.

    my email address => hello@ranklore.ai
    my calendar link => Feel free to book a time here: https://cal.com/your-link

    """

    /// Parses `cue => expansion` lines. Later duplicates of a cue are ignored, so the first list passed wins.
    static func parse(_ text: String, into list: inout [Snippet]) {
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let arrow = line.range(of: "=>") else { continue }
            let cue = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let exp = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
            guard cue.count <= 60, exp.count <= 4000 else { continue }
            guard !list.contains(where: { $0.cue.caseInsensitiveCompare(cue) == .orderedSame }) else { continue }
            if let s = Snippet(cue: cue, expansion: exp) { list.append(s) }
        }
    }

    /// Expands every cue found in the text. A dictation that is only a cue becomes the expansion exactly.
    static func apply(_ snippets: [Snippet], to text: String) -> String {
        var t = text
        for s in snippets {
            let whole = NSRange(t.startIndex..., in: t)
            guard let m = s.regex.firstMatch(in: t, range: whole) else { continue }
            let rest = t.replacingCharacters(in: Range(m.range, in: t)!, with: "")
            if rest.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                return s.expansion
            }
            t = s.regex.stringByReplacingMatches(in: t, range: whole, withTemplate: NSRegularExpression.escapedTemplate(for: s.expansion))
        }
        return t
    }
}

/// Everything the dictation pipeline needs from disk: personal files first, then the team folder.
/// Personal entries win when both define the same word, cue or app, the same rule Wispr Flow uses.
struct Personalization {
    var vocab = Vocabulary()
    var snippets: [Snippet] = []
    var styles: [String: Style] = [:]
    var teamLoaded = false
    var teamError: String?

    static func load() -> Personalization {
        var p = Personalization()
        Vocabulary.ensureFile()
        Self.ensure(Paths.snippets, Snippet.template)
        Self.ensure(Paths.styles, Self.stylesTemplate)

        var dictText = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? ""
        var snippetText = (try? String(contentsOf: Paths.snippets, encoding: .utf8)) ?? ""
        var styleText = (try? String(contentsOf: Paths.styles, encoding: .utf8)) ?? ""

        if let team = Settings.shared.teamFolderURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: team.path, isDirectory: &isDir), isDir.boolValue {
                p.teamLoaded = true
                // Team entries are appended after personal ones, so personal lines parse first and win.
                dictText += "\n" + ((try? String(contentsOf: team.appendingPathComponent(TeamFolder.dictionary), encoding: .utf8)) ?? "")
                snippetText += "\n" + ((try? String(contentsOf: team.appendingPathComponent(TeamFolder.snippets), encoding: .utf8)) ?? "")
                styleText += "\n" + ((try? String(contentsOf: team.appendingPathComponent(TeamFolder.styles), encoding: .utf8)) ?? "")
            } else {
                p.teamError = "Team folder not reachable: \(team.lastPathComponent)"
            }
        }

        p.vocab = Vocabulary.parse(dictText)
        Snippet.parse(snippetText, into: &p.snippets)
        p.styles = Self.parseStyles(styleText)
        return p
    }

    /// Which style to use for the app in front. Order: personal file, team file, built-in table, neutral.
    func style(for bundleId: String?) -> Style {
        guard let id = bundleId else { return .neutral }
        return styles[id] ?? Style.defaults[id] ?? .neutral
    }

    static let stylesTemplate = """
    # FreeFlow styles: the tone the AI uses, by app.   bundle.id => formal | casual | neutral | code | plain
    # "plain" means no AI rewrite in that app. Find an app's bundle id with:  osascript -e 'id of app "Slack"'
    # Built-in defaults already cover Mail, Outlook, Slack, WhatsApp, Messages, Telegram, VS Code, Cursor, Terminal and more.

    # com.apple.Notes => casual

    """

    static func parseStyles(_ text: String) -> [String: Style] {
        var out: [String: Style] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let arrow = line.range(of: "=>") else { continue }
            let id = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
            guard !id.isEmpty, out[id] == nil, let s = Style(rawValue: name) else { continue }
            out[id] = s
        }
        return out
    }

    private static func ensure(_ url: URL, _ template: String) {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? template.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// The shared folder: any folder every teammate can see (iCloud Drive, Dropbox, the NAS, a git checkout).
enum TeamFolder {
    static let dictionary = "team-dictionary.txt"
    static let snippets = "team-snippets.txt"
    static let styles = "team-styles.txt"
    static let usageDir = "usage"

    /// Creates the three shared files with a short header if they are missing.
    static func prepare(_ url: URL) {
        let headers = [
            dictionary: "# Team dictionary: names, products, jargon. One per line, or  wrong => right\n",
            snippets: "# Team snippets:  cue => expansion   (\\n for a new line)\n",
            styles: "# Team styles:  bundle.id => formal | casual | neutral | code | plain\n",
        ]
        for (name, header) in headers {
            let f = url.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: f.path) {
                try? header.write(to: f, atomically: true, encoding: .utf8)
            }
        }
    }

    private static var lastUsageWrite = Date.distantPast

    /// Writes this user's word counts to usage/<name>.json, at most once a minute. Off unless the user turns it on.
    static func shareUsage() {
        let s = Settings.shared
        guard s.shareUsage, let team = s.teamFolderURL, Date().timeIntervalSince(lastUsageWrite) > 60 else { return }
        lastUsageWrite = Date()
        let dir = team.appendingPathComponent(usageDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
        let safe = name.replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
        let f = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "name": name, "updated": f.string(from: Date()),
            "wordsToday": s.wordsToday, "wordsTotal": s.wordsTotal, "day": Settings.today,
            "topApps": s.topApps(5).map { ["app": $0.0, "words": $0.1] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(safe).json"), options: .atomic)
        }
    }

    /// Reads every teammate's usage file for the menu.
    static func teamUsage() -> [(String, Int, Int)] {
        guard let team = Settings.shared.teamFolderURL else { return [] }
        let dir = team.appendingPathComponent(usageDir)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let name = o["name"] as? String else { return nil }
            let today = o["day"] as? String == Settings.today ? (o["wordsToday"] as? Int ?? 0) : 0
            return (name, today, o["wordsTotal"] as? Int ?? 0)
        }.sorted { $0.2 > $1.2 }
    }
}
