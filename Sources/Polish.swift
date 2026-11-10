import Foundation
import NaturalLanguage

// Polish: the Grammarly-style half of FreeFlow. Shared by the Mac app and the iPhone app (like Text.swift), Foundation only.
//
//  * GrammarChecker   finds spelling, grammar, punctuation, clarity and word-choice problems and offers fixes.
//                     The engine is Harper (Apache-2.0, https://github.com/Automattic/harper) when it is linked in
//                     (scripts/build-harper.sh, compile flag HARPER); otherwise a smaller built-in rule set is used.
//  * WritingStats     words, reading time, grade level.
//  * ToneReader       how the text will probably sound (formal, friendly, urgent, hesitant ...).
//  * RewriteMode      "make it shorter / friendlier / more confident" prompts for a local model, and RewriteGuard, which
//                     refuses a rewrite that changed a number, dropped one of your words or switched language.
//
// Everything runs on the device. Nothing is sent anywhere.

// MARK: - Issues

enum PolishKind: String, CaseIterable, Codable {
    case spelling, grammar, punctuation, clarity, style

    var title: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .punctuation: return "Punctuation"
        case .clarity: return "Clarity"
        case .style: return "Word choice"
        }
    }

    /// Things that are simply wrong, as opposed to things that could read better.
    var isCorrectness: Bool { self == .spelling || self == .grammar || self == .punctuation }

    /// Harper's own category names, folded into ours. Anything that is a plain mistake (wrong article, "should of", then/than,
    /// agreement, capitals) counts as grammar so "fix all" reaches it; only suggestions that make the text better stay optional.
    static func from(harper key: String) -> PolishKind {
        switch key {
        case "Spelling", "Typo": return .spelling
        case "Punctuation", "Formatting": return .punctuation
        case "Readability", "Redundancy": return .clarity
        case "Enhancement", "Style", "Regionalism": return .style
        default: return .grammar   // Agreement, Capitalization, Grammar, Usage, WordChoice, Miscellaneous, Eggcorn, Malapropism ...
        }
    }
}

struct PolishIssue: Identifiable, Equatable {
    /// Positions count Unicode scalars in the text that was checked. Check again after every edit.
    var start: Int
    var end: Int
    var kind: PolishKind
    var message: String
    var original: String
    /// Whole replacements for `original`. An empty string means "take it out".
    var fixes: [String]

    var id: String { "\(start):\(end):\(kind.rawValue):\(original)" }
}

enum PolishText {
    static func scalarCount(_ text: String) -> Int { text.unicodeScalars.count }

    static func slice(_ text: String, _ start: Int, _ end: Int) -> String {
        let u = text.unicodeScalars
        guard start >= 0, end >= start, end <= u.count else { return "" }
        let a = u.index(u.startIndex, offsetBy: start)
        let b = u.index(a, offsetBy: end - start)
        return String(String.UnicodeScalarView(u[a..<b]))
    }

    /// The text with one fix applied. Taking a word out also takes out the space it leaves behind.
    static func apply(_ replacement: String, start: Int, end: Int, to text: String) -> String {
        let u = text.unicodeScalars
        guard start >= 0, end >= start, end <= u.count else { return text }
        let a = u.index(u.startIndex, offsetBy: start)
        let b = u.index(a, offsetBy: end - start)
        var head = String(String.UnicodeScalarView(u[..<a]))
        var tail = String(String.UnicodeScalarView(u[b...]))
        if replacement.isEmpty {
            if head.hasSuffix(" "), tail.hasPrefix(" ") || tail.isEmpty || tail.first.map({ ",.;:!?)".contains($0) }) == true {
                head.removeLast()
            } else if head.isEmpty || head.hasSuffix("\n"), tail.hasPrefix(" ") {
                tail.removeFirst()
            }
        }
        return head + replacement + tail
    }

    static func apply(_ issue: PolishIssue, fix: Int = 0, to text: String) -> String {
        guard issue.fixes.indices.contains(fix) else { return text }
        return apply(issue.fixes[fix], start: issue.start, end: issue.end, to: text)
    }

    /// A few words around the problem, for showing in a list.
    static func context(of issue: PolishIssue, in text: String, radius: Int = 36) -> (before: String, problem: String, after: String) {
        let total = scalarCount(text)
        let a = max(0, issue.start - radius), b = min(total, issue.end + radius)
        var before = slice(text, a, issue.start), after = slice(text, issue.end, b)
        if a > 0 { before = "…" + before.drop(while: { !$0.isWhitespace }) }
        if b < total { after = String(after.reversed().drop(while: { !$0.isWhitespace }).reversed()) + "…" }
        return (before.replacingOccurrences(of: "\n", with: " "), slice(text, issue.start, issue.end), after.replacingOccurrences(of: "\n", with: " "))
    }

    static func hasCJK(_ s: String) -> Bool { s.contains(where: RewriteGuard.isCJK) }
}

// MARK: - The checker

