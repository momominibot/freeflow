import Foundation

/// Words that Whisper should spell your way, plus "wrong => right" swaps.
struct Vocabulary {
    var terms: [String] = []
    /// Words learned from your corrections. They share the prompt with `terms`, which keep most of the room.
    var learnedTerms: [String] = []
    var replacements: [(NSRegularExpression, String)] = []
    var seenWrong = Set<String>()

    /// At most 60 words go to the engine: your dictionary first, with room kept for what was learned.
    var promptTerms: [String] {
        let learned = learnedTerms.filter { !terms.contains($0) }
        let reserve = min(learned.count, max(60 - terms.count, 15))
        return Array(terms.prefix(60 - reserve)) + Array(learned.prefix(reserve))
    }

    var prompt: String {
        promptTerms.isEmpty ? "" : "Glossary: " + promptTerms.joined(separator: ", ") + "."
    }

    /// Same terms, introduced in Simplified Chinese so Whisper stays in Simplified for mixed English and Chinese speech.
    var promptMixed: String {
        promptTerms.isEmpty ? "" : "词汇：" + promptTerms.joined(separator: ", ") + "。"
    }

    /// A swap from `wrong` to `right`. The first rule for a given `wrong` wins, so your own dictionary beats what was learned.
    mutating func addReplacement(_ wrong: String, _ right: String) {
        guard !wrong.isEmpty, !seenWrong.contains(wrong.lowercased()) else { return }
        seenWrong.insert(wrong.lowercased())
        var pattern = NSRegularExpression.escapedPattern(for: wrong)
        if wrong.first.map({ $0.isLetter || $0.isNumber }) == true { pattern = "\\b" + pattern }
        if wrong.last.map({ $0.isLetter || $0.isNumber }) == true { pattern += "\\b" }
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            replacements.append((re, NSRegularExpression.escapedTemplate(for: right)))
        }
    }

    /// Adds what Purrscribe learned from your corrections: active swaps, and the words you meant as hotwords.
    mutating func addLearned(_ learned: LearnedFile, isCommon: (String) -> Bool) {
        for fix in learned.activeFixes(isCommon: isCommon) { addReplacement(fix.wrong, fix.right) }
        learnedTerms = learned.topTerms(40)
    }

    static let template = """
    # Purrscribe dictionary
    # One word or name per line, so Whisper spells it your way.
    # To always swap a spelling, write:  wrong => right
    # Changes apply to the next thing you dictate.

    Ranklore
    EMIS+
    reinstate.sg
    Pets Crystal
    Wellness Protocol
    Sen & Fascia
    Rhythme
    Shopify
    Vercel
    Supabase
    Higgsfield
    Seedream
    Doubao
    Hermes

    RankLore => Ranklore
    Rank Lore => Ranklore
    Ranklor => Ranklore

    """

    static func ensureFile() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.dictionary.path) {
            try? template.write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        }
    }

    /// The personal dictionary only. `Personalization.load()` adds the team's.
    static func load() -> Vocabulary {
        parse((try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? "")
    }

    static func parse(_ text: String) -> Vocabulary {
        var v = Vocabulary()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let arrow = line.range(of: "=>") {
                let wrong = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !wrong.isEmpty, !v.seenWrong.contains(wrong.lowercased()) else { continue }
                v.addReplacement(wrong, right)
                if !right.isEmpty, !v.terms.contains(right) { v.terms.append(right) }
            } else if !v.terms.contains(line) {
                v.terms.append(line)
            }
        }
        return v
    }

    func apply(_ s: String) -> String {
        replacements.reduce(s) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
    }

    /// Appends a word (or `wrong => right`) to the personal dictionary file.
    static func add(_ line: String) {
        ensureFile()
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let data = ("\n" + clean + "\n").data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: Paths.dictionary) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        }
    }
}

enum TextCleaner {
    /// Phrases Whisper tends to invent from silence or room noise.
    static let hallucinations: Set<String> = [
        "thank you", "thank you so much", "thanks for watching", "thank you for watching",
        "thanks for listening", "you", "bye", "bye bye", "please subscribe",
        "subtitles by the amaraorg community",
    ]

