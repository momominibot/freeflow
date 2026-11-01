import Foundation

/// Words that Whisper should spell your way, plus "wrong => right" swaps.
struct Vocabulary {
    var terms: [String] = []
    var replacements: [(NSRegularExpression, String)] = []

    var prompt: String {
        terms.isEmpty ? "" : "Glossary: " + terms.prefix(60).joined(separator: ", ") + "."
    }

    static let template = """
    # FreeFlow dictionary
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

    static func load() -> Vocabulary {
        var v = Vocabulary()
        guard let text = try? String(contentsOf: Paths.dictionary, encoding: .utf8) else { return v }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let arrow = line.range(of: "=>") {
                let wrong = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !wrong.isEmpty else { continue }
                var pattern = NSRegularExpression.escapedPattern(for: wrong)
                if wrong.first.map({ $0.isLetter || $0.isNumber }) == true { pattern = "\\b" + pattern }
                if wrong.last.map({ $0.isLetter || $0.isNumber }) == true { pattern += "\\b" }
                if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    v.replacements.append((re, NSRegularExpression.escapedTemplate(for: right)))
                }
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

    static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