enum GrammarChecker {
    /// Checks `text`. `words` are never reported as misspelled (your dictionary); `ignored` are problems you already dismissed
    /// (the exact text that was flagged, lowercased).
    static func check(_ text: String, words: [String] = [], ignored: Set<String> = []) -> [PolishIssue] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let known = Set(words.map { $0.lowercased() })
        var found: [PolishIssue]
        if HarperEngine.isLinked {
            HarperEngine.configure(words: words)
            found = HarperEngine.lint(text, mixed: PolishText.hasCJK(text))
            found += RuleChecker.extras(text)
        } else {
            found = RuleChecker.all(text)
        }
        // Web addresses, e-mail addresses, file names, #tags, @names and the entries of your dictionary are left alone, wherever
        // they sit: no engine knows that "emis.asia" or "EMIS+" is not a typo.
        let protected = protectedRanges(in: text, words: words)
        found = found.filter { issue in
            let key = issue.original.lowercased()
            if ignored.contains(key) { return false }
            if issue.kind == .spelling, known.contains(key) { return false }
            if protected.contains(where: { issue.start < $0.upperBound && $0.lowerBound < issue.end }) { return false }
            if isListMarkerCapital(issue, in: text) { return false }
            return true
        }
        // Where two problems cover the same words, keep the more important one (correctness before polish). A note about a whole
        // sentence (too long, hard to read) has no fix and sits beside the specific problems instead of hiding them.
        let notes = found.filter { $0.fixes.isEmpty && $0.kind == .clarity && $0.end - $0.start > 60 }
        let specific = found.filter { !($0.fixes.isEmpty && $0.kind == .clarity && $0.end - $0.start > 60) }
            .sorted { ($0.start, $0.kind.isCorrectness ? 0 : 1) < ($1.start, $1.kind.isCorrectness ? 0 : 1) }
        var kept: [PolishIssue] = []
        for i in specific {
            if let last = kept.last, i.start < last.end { continue }
            kept.append(i)
        }
        return (kept + notes).sorted { $0.start < $1.start }
    }

    /// Applies fixes in one go: the first suggestion of every correctness problem. With `onlyClear`, spelling is left alone and a
    /// problem is fixed only when there is exactly one suggestion, which is what is safe to do without asking.
    static func autoFix(_ text: String, words: [String] = [], onlyClear: Bool = false) -> (text: String, fixed: Int) {
        var out = text
        var count = 0
        let issues = check(text, words: words).filter { $0.kind.isCorrectness && !$0.fixes.isEmpty }
        for issue in issues.reversed() {
            if onlyClear, issue.kind == .spelling || issue.fixes.count != 1 { continue }
            out = PolishText.apply(issue, fix: 0, to: out)
            count += 1
        }
        return (out, count)
    }

    /// Words that mean about the same. The hand-picked list first (it is short but good for the words people lean on), then
    /// Harper's thesaurus when linked. That one lists every sense of a word ("good" gives "one", "company", "line"), so it is
    /// sorted by how close Apple's on-device word model thinks each one is, and the far ones are dropped.
    static func synonyms(for word: String) -> [String] {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !w.isEmpty, w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { return [] }
        if let curated = RuleChecker.thesaurus[w] { return curated }
        guard HarperEngine.isLinked else { return [] }
        // Single plain words only: the thesaurus also holds phrases and rare forms that read oddly in a list.
        let plain = HarperEngine.synonyms(w).filter { $0.allSatisfy(\.isLetter) && $0.count > 2 && $0 != w }
        return Array(rank(plain, against: w).prefix(6))
    }

    private static func rank(_ candidates: [String], against word: String) -> [String] {
        guard candidates.count > 1, let embedding = NLEmbedding.wordEmbedding(for: .english) else { return candidates }
        let scored = candidates.map { ($0, embedding.distance(between: word, and: $0)) }
            .sorted { $0.1 < $1.1 }
        let near = scored.filter { $0.1 <= 1.15 }
        return (near.count >= 3 ? near : scored).map(\.0)
    }

    // MARK: Things that are not mistakes

    private static let protectedPattern: NSRegularExpression = {
        let tlds = "com|org|net|io|asia|sg|co|ai|app|dev|edu|gov|uk|my|cn|me|xyz|shop|store"
        let files = "swift|txt|md|pdf|docx?|xlsx?|pptx?|csv|png|jpe?g|gif|json|js|ts|py|html?|css|zip|mp[34]|wav|m4a"
        let pattern = "(?:https?://|www\\.)\\S+"
            + "|[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+"
            + "|\\b[\\w-]+(?:\\.[\\w-]+)*\\.(?:\(tlds))\\b(?:/\\S*)?"
            + "|\\b[\\w-]+\\.(?:\(files))\\b"
            + "|[#@][\\w-]+"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Scalar ranges of web addresses, e-mail addresses, file names, tags and the words of your dictionary.
    static func protectedRanges(in text: String, words: [String]) -> [Range<Int>] {
        let ns = text as NSString
        var ns16: [NSRange] = protectedPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        for w in words where w.count >= 2 {
            var from = 0
            while from < ns.length {
                let r = ns.range(of: w, options: [.caseInsensitive], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                ns16.append(r)
                from = r.location + max(1, r.length)
            }
        }
        guard !ns16.isEmpty else { return [] }
        let u = text.unicodeScalars
        return ns16.compactMap { r in
            guard let range = Range(r, in: text) else { return nil }
            return u.distance(from: u.startIndex, to: range.lowerBound)..<u.distance(from: u.startIndex, to: range.upperBound)
        }
    }

    /// "1. open the app": a list item is not a sentence, so the missing capital is not worth a mark.
    private static func isListMarkerCapital(_ issue: PolishIssue, in text: String) -> Bool {
        guard issue.kind == .grammar, let fix = issue.fixes.first, let first = issue.original.first, first.isLowercase,
              fix != issue.original, fix.lowercased() == issue.original.lowercased() else { return false }
        let head = PolishText.slice(text, max(0, issue.start - 12), issue.start)
        let line = head.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? head
        return line.range(of: "^\\s*(?:\\d{1,3}[.)]|[-*•–])\\s+$", options: .regularExpression) != nil
    }
}

// MARK: - Harper (linked in when the HARPER flag is set)

enum HarperEngine {
    #if HARPER
    static let isLinked = true
    #else
    static let isLinked = false
    #endif

    /// 0 American, 1 British, 2 Canadian, 3 Australian, 4 Indian. Singapore uses British spelling.
    static var dialect: Int = 1 { didSet { if oldValue != dialect { configured = nil } } }
    private static var configured: [String]?
    private static let lock = NSLock()

    private struct Fix: Decodable { var kind: String; var text: String }
    private struct Problem: Decodable { var start: Int; var end: Int; var kind: String; var message: String; var priority: Int; var fixes: [Fix] }

    /// Tells Harper which words are fine. Cheap when nothing changed.
    static func configure(words: [String]) {
        #if HARPER
        lock.lock(); defer { lock.unlock() }
        let sorted = words.sorted()
        if configured == sorted { return }
        harper_set_dialect(Int32(dialect))
        if let data = try? JSONEncoder().encode(sorted), let json = String(data: data, encoding: .utf8) {
            json.withCString { harper_set_words($0) }
        }
        configured = sorted
        #endif
    }

    static func lint(_ text: String, mixed: Bool) -> [PolishIssue] {
        #if HARPER
        lock.lock(); defer { lock.unlock() }
        guard let raw = text.withCString({ harper_lint($0, mixed ? 1 : 0) }) else { return [] }
        defer { harper_free(raw) }
        guard let problems = try? JSONDecoder().decode([Problem].self, from: Data(String(cString: raw).utf8)) else { return [] }
        return problems.compactMap { p in
            let original = PolishText.slice(text, p.start, p.end)
            guard !original.isEmpty || p.fixes.contains(where: { $0.kind == "insert" }) else { return nil }
            var fixes: [String] = []
            for f in p.fixes {
                switch f.kind {
                case "remove": fixes.append("")
                case "insert": fixes.append(original + f.text)
                default: fixes.append(f.text)
                }
            }
            return PolishIssue(start: p.start, end: p.end, kind: PolishKind.from(harper: p.kind),
                               message: cleanMessage(p.message), original: original, fixes: fixes)
        }
        #else
        return []
        #endif
    }

    static func synonyms(_ word: String) -> [String] {
        #if HARPER
        lock.lock(); defer { lock.unlock() }
        guard let raw = word.withCString({ harper_synonyms($0) }) else { return [] }
        defer { harper_free(raw) }
        return (try? JSONDecoder().decode([String].self, from: Data(String(cString: raw).utf8))) ?? []
        #else
        return []
        #endif
    }

    /// Harper writes its explanations in Markdown (backticks, bold); lists show plain words.
    static func cleanMessage(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "\"").replacingOccurrences(of: "**", with: "")
    }
}