    static func clean(_ raw: String, removeFillers: Bool, vocab: Vocabulary, quiet: Bool) -> String {
        var t = raw.replacingOccurrences(of: "\n", with: " ")
        t = sub(t, #"\[[^\]]*\]"#, "")
        t = sub(t, #"(?i)\((?:music|silence|applause|laughter|laughs|inaudible|blank audio|background noise)[^)]*\)"#, "")
        t = sub(t, "[♪♫]+", "")
        let before = t.trimmingCharacters(in: .whitespaces)
        if removeFillers {
            // "we should, uh, ship" -> "we should ship"; a sentence-ending period is kept.
            t = sub(t, #"(?i)(?:,\s*)?\b(?:um+|uh+|uhm+|erm+|hmm+)\b[,…]*"#, "")
        }
        t = vocab.apply(t)
        t = sub(t, #"\s+([,.!?;:])"#, "$1")
        t = sub(t, #"\s{2,}"#, " ")
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        t = sub(t, #"^[,;:.…]+\s*"#, "")
        if removeFillers, let f = before.first, f.isUppercase, let g = t.first, g.isLowercase {
            t = g.uppercased() + t.dropFirst()
        }
        if quiet {
            let key = t.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
            if hallucinations.contains(key) { return "" }
        }
        return t
    }

    /// Only the hallucination filter and bracket noise, for the "None" cleanup level.
    static func raw(_ raw: String, quiet: Bool) -> String {
        var t = raw.replacingOccurrences(of: "\n", with: " ")
        t = sub(t, #"\[[^\]]*\]"#, "")
        t = sub(t, #"\s{2,}"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if quiet {
            let key = t.lowercased().filter { $0.isLetter || $0 == " " }.trimmingCharacters(in: .whitespaces)
            if hallucinations.contains(key) { return "" }
        }
        return t
    }

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

/// Say code the way it is written: "camel case user profile" gives userProfile. The same vocabulary Talon and Wispr Flow use,
/// as fixed rules (not model judgement), so a phrase gives the same name every time, on the Mac and on the iPhone.
///   camel case / snake case / kebab case (or dash case) / pascal case / constant case     then the words of the name
///   "index dot ts" gives index.ts, "src slash app slash main dot swift" gives src/app/main.swift, "dash dash force" gives --force
/// A case command only counts at the start of a clause (the whole dictation, or after . ! ? , ;), and the name stops at the
/// first bit of punctuation or small joining word (and, then, is, to, with ...), so "I like camel case names" is left alone.
enum CodeSpeech {
    private enum Case { case camel, snake, kebab, pascal, constant }

    private static let triggers: [(String, Case)] = [
        ("screaming snake case", .constant), ("constant case", .constant), ("snake case", .snake),
        ("camel case", .camel), ("pascal case", .pascal), ("kebab case", .kebab), ("dash case", .kebab),
    ]

    private static let stopWords: Set<String> = [
        "and", "then", "but", "or", "so", "because", "which", "that", "is", "are", "was", "were", "should", "will", "would", "can",
        "in", "on", "to", "from", "with", "into", "for", "as", "when", "if", "please", "thanks", "thank",
    ]

    private static let extensions = "swift|ts|tsx|js|jsx|mjs|py|rs|go|rb|java|kt|cpp|hpp|php|sh|zsh|md|json|yaml|yml|toml|css|scss|html|xml|sql|txt|lock|env|plist|csv|png|jpg|svg"

    static func apply(_ input: String) -> String {
        var t = input
        // Names in a given case, clause by clause.
        let names = triggers.map { NSRegularExpression.escapedPattern(for: $0.0).replacingOccurrences(of: "\\ ", with: " ") }.joined(separator: "|")
        let pattern = "(?im)(^|[.!?,;]\\s+|\\n)(\(names))[ \\t]+([A-Za-z0-9][A-Za-z0-9'’-]*(?:[ \\t]+[A-Za-z0-9][A-Za-z0-9'’-]*)*)"
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let lead = ns.substring(with: m.range(at: 1))
                let trigger = ns.substring(with: m.range(at: 2)).lowercased()
                guard let style = triggers.first(where: { $0.0 == trigger })?.1 else { continue }
                var words = ns.substring(with: m.range(at: 3)).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                var rest: [String] = []
                if let stop = words.firstIndex(where: { stopWords.contains($0.lowercased()) }) {
                    rest = Array(words[stop...]); words = Array(words[..<stop])
                }
                if words.count > 6 { rest = Array(words[6...]) + rest; words = Array(words[..<6]) }
                guard !words.isEmpty else { continue }
                var replacement = lead + format(words, style)
                if !rest.isEmpty { replacement += " " + rest.joined(separator: " ") }
                // "Camel case user name." as the whole dictation: the name, without a sentence full stop after it.
                let end = m.range.location + m.range.length
                if lead.isEmpty, rest.isEmpty, ns.substring(from: end).trimmingCharacters(in: .whitespaces) == "." {
                    t = ns.replacingCharacters(in: NSRange(location: m.range.location, length: ns.length - m.range.location), with: replacement)
                } else {
                    t = ns.replacingCharacters(in: m.range, with: replacement)
                }
                return apply(t) // one name at a time keeps the ranges simple; the loop ends when none are left
            }
        }
        // File names and paths: "index dot ts", "src slash app slash main dot swift".
        t = TextCleaner.sub(t, "(?i)\\b([A-Za-z0-9_-]+) dot (\(extensions))\\b", "$1.$2")
        if let re = try? NSRegularExpression(pattern: "(?i)\\b[A-Za-z0-9_-]+(?: slash [A-Za-z0-9_-]+)+(?=\\.(?:\(extensions))\\b)") {
            let ns = t as NSString
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let path = ns.substring(with: m.range).replacingOccurrences(of: " slash ", with: "/", options: .caseInsensitive)
                t = (t as NSString).replacingCharacters(in: m.range, with: path)
            }
        }
        // Flags: "dash dash force" is --force.
        t = TextCleaner.sub(t, "(?i)\\bdash dash ([A-Za-z][A-Za-z0-9-]*)", "--$1")
        return t
    }

    private static func format(_ words: [String], _ style: Case) -> String {
        let clean = words.map { $0.replacingOccurrences(of: "['’]", with: "", options: .regularExpression).lowercased() }.filter { !$0.isEmpty }
        func cap(_ w: String) -> String { w.prefix(1).uppercased() + w.dropFirst() }
        switch style {
        case .camel: return clean.enumerated().map { $0.offset == 0 ? $0.element : cap($0.element) }.joined()
        case .pascal: return clean.map(cap).joined()
        case .snake: return clean.joined(separator: "_")
        case .kebab: return clean.joined(separator: "-")
        case .constant: return clean.joined(separator: "_").uppercased()
        }
    }
}

/// Things you can say at the end of a dictation, like Wispr Flow's "press enter".
struct SpokenCommands {
    var text: String
    var pressEnter = false

    static func parse(_ input: String) -> SpokenCommands {
        var out = SpokenCommands(text: input)
        var t = CodeSpeech.apply(input)
        // "... press enter" / "hit return" / "send it" at the very end sends the message after pasting.
        // A command must start its own clause: the whole dictation, or right after . ! ? , ; so "and then press enter"
        // inside a sentence is left alone. The sentence's own full stop before the command is kept; a comma is dropped.
        let enter = #"(?i)(?:^|(?<=[.!?])|,|;)\s*(?:press|hit)\s+(?:enter|return)\b[.!]?\s*$"#
        if TextCleaner.sub(t, enter, "\u{1}").hasSuffix("\u{1}") {
            out.pressEnter = true
            t = TextCleaner.sub(t, enter, "")
        }
        // "new paragraph" as its own clause becomes a blank line; "new line" only at the end, since it is an ordinary phrase too.
        t = TextCleaner.sub(t, #"(?i)(?:^|(?<=[.!?])|,|;)\s*new paragraph\b[,.]?\s*"#, "\n\n")
        t = TextCleaner.sub(t, #"(?i)(?:^|(?<=[.!?])|,|;)\s*new line\b[.!]?\s*$"#, "\n")
        t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        out.text = t.trimmingCharacters(in: .whitespaces)
        if out.text.hasSuffix("\n") == false { out.text = out.text.trimmingCharacters(in: .newlines) }
        return out
    }
}