// MARK: - Built-in rules (the fallback, and the extras Harper does not do)

enum RuleChecker {
    // Phrase tables: (wrong, right, why)
    private static let confusions: [(String, String, String)] = [
        ("should of", "should have", "\"Should of\" is a misheard \"should have\"."),
        ("could of", "could have", "\"Could of\" is a misheard \"could have\"."),
        ("would of", "would have", "\"Would of\" is a misheard \"would have\"."),
        ("must of", "must have", "\"Must of\" is a misheard \"must have\"."),
        ("might of", "might have", "\"Might of\" is a misheard \"might have\"."),
        ("alot", "a lot", "\"A lot\" is two words."),
        ("your welcome", "you're welcome", "\"You're\" (you are) is meant here."),
        ("your a", "you're a", "\"You're\" (you are) is meant here."),
        ("its a", "it's a", "\"It's\" (it is) is meant here."),
        ("their is", "there is", "\"There is\" is meant here."),
        ("he don't", "he doesn't", "Use \"doesn't\" with he, she and it."),
        ("she don't", "she doesn't", "Use \"doesn't\" with he, she and it."),
        ("it don't", "it doesn't", "Use \"doesn't\" with he, she and it."),
        ("they was", "they were", "Use \"were\" with they."),
        ("we was", "we were", "Use \"were\" with we."),
        ("you was", "you were", "Use \"were\" with you."),
        ("less people", "fewer people", "Use \"fewer\" for things you can count."),
        ("more better", "better", "\"Better\" already means more good."),
        ("could care less", "couldn't care less", "The saying is \"couldn't care less\"."),
        ("for all intensive purposes", "for all intents and purposes", "The saying is \"for all intents and purposes\"."),
    ]

    private static let spellings: [(String, String)] = [
        ("definately", "definitely"), ("seperate", "separate"), ("recieve", "receive"), ("occured", "occurred"),
        ("untill", "until"), ("wich", "which"), ("teh", "the"), ("adress", "address"), ("begining", "beginning"),
        ("beleive", "believe"), ("calender", "calendar"), ("commited", "committed"), ("enviroment", "environment"),
        ("goverment", "government"), ("independant", "independent"), ("neccessary", "necessary"), ("necesary", "necessary"),
        ("occassion", "occasion"), ("accomodate", "accommodate"), ("tommorow", "tomorrow"), ("tomorow", "tomorrow"),
        ("wierd", "weird"), ("thier", "their"), ("freind", "friend"), ("realy", "really"), ("truely", "truly"),
    ]

    private static let wordy: [(String, String)] = [
        ("in order to", "to"), ("due to the fact that", "because"), ("at this point in time", "now"),
        ("at the present time", "now"), ("in the event that", "if"), ("for the purpose of", "for"),
        ("with regard to", "about"), ("with regards to", "about"), ("a number of", "several"),
        ("in spite of the fact that", "although"), ("has the ability to", "can"), ("is able to", "can"),
        ("in close proximity to", "near"), ("each and every", "every"), ("first and foremost", "first"),
        ("the reason why is that", "because"), ("it is important to note that", ""), ("needless to say", ""),
        ("very unique", "unique"), ("completely finished", "finished"), ("past history", "history"),
        ("end result", "result"), ("future plans", "plans"), ("free gift", "gift"), ("repeat again", "repeat"),
        ("revert back", "revert"), ("basically", ""), ("absolutely essential", "essential"),
    ]

    private static let veryAdjective: [String: [String]] = [
        "good": ["excellent", "great"], "bad": ["terrible", "awful"], "big": ["huge", "enormous"], "small": ["tiny"],
        "important": ["crucial", "essential"], "happy": ["delighted", "thrilled"], "sad": ["miserable"], "tired": ["exhausted"],
        "easy": ["simple", "effortless"], "smart": ["brilliant"], "fast": ["rapid", "quick"], "slow": ["sluggish"],
        "old": ["ancient"], "interesting": ["fascinating"], "beautiful": ["stunning", "gorgeous"], "angry": ["furious"],
        "hungry": ["starving"], "clean": ["spotless"], "funny": ["hilarious"], "cold": ["freezing"], "hot": ["scorching"],
        "quiet": ["silent"], "pretty": ["gorgeous"], "nice": ["delightful"], "sure": ["certain"], "tasty": ["delicious"],
        "worried": ["anxious"], "surprised": ["astonished"], "necessary": ["essential"], "bright": ["brilliant"],
    ]

    /// Words that are easy to lean on. Flagged only when they come back three times or more.
    static let thesaurus: [String: [String]] = [
        "good": ["great", "solid", "strong", "fine"], "nice": ["pleasant", "kind", "lovely"],
        "thing": ["item", "matter", "point"], "things": ["items", "matters", "points"], "stuff": ["material", "items", "belongings"],
        "big": ["large", "major", "significant"], "bad": ["poor", "weak", "harmful"], "great": ["excellent", "superb", "strong"],
        "important": ["key", "vital", "significant"], "really": ["truly", "genuinely"], "very": ["highly", "especially"],
        "just": ["only", "simply"], "get": ["receive", "obtain", "become"], "got": ["received", "obtained", "became"],
        "amazing": ["remarkable", "impressive"], "interesting": ["intriguing", "notable"], "lot": ["great deal", "plenty"],
        "happy": ["pleased", "glad"], "sad": ["unhappy", "down"], "use": ["apply", "employ"], "help": ["assist", "support"],
        "make": ["create", "build", "produce"], "show": ["demonstrate", "reveal"], "need": ["require"], "start": ["begin", "launch"],
        "think": ["believe", "consider"], "say": ["state", "mention"], "tell": ["inform", "let know"], "fast": ["quick", "rapid"],
    ]
    private static let overused: Set<String> = ["good", "nice", "thing", "things", "stuff", "big", "bad", "great", "important",
                                                "really", "very", "just", "get", "got", "amazing", "interesting"]

    private static let notVowelSound: Set<String> = ["one", "once", "use", "used", "user", "users", "usual", "usually", "useful", "uk", "ukulele",
                                                     "university", "unit", "union", "unique", "uniform", "united", "universal", "unicorn",
                                                     "european", "euro", "eulogy", "utility", "utensil", "ubiquitous", "usage", "unanimous"]
    private static let silentH: Set<String> = ["hour", "hours", "honest", "honestly", "honour", "honor", "heir", "hourly"]
    private static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "mr", "mrs", "ms", "dr", "prof", "no", "inc", "ltd", "approx", "est", "st", "jr", "sr", "fig"]

    // MARK: entry points

    /// Everything, for when Harper is not linked in.
    static func all(_ text: String) -> [PolishIssue] {
        var out: [PolishIssue] = []
        for seg in latinSegments(text) {
            out += segmentIssues(seg.text, offset: seg.offset, atTextStart: seg.offset == 0)
        }
        return out + extras(text)
    }

    /// What Harper does not do (or not reliably): word mix-ups from the tables, wordy phrases, the "you use this word a lot" and
    /// "very + word" nudges, and long sentences.
    static func extras(_ text: String) -> [PolishIssue] {
        var out: [PolishIssue] = []
        for seg in latinSegments(text) {
            out += phraseIssues(seg.text, offset: seg.offset)
            out += veryIssues(seg.text, offset: seg.offset)
            out += overusedIssues(seg.text, offset: seg.offset)
            out += longSentences(seg.text, offset: seg.offset)
        }
        return out
    }

    // MARK: segments (Chinese and other CJK text is never judged as English)

    struct Segment { var text: String; var offset: Int }

    static func latinSegments(_ text: String) -> [Segment] {
        guard PolishText.hasCJK(text) else { return [Segment(text: text, offset: 0)] }
        var out: [Segment] = []
        var current = String.UnicodeScalarView()
        var start = 0, index = 0
        for u in text.unicodeScalars {
            if RewriteGuard.isCJK(Character(u)) {
                if !current.isEmpty { out.append(Segment(text: String(current), offset: start)); current = String.UnicodeScalarView() }
                start = index + 1
            } else {
                if current.isEmpty { start = index }
                current.append(u)
            }
            index += 1
        }
        if !current.isEmpty { out.append(Segment(text: String(current), offset: start)) }
        return out
    }

    // MARK: helpers

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        // The patterns are fixed in this file; a typo should fail loudly in the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// A phrase as a pattern that also matches when the words are separated by more than one space.
    private static func phrasePattern(_ phrase: String) -> String {
        phrase.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
    }

    /// Scalar offsets for an NSRange of `text`.
    private static func span(_ r: NSRange, in text: String) -> (Int, Int)? {
        guard let range = Range(r, in: text) else { return nil }
        let u = text.unicodeScalars
        return (u.distance(from: u.startIndex, to: range.lowerBound), u.distance(from: u.startIndex, to: range.upperBound))
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func sub(_ text: String, _ r: NSRange) -> String {
        Range(r, in: text).map { String(text[$0]) } ?? ""
    }

    private static func matchCase(_ replacement: String, like original: String) -> String {
        guard let f = original.first, f.isUppercase, let r = replacement.first else { return replacement }
        return String(r).uppercased() + replacement.dropFirst()
    }

    private static func make(_ r: NSRange, _ text: String, _ offset: Int, _ kind: PolishKind, _ message: String, _ fixes: [String]) -> PolishIssue? {
        guard let (a, b) = span(r, in: text) else { return nil }
        return PolishIssue(start: a + offset, end: b + offset, kind: kind, message: message, original: sub(text, r), fixes: fixes)
    }

    // MARK: rules

    private static func segmentIssues(_ text: String, offset: Int, atTextStart: Bool) -> [PolishIssue] {
        var out: [PolishIssue] = []

        // The same word twice in a row.
        for m in matches(regex("\\b([A-Za-z']+)\\s+\\1\\b"), text) {
            let word = sub(text, m.range(at: 1)).lowercased()
            if ["that", "had"].contains(word) { continue }
            if let i = make(m.range, text, offset, .grammar, "The word \"\(word)\" is repeated.", [sub(text, m.range(at: 1))]) { out.append(i) }
        }

        // a / an
        for m in matches(regex("\\b(a|an)\\s+([A-Za-z]+)\\b"), text) {
            let article = sub(text, m.range(at: 1)), word = sub(text, m.range(at: 2))
            let lower = word.lowercased()
            if word == word.uppercased(), word.count > 1 { continue }          // acronyms: "an MBA", "a FAQ"
            guard let f = lower.first else { continue }
            let vowelSound = ("aeiou".contains(f) && !notVowelSound.contains(lower)) || silentH.contains(lower)
            let needs = vowelSound ? "an" : "a"
            if article.lowercased() != needs, let i = make(m.range(at: 1), text, offset, .grammar,
                                                          "Use \"\(needs)\" before \"\(word)\".", [matchCase(needs, like: article)]) { out.append(i) }
        }

        // lowercase "i" (also the start of i'm, i'll, i've, i'd)
        for m in matches(regex("(?<![A-Za-z0-9'’.@/_-])i(?=\\s|'|’|$|[,.;:!?])", []), text) {
            if let i = make(m.range, text, offset, .grammar, "The word \"I\" is always a capital letter.", ["I"]) { out.append(i) }
        }

        // The first word of a sentence starts with a capital letter.
        for m in matches(regex("(^|[.!?]\\s+|\\n\\s*)([a-z][a-z']*)\\b", []), text) {
            if m.range(at: 1).length == 0, !atTextStart { continue }
            let word = sub(text, m.range(at: 2))
            let before = sub(text, m.range(at: 1))
            if before.contains("."), let prev = previousWord(before: m.range(at: 1).location, in: text) {
                if abbreviations.contains(prev.lowercased()) { continue }          // e.g. like, Mr. smith
                if prev.allSatisfy(\.isNumber) { continue }                        // 1. first item
            }
            let loc = m.range(at: 1).location
            if before.hasPrefix("."), loc > 0, (text as NSString).substring(with: NSRange(location: loc - 1, length: 1)) == "." { continue }   // wait... what
            // "e.g. like", "iPhone", www.site.com: only plain lowercase words, not followed by a dot-joined name.
            let end = m.range(at: 2).location + m.range(at: 2).length
            if end < (text as NSString).length, ".@/_".contains((text as NSString).substring(with: NSRange(location: end, length: 1))) { continue }
            if let i = make(m.range(at: 2), text, offset, .grammar, "Start a sentence with a capital letter.", [matchCase(word, like: "A")]) { out.append(i) }
        }

        // Spaces
        for m in matches(regex("(?<=\\S)[ \\t]{2,}(?=\\S)", []), text) {
            if let i = make(m.range, text, offset, .punctuation, "There is more than one space here.", [" "]) { out.append(i) }
        }
        for m in matches(regex("(?<=[A-Za-z0-9])[ \\t]+(?=[,;:!?](?:\\s|$))", []), text) {
            if let i = make(m.range, text, offset, .punctuation, "No space is needed before this mark.", [""]) { out.append(i) }
        }
        for m in matches(regex("(?<=[A-Za-z]{2}),(?=[A-Za-z]{2})", []), text) {
            if let i = make(m.range, text, offset, .punctuation, "Add a space after the comma.", [", "]) { out.append(i) }
        }
        for m in matches(regex("(?<=[a-z]{3})\\.(?=[A-Z][a-z]{2})", []), text) {
            // Skip dotted names such as Node.Js or file.Name.
            if previousWord(before: m.range.location, in: text)?.contains(".") == true { continue }
            if let i = make(m.range, text, offset, .punctuation, "Add a space after the full stop.", [". "]) { out.append(i) }
        }

        // then / than
        for m in matches(regex("\\b((?:[a-z]+er|more|less|better|worse|rather))\\s+(then)\\b"), text) {
            if let i = make(m.range(at: 2), text, offset, .grammar, "After a comparison, use \"than\".", [matchCase("than", like: sub(text, m.range(at: 2)))]) { out.append(i) }
        }

        for (wrong, right) in spellings {
            for m in matches(regex("\\b" + wrong + "\\b"), text) {
                if let i = make(m.range, text, offset, .spelling, "\"\(sub(text, m.range))\" is misspelled.", [matchCase(right, like: sub(text, m.range))]) { out.append(i) }
            }
        }
        return out
    }

    /// Mix-ups and wordy phrases from the tables above. Harper covers many of the mix-ups too; where both find the same words the
    /// overlap is resolved in `GrammarChecker.check`.
    private static func phraseIssues(_ text: String, offset: Int) -> [PolishIssue] {
        var out: [PolishIssue] = []
        for (wrong, right, why) in confusions {
            let re = regex("\\b" + phrasePattern(wrong) + "\\b")
            for m in matches(re, text) {
                if let i = make(m.range, text, offset, .grammar, why, [matchCase(right, like: sub(text, m.range))]) { out.append(i) }
            }
        }
        // their going to -> they're going to, its not -> it's not (only before words that cannot follow the possessive)
        for m in matches(regex("\\b(their)\\s+(?:not|always|just|really|(?:going|coming)\\s+(?:to|home|there|out|back|in|on))\\b"), text) {
            let r = m.range(at: 1)
            if let i = make(r, text, offset, .grammar, "\"They're\" (they are) is meant here.", [matchCase("they're", like: sub(text, r))]) { out.append(i) }
        }
        for m in matches(regex("\\b(its)\\s+(?:not|been|always|just|really|going\\s+to)\\b"), text) {
            let r = m.range(at: 1)
            if let i = make(r, text, offset, .grammar, "\"It's\" (it is) is meant here.", [matchCase("it's", like: sub(text, r))]) { out.append(i) }
        }
        for (long, short) in wordy {
            let re = regex("\\b" + phrasePattern(long) + "\\b")
            for m in matches(re, text) {
                let msg = short.isEmpty ? "You can leave this out." : "Shorter: \"\(short)\"."
                if let i = make(m.range, text, offset, .clarity, msg, [short.isEmpty ? "" : matchCase(short, like: sub(text, m.range))]) { out.append(i) }
            }
        }
        return out
    }

    private static func previousWord(before location: Int, in text: String) -> String? {
        let ns = text as NSString
        guard location > 0 else { return nil }
        var end = location
        while end > 0, " .!?\n".contains(ns.substring(with: NSRange(location: end - 1, length: 1))) { end -= 1 }
        var start = end
        while start > 0, !" \n".contains(ns.substring(with: NSRange(location: start - 1, length: 1))) { start -= 1 }
        guard end > start else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()"))
    }

    private static func veryIssues(_ text: String, offset: Int) -> [PolishIssue] {
        var out: [PolishIssue] = []
        for m in matches(regex("\\b(very|really)\\s+([A-Za-z]+)\\b"), text) {
            let adj = sub(text, m.range(at: 2)).lowercased()
            guard let better = veryAdjective[adj] else { continue }
            let original = sub(text, m.range)
            if let i = make(m.range, text, offset, .style, "\"\(original)\" can be one stronger word.", better.map { matchCase($0, like: original) }) { out.append(i) }
        }
        return out
    }

    private static func overusedIssues(_ text: String, offset: Int) -> [PolishIssue] {
        var seen: [String: Int] = [:]
        var out: [PolishIssue] = []
        let ns = text as NSString
        // "very good" is handled by veryIssues; "just" and "get" count only as whole words.
        for m in matches(regex("\\b[A-Za-z]+\\b"), text) {
            let w = ns.substring(with: m.range).lowercased()
            guard overused.contains(w) else { continue }
            seen[w, default: 0] += 1
            if seen[w]! >= 3, let swaps = thesaurus[w],
               let i = make(m.range, text, offset, .style, "You have used \"\(w)\" \(seen[w]!) times. A different word may read better.", swaps.map { matchCase($0, like: ns.substring(with: m.range)) }) {
                out.append(i)
            }
        }
        return out
    }

    private static func longSentences(_ text: String, offset: Int) -> [PolishIssue] {
        var out: [PolishIssue] = []
        for m in matches(regex("[^.!?\\n]+[.!?]?", []), text) {
            let s = sub(text, m.range)
            let n = s.split(whereSeparator: { $0.isWhitespace }).count
            if n >= 38, let i = make(m.range, text, offset, .clarity, "This sentence is \(n) words long. Two shorter ones are easier to read.", []) { out.append(i) }
        }
        return out
    }
}

// MARK: - How it reads

struct WritingStats: Equatable {
    var words: Int
    var sentences: Int
    var readingEase: Double?
    var grade: Double?
    var readingSeconds: Int

    var ease: String {
        guard let r = readingEase else { return "" }
        switch r {
        case 70...: return "Easy to read"
        case 50..<70: return "Plain"
        case 30..<50: return "Fairly hard"
        default: return "Hard"
        }
    }

    static func of(_ text: String) -> WritingStats {
        let words = TextCleaner.wordCount(text)
        let sentences = max(1, RuleChecker.sentenceCount(text))
        let latin = text.split { !($0.isLetter && !RewriteGuard.isCJK($0)) && $0 != "'" }.filter { !$0.isEmpty }
        let seconds = Int((Double(words) / 230.0 * 60).rounded())
        guard latin.count >= 8 else { return WritingStats(words: words, sentences: sentences, readingEase: nil, grade: nil, readingSeconds: seconds) }
        let syllables = latin.reduce(0) { $0 + syllableCount(String($1)) }
        let perSentence = Double(latin.count) / Double(sentences), perWord = Double(syllables) / Double(latin.count)
        let ease = 206.835 - 1.015 * perSentence - 84.6 * perWord
        let grade = 0.39 * perSentence + 11.8 * perWord - 15.59
        return WritingStats(words: words, sentences: sentences, readingEase: max(0, min(100, ease)), grade: max(0, grade), readingSeconds: seconds)
    }

    static func syllableCount(_ word: String) -> Int {
        let w = word.lowercased().filter { $0.isLetter }
        guard !w.isEmpty else { return 0 }
        var count = 0, previousVowel = false
        for c in w {
            let vowel = "aeiouy".contains(c)
            if vowel, !previousVowel { count += 1 }
            previousVowel = vowel
        }
        if w.hasSuffix("e"), !w.hasSuffix("le"), count > 1 { count -= 1 }
        return max(1, count)
    }
}

extension RuleChecker {
    static func sentenceCount(_ text: String) -> Int {
        let re = try! NSRegularExpression(pattern: "[^.!?\\n]+[.!?]*")
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter {
            Range($0.range, in: text).map { text[$0].contains(where: { $0.isLetter || $0.isNumber }) } ?? false
        }.count
    }
}

struct ToneTag: Equatable {
    var name: String
    var note: String
}

enum ToneReader {
    private static let formalWords = ["regards", "sincerely", "kindly", "please find", "pursuant", "i would like to", "i am writing", "dear ", "respectfully", "furthermore", "therefore", "attached"]
    private static let casualWords = ["hey", "yeah", "yep", "nope", "gonna", "wanna", "gotta", "lol", "btw", "haha", "cool", "awesome", "stuff", "guys", "ok ", "okay", "cheers", "lah", "lor", "leh"]
    private static let friendlyWords = ["thanks", "thank you", "appreciate", "glad", "happy to", "love", "great", "wonderful", "looking forward", "hope you", "please", "welcome"]
    private static let urgentWords = ["asap", "urgent", "immediately", "right away", "as soon as possible", "deadline", "by today", "by tomorrow", "today", "now", "critical", "emergency"]
    private static let hedgeWords = ["maybe", "perhaps", "i think", "i guess", "sort of", "kind of", "just wondering", "sorry to", "if possible", "i was wondering", "not sure", "possibly", "a bit", "might be"]
    private static let negativeWords = ["unacceptable", "disappointed", "frustrated", "angry", "terrible", "worst", "annoyed", "ridiculous", "complaint", "upset", "unhappy", "never again"]

    /// Up to three labels for how the text will probably come across. Plain rules plus Apple's on-device sentiment score.
    static func read(_ text: String) -> [ToneTag] {
        let lower = " " + text.lowercased() + " "
        guard TextCleaner.wordCount(text) >= 4 else { return [] }
        func hits(_ list: [String]) -> Int { list.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) } }
        let words = max(1, TextCleaner.wordCount(text))
        let contractions = (try? NSRegularExpression(pattern: "\\b\\w+['’](?:t|s|re|ll|ve|d|m)\\b"))?
            .numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
        let exclaims = text.filter { $0 == "!" }.count
        let sentiment = sentimentScore(text)

        var tags: [(Double, ToneTag)] = []
        let formal = Double(hits(formalWords)) * 2 - Double(hits(casualWords)) - Double(contractions) / Double(max(1, words / 12))
        let casual = Double(hits(casualWords)) * 1.5 + Double(contractions) / Double(max(1, words / 12)) + Double(exclaims) * 0.5
        if formal >= 2 { tags.append((formal, ToneTag(name: "Formal", note: "Polite and professional."))) }
        else if casual >= 2 { tags.append((casual, ToneTag(name: "Casual", note: "Relaxed, like a chat."))) }
        let friendly = Double(hits(friendlyWords)) + Double(exclaims) * 0.5 + max(0, sentiment) * 2
        if friendly >= 2 { tags.append((friendly, ToneTag(name: "Friendly", note: "Warm and positive."))) }
        let urgent = Double(hits(urgentWords)) * 1.5
        if urgent >= 1.5 { tags.append((urgent, ToneTag(name: "Urgent", note: "Reads as time-sensitive."))) }
        let hedges = Double(hits(hedgeWords)) * 1.5
        if hedges >= 1.5 { tags.append((hedges, ToneTag(name: "Hesitant", note: "Softening words such as \"maybe\" or \"I think\"."))) }
        let negative = Double(hits(negativeWords)) * 2 + max(0, -sentiment) * 3
        if negative >= 2 { tags.append((negative, ToneTag(name: "Frustrated", note: "May come across as upset."))) }
        if tags.isEmpty { tags.append((1, ToneTag(name: "Neutral", note: "Matter of fact."))) }
        return tags.sorted { $0.0 > $1.0 }.prefix(3).map { $0.1 }
    }

    /// -1 (negative) to 1 (positive), averaged over paragraphs, from Apple's on-device language model.
    static func sentimentScore(_ text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        var total = 0.0, n = 0.0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .paragraph, scheme: .sentimentScore, options: []) { tag, _ in
            if let t = tag, let v = Double(t.rawValue) { total += v; n += 1 }
            return true
        }
        return n == 0 ? 0 : total / n
    }
}

// MARK: - Rewrites

enum RewriteMode: String, CaseIterable, Identifiable {
    case fix, clearer, shorter, rephrase, friendlier, professional, confident
    /// For people who build with AI: speech or rough notes in, text ready for a coding agent or a code host out.
    case codingPrompt, taskPlan, bugReport, commitMessage, conventionalCommit, pullRequest, codeComment

    var id: String { rawValue }

    /// The everyday writing rewrites, and the ones for builders (coding prompts, commit messages ...), shown as two groups.
    static var writing: [RewriteMode] { allCases.filter { !$0.isBuilder } }
    static var builders: [RewriteMode] { allCases.filter { $0.isBuilder } }

    var isBuilder: Bool {
        switch self {
        case .codingPrompt, .taskPlan, .bugReport, .commitMessage, .conventionalCommit, .pullRequest, .codeComment: return true
        default: return false
        }
    }

    var isCommit: Bool { self == .commitMessage || self == .conventionalCommit }

    /// Rewrites that are allowed to leave out a number or a name from the notes (a commit message is a summary).
    var mayDropDetails: Bool { self == .shorter || isCommit || self == .codeComment }

    var title: String {
        switch self {
        case .fix: return "Fix mistakes"
        case .clearer: return "Make it clearer"
        case .shorter: return "Shorter"
        case .rephrase: return "Rephrase"
        case .friendlier: return "Friendlier"
        case .professional: return "More professional"
        case .confident: return "More confident"
        case .codingPrompt: return "Coding prompt"
        case .taskPlan: return "Step-by-step plan"
        case .bugReport: return "Bug report"
        case .commitMessage: return "Commit message"
        case .conventionalCommit: return "Conventional commit"
        case .pullRequest: return "Pull request"
        case .codeComment: return "Code comment"
        }
    }

    var symbol: String {
        switch self {
        case .fix: return "checkmark.seal"
        case .clearer: return "text.alignleft"
        case .shorter: return "arrow.down.right.and.arrow.up.left"
        case .rephrase: return "arrow.triangle.2.circlepath"
        case .friendlier: return "face.smiling"
        case .professional: return "briefcase"
        case .confident: return "bolt"
        case .codingPrompt: return "terminal"
        case .taskPlan: return "checklist"
        case .bugReport: return "ladybug"
        case .commitMessage: return "arrow.triangle.branch"
        case .conventionalCommit: return "tag"
        case .pullRequest: return "arrow.triangle.pull"
        case .codeComment: return "curlybraces"
        }
    }

    /// How freely the model may word things: low for edits that must stay faithful, higher for a plain rephrase.
    var temperature: Double {
        switch self {
        case .fix: return 0.1
        case .rephrase: return 0.7
        default: return isBuilder ? 0.2 : 0.3
        }
    }

    var instruction: String {
        switch self {
        case .fix: return "Fix spelling, grammar and punctuation only. Do not change the wording, the tone or the order of the sentences."
        case .clearer: return "Make this clearer and easier to read. Split sentences that are too long, cut words that add nothing, and prefer plain words. Keep the meaning."
        case .shorter: return "Make this shorter. Keep the meaning, the names and the numbers. Cut anything that repeats or adds nothing."
        case .rephrase: return "Say the same thing in different words. Change the sentence structure as well as the words. Keep the meaning."
        case .friendlier: return "Rewrite this in a warmer, friendlier tone. Keep the meaning and every fact."
        case .professional: return "Rewrite this in a polite, professional tone suitable for work email. Keep the meaning and every fact."
        case .confident: return "Rewrite this to sound more confident and direct. Remove hedging such as \"I think\", \"maybe\", \"just\" and \"sorry to bother\". Stay polite. Keep the meaning and every fact."
        case .codingPrompt:
            return "Write the notes up as a prompt for an AI coding agent. Open with one plain sentence that states the goal. Then add only the parts the notes really give, each on its own labelled line or short list, in this order: Context: (what exists, what is wrong, where), Requirements: (what to build or change, one point per line), Constraints: (what to follow, reuse or avoid, and what not to touch), Done when: (how to tell it worked, such as a test, a command or something visible). Leave out any label with nothing under it."
        case .taskPlan:
            return "Turn the notes into a plan for an AI coding agent. First a line that states the goal. Then a numbered list of small steps in the order they should be done, each one action that can be checked. Use only steps the notes state or clearly imply; add no extra steps. If the notes name a check to run, make it the last step."
        case .bugReport:
            return "Write the notes up as a bug report. Use these labelled parts and leave out any the notes do not cover: Summary: (one line), What happens:, What should happen:, Steps to reproduce: (numbered), Where: (files, screens, versions, device), Error text: (exactly as given)."
        case .commitMessage:
            return "Write one git commit message from the notes. First line: a short summary in the imperative mood (\"Add\", \"Fix\", \"Remove\"), no full stop, 50 characters or fewer when possible and never more than 72. If the notes give a reason, add a blank line and then a body of one or two plain sentences that say why, not only what. No type prefix and no emoji."
        case .conventionalCommit:
            return "Write one git commit message in the Conventional Commits style from the notes. First line: type(scope): description. The type is one of feat, fix, docs, style, refactor, perf, test, build, ci, chore. Add (scope) only if the notes name an area. The description is lower case, in the imperative mood, with no full stop, and the whole first line is at most 72 characters. If the notes give a reason, add a blank line and a short body. If the notes say existing behaviour breaks, end with a line that starts BREAKING CHANGE: and says what breaks."
        case .pullRequest:
            return "Write a pull request description from the notes. Use these labelled parts and leave out any the notes do not cover: Summary: (what changed, in one or two sentences), Why: (the problem or reason), Changes: (short list), How to test: (steps or commands exactly as given), Notes for the reviewer: (risks, follow-ups, things to check)."
        case .codeComment:
            return "Write a code comment from the notes, not code: one to three short sentences that say what the code does and why, in plain words. Do not add comment marks such as // or #. Do not repeat the code line by line."
        }
    }

    /// How much longer than the original a good answer can be.
    var growth: ClosedRange<Double> {
        switch self {
        case .fix: return 0.7...1.3
        case .shorter: return 0.2...1.02
        case .clearer: return 0.4...1.5
        case .codingPrompt, .taskPlan, .bugReport, .pullRequest: return 0.5...4.0
        case .commitMessage, .conventionalCommit: return 0.1...1.6
        case .codeComment: return 0.1...2.5
        default: return 0.4...2.2
        }
    }
}

enum RewritePrompt {
    static let system = """
    You are a careful editor inside a writing app. You receive a piece of writing and one instruction, and you return only the rewritten text.
    - Keep every name, number, date, amount, link and product word exactly as written.
    - Never add facts, greetings or sign-offs that are not in the text. Never answer questions in the text; rewrite them.
    - Keep the language of the text. If it mixes English with Chinese, Malay or Tamil, or uses words such as lah, lor and leh, keep that mix and those words.
    - Keep line breaks and lists as they are.
    - Output the text only: no quotes, no explanation, no heading.
    """

    /// For the builder modes (coding prompt, commit message ...): the model writes up rough or spoken notes, it never does the task.
    static let builderSystem = """
    You turn spoken or rough notes from someone who builds software into clean text for an AI coding agent or a code host. You return only that text.
    - Use only what the notes say. Never invent a file, function, library, command, number, error message or requirement. If a part is not in the notes, leave that part out.
    - Keep every file name, path, function or variable name, command, flag, version, number, link and error text exactly as written, character for character.
    - Drop filler, false starts and politeness (please, thank you, "hey Claude"). Keep every requirement, constraint and preference, even a small one. Apply the speaker's own corrections ("make that 75, not 50").
    - Write plain text. Use the labels you are asked for, each followed by a colon, and short lines that start with "- " for lists. No Markdown headings, no bold, no code fences, no quotes around the whole output.
    - Never answer a question that is in the notes and never do the task described; only write it up for someone else to do.
    - Keep the language of the notes. If the notes mix English with Chinese, Malay or Tamil, keep that mix.
    - Output the text only: no explanation, no heading of your own.
    """

    static func system(for mode: RewriteMode) -> String { mode.isBuilder ? builderSystem : system }

    static func user(_ text: String, mode: RewriteMode, terms: [String] = []) -> String {
        var s = "Instruction: \(mode.instruction)\n"
        let kept = terms.filter { text.localizedCaseInsensitiveContains($0) }.prefix(20)
        if !kept.isEmpty { s += "Keep these words exactly as spelled: \(kept.joined(separator: ", ")).\n" }
        return s + (mode.isBuilder ? "\nNotes:\n" : "\nText:\n") + text
    }
}

enum RewriteGuard {
    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { u in
            (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value)
                || (0x3040...0x30FF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value)
        }
    }

    static func cjkCount(_ s: String) -> Int { s.filter(isCJK).count }

    /// Digit runs in order, with thousands separators removed, so 75,000 and 75000 agree.
    static func numbers(_ s: String) -> [String] {
        let flat = s.replacingOccurrences(of: "(?<=\\d),(?=\\d{3})", with: "", options: .regularExpression)
        return flat.split { !$0.isNumber }.map(String.init)
    }

    /// Runs of ordinary digits, thousands separators removed. (`numbers` also counts Chinese numerals such as the 一 in 一下.)
    static func digitRuns(_ s: String) -> [String] {
        let flat = s.replacingOccurrences(of: "(?<=\\d),(?=\\d{3})", with: "", options: .regularExpression)
        return flat.split { !($0.isASCII && $0.isNumber) }.map(String.init)
    }

    static func chineseNumerals(_ s: String) -> Set<String> {
        let numerals = Set("零〇一二三四五六七八九十百千万亿两")
        var runs = Set<String>(), run = ""
        for c in s { if numerals.contains(c) { run.append(c) } else if !run.isEmpty { runs.insert(run); run = "" } }
        if !run.isEmpty { runs.insert(run) }
        return runs
    }

    /// Things a builder writes that must come out exactly as they went in: `backtick` spans, file names and paths, snake_case and
    /// camelCase names, calls like save(), --flags, links, versions, @mentions and #issue numbers.
    static func codeTokens(_ s: String) -> [String] {
        let exts = "swift|ts|tsx|js|jsx|mjs|py|rs|go|rb|java|kt|c|h|cpp|hpp|cs|php|sh|zsh|md|json|yaml|yml|toml|css|scss|html|xml|sql|txt|lock|env|plist|ini|cfg|csv|png|jpg|svg"
        // (pattern, capture group to keep, ignore case, is a bare path that needs the slash checks below)
        let patterns: [(String, Int, Bool, Bool)] = [
            ("`([^`\\n]+)`", 1, false, false),
            ("https?://[^\\s)\\]>\"']+", 0, false, false),
            ("(?<![\\w])[\\w./@~-]*[\\w-]\\.(?:\(exts))\\b", 0, true, false),
            ("(?<![\\w/.~])(?:\\.{1,2}/|~/|/)?[\\w.-]+(?:/[\\w.-]+)+/?", 0, false, true),
            ("\\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\\b", 0, false, false),
            ("\\b[a-z]+(?:[A-Z][a-z0-9]*)+\\b", 0, false, false),
            ("\\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]*)+\\b", 0, false, false),
            ("\\b[A-Za-z_][\\w.]*\\(\\)", 0, false, false),
            ("(?<![\\w-])--[A-Za-z][\\w-]*", 0, false, false),
            ("(?<=\\s)-[A-Za-z]\\b(?!-)", 0, false, false),
            ("\\bv?\\d+\\.\\d+(?:\\.\\d+)+\\b", 0, false, false),
            ("(?<![\\w])[@#][\\w./-]*\\w", 0, false, false),
        ]
        var found: [String] = []
        let ns = s as NSString
        for (pattern, group, ignoreCase, barePath) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: group)
                guard r.location != NSNotFound else { continue }
                let token = ns.substring(with: r).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'"))
                if barePath {
                    // A slash alone is not a path ("and/or", "24/7"): it needs two slashes, a leading ./ ../ ~/ / or a trailing /.
                    let slashes = token.filter { $0 == "/" }.count
                    let anchored = token.hasPrefix("./") || token.hasPrefix("../") || token.hasPrefix("~/") || token.hasPrefix("/") || token.hasSuffix("/")
                    guard slashes >= 2 || anchored, token.contains(where: { $0.isLetter }) else { continue }
                }
                if token.count >= 2 { found.append(token) }
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The same digit runs `digitRuns` finds, but not the 1. 2. 3. a list adds in front of its lines.
    static func digitRunsIgnoringListMarkers(_ s: String) -> [String] {
        digitRuns(s.replacingOccurrences(of: "(?m)^\\s*\\d{1,2}[.)]\\s+", with: "", options: .regularExpression))
    }

    /// Strips the wrapping a chatty model adds: <think> blocks, code fences, quotes around everything, "Here is ...".
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```"), t.hasSuffix("```") {
            t = t.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        if t.count > 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("“") && t.hasSuffix("”")) {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a rewrite is safe to show. It never judges whether the rewrite is good, only whether it broke something that
    /// must not break: a number was invented or changed, one of your words was lost, the language switched, or the model
    /// answered the text instead of rewriting it.
    static func looksLikeRewrite(original: String, rewritten: String, mode: RewriteMode, protectedTerms: [String] = []) -> Bool {
        let a = original.trimmingCharacters(in: .whitespacesAndNewlines), b = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, !a.isEmpty else { return false }
        let ratio = Double(b.count) / Double(a.count)
        guard mode.growth.contains(ratio) || a.count < 40 else { return false }
        // Language must not change.
        let cjkA = cjkCount(a), cjkB = cjkCount(b)
        if cjkA >= 2, Double(cjkB) < 0.6 * Double(cjkA) { return false }
        if cjkA == 0, cjkB > 0 { return false }
        // Numbers: none invented, and the ones kept stay in order. "Shorter" may drop some.
        // A builder's list adds 1. 2. 3. in front of lines and moves things under labels, so list markers are ignored and order is not checked.
        let na = mode.isBuilder ? digitRunsIgnoringListMarkers(a) : digitRuns(a)
        let nb = mode.isBuilder ? digitRunsIgnoringListMarkers(b) : digitRuns(b)
        guard Set(nb).isSubset(of: Set(na)) else { return false }
        guard chineseNumerals(b).isSubset(of: chineseNumerals(a)) else { return false }
        if mode != .shorter, mode != .confident, !mode.mayDropDetails, Set(na) != Set(nb) { return false }
        if !mode.isBuilder {
            var i = na.startIndex
            for n in nb {
                guard let j = na[i...].firstIndex(of: n) else { return false }
                i = j + 1
            }
        }
        // Your words (names, products) survive exactly as spelled.
        for term in protectedTerms where term.count > 2 && a.contains(term) && !b.contains(term) {
            if mode.mayDropDetails { continue }
            return false
        }
        if mode.isBuilder {
            // File names, identifiers, flags and links survive character for character (a commit message may leave some out).
            if !mode.mayDropDetails {
                for token in codeTokens(a) where !b.contains(token) { return false }
            }
            // A commit message starts with a short summary line.
            if mode.isCommit, (b.components(separatedBy: "\n").first ?? "").count > 72 { return false }
        }
        let lower = b.lowercased()
        for tell in ["here is", "here's the", "here are", "sure,", "sure!", "certainly", "as an ai", "i cannot", "i can't", "rewritten text"] where lower.hasPrefix(tell) {
            return false
        }
        return true
    }
}
