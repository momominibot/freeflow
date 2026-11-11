import AppKit
import ApplicationServices

/// Purrscribe learns your words from your own fixes. Everything lives in learned.txt on this Mac.
///
/// The loop: Purrscribe types text, you correct a word, `CorrectionWatcher` sees the change, `Learning.pairs`
/// turns it into "heard -> meant" pairs, `LearnedFile` counts votes, and `Vocabulary.addLearned` feeds the
/// result back to both speech engines (as hotwords in the prompt) and to the post-transcription swaps.
enum Learning {
    struct Pair: Equatable {
        let wrong: String
        let right: String
    }

    struct Token {
        let text: String
        let range: NSRange
    }

    // MARK: - Tokens

    private static let cjkClass = #"\x{3400}-\x{4DBF}\x{4E00}-\x{9FFF}"#

    /// A Latin word (letters, digits, and ' + & . - inside it, so EMIS+ and reinstate.sg stay whole) or one Chinese character.
    private static let tokenRE: NSRegularExpression = {
        let word = #"[[\p{L}\p{N}]&&[^"# + cjkClass + #"]]"#
        let inner = #"[[\p{L}\p{N}'’+\&.\-]&&[^"# + cjkClass + #"]]"#
        let last = #"[[\p{L}\p{N}+]&&[^"# + cjkClass + #"]]"#
        return try! NSRegularExpression(pattern: "[" + cjkClass + "]|" + word + "(?:" + inner + "*" + last + ")?")
    }()

    static func tokenize(_ s: String) -> [Token] {
        let ns = s as NSString
        return tokenRE.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            Token(text: ns.substring(with: $0.range), range: $0.range)
        }
    }

    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    /// Letters and digits only, lower case: what "sounds the same on paper".
    private static func skeleton(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    // MARK: - What did the user change?

    /// Word-level "heard -> meant" pairs between what Purrscribe typed and what the text says now.
    /// Only substitutions that look like a speech slip are returned: a rewrite, a number change or a
    /// sentence-start capital is the person writing, not the engine mishearing.
    static func pairs(original: String, edited: String) -> [Pair] {
        let a = tokenize(original), b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= 400, b.count <= 500 else { return [] }

        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var hunks: [(a: Range<Int>, b: Range<Int>)] = []
        var i = 0, j = 0, gapA = 0, gapB = 0
        while i < a.count, j < b.count {
            if a[i].text == b[j].text {
                if i > gapA || j > gapB { hunks.append((gapA..<i, gapB..<j)) }
                i += 1; j += 1; gapA = i; gapB = j
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        if a.count > gapA || b.count > gapB { hunks.append((gapA..<a.count, gapB..<b.count)) }
        guard !hunks.isEmpty else { return [] }

        // Much of the text changed: the person rewrote it. Short phrases are judged by similarity instead.
        let changed = hunks.reduce(0) { $0 + max($1.a.count, $1.b.count) }
        if a.count > 4, Double(changed) / Double(a.count) > 0.5 { return [] }

        let o = original as NSString, e = edited as NSString
        func adjacent(_ x: Token, _ y: Token) -> Bool { x.range.location + x.range.length == y.range.location }
        func isCJKToken(_ t: Token) -> Bool { hasCJK(t.text) }

        var out: [Pair] = []
        for var h in hunks {
            guard !h.a.isEmpty, !h.b.isEmpty, h.a.count <= 5, h.b.count <= 5 else { continue }
            // One changed Chinese character is too small to swap on its own: take a neighbour along.
            if h.a.count == 1, h.b.count == 1, isCJKToken(a[h.a.lowerBound]), isCJKToken(b[h.b.lowerBound]) {
                if h.a.lowerBound > 0, h.b.lowerBound > 0, isCJKToken(a[h.a.lowerBound - 1]),
                   adjacent(a[h.a.lowerBound - 1], a[h.a.lowerBound]) {
                    h.a = (h.a.lowerBound - 1)..<h.a.upperBound
                    h.b = (h.b.lowerBound - 1)..<h.b.upperBound
                } else if h.a.upperBound < a.count, h.b.upperBound < b.count, isCJKToken(a[h.a.upperBound]),
                          adjacent(a[h.a.upperBound - 1], a[h.a.upperBound]) {
                    h.a = h.a.lowerBound..<(h.a.upperBound + 1)
                    h.b = h.b.lowerBound..<(h.b.upperBound + 1)
                }
            }
            let af = a[h.a.lowerBound], al = a[h.a.upperBound - 1]
            let bf = b[h.b.lowerBound], bl = b[h.b.upperBound - 1]
            let wrong = o.substring(with: NSRange(location: af.range.location, length: al.range.location + al.range.length - af.range.location))
            let right = e.substring(with: NSRange(location: bf.range.location, length: bl.range.location + bl.range.length - bf.range.location))
            let wholeShortText = a.count <= 4 && h.a.count == a.count
            if looksLikeSpeechSlip(wrong: wrong, right: right, strict: wholeShortText) {
                let p = Pair(wrong: wrong, right: right)
                if !out.contains(p) { out.append(p) }
            }
        }
        return out
    }

    static func looksLikeSpeechSlip(wrong w: String, right r: String, strict: Bool = false) -> Bool {
        if w == r { return false }
        let sw = skeleton(w), sr = skeleton(r)
        if sw == sr {
            guard w.lowercased() == r.lowercased() else { return true } // spacing or punctuation: "Rank Lore" -> "Ranklore"
            // Case only. A sentence-start capital is not a correction; EMIS or iPhone is.
            let upFirst = String(w.prefix(1)).uppercased() + w.dropFirst()
            let lowFirst = String(w.prefix(1)).lowercased() + w.dropFirst()
            return r != upFirst && r != lowFirst
        }
        if w.contains(where: { $0.isNumber }) || r.contains(where: { $0.isNumber }) { return false }
        if hasCJK(w) || hasCJK(r) {
            guard hasCJK(w), hasCJK(r), !w.contains(where: { $0.isASCII && $0.isLetter }), !r.contains(where: { $0.isASCII && $0.isLetter }) else { return false }
            return sw.count >= 2 && sr.count >= 1 && sw.count <= 6 && sr.count <= 6
        }
        guard sw.count >= 2, !sr.isEmpty else { return false }
        let d = Double(distance(Array(sw), Array(sr))) / Double(max(sw.count, sr.count))
        return d <= (strict ? 0.5 : 0.7)
    }

    // MARK: - Finding the typed text again

    /// What surrounded the text Purrscribe typed, so it can be found again after the user edits around it.
    struct Anchors {
        var prefix: String
        var suffix: String
        var start: Int
        var length: Int
    }

    static func anchors(in value: String, start: Int, length: Int, width: Int = 24) -> Anchors? {
        let ns = value as NSString
        guard start >= 0, length > 0, start + length <= ns.length else { return nil }
        let p0 = max(0, start - width)
        let end = start + length
        let s1 = min(ns.length, end + width)
        return Anchors(prefix: ns.substring(with: NSRange(location: p0, length: start - p0)),
                       suffix: ns.substring(with: NSRange(location: end, length: s1 - end)),
                       start: start, length: length)
    }

    /// The text between the two anchors as it reads now, or nil if either anchor was edited away.
    static func span(_ a: Anchors, in value: String) -> String? {
        let ns = value as NSString
        var from = 0
        if !a.prefix.isEmpty {
            var best: NSRange?
            var searchFrom = 0
            while searchFrom <= ns.length {
                let r = ns.range(of: a.prefix, options: [], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                if r.location == NSNotFound { break }
                if best == nil || abs(r.location + r.length - a.start) < abs(best!.location + best!.length - a.start) { best = r }
                searchFrom = r.location + 1
            }
            guard let b = best else { return nil }
            from = b.location + b.length
        }
        var to: Int
        if a.suffix.isEmpty {
            to = min(ns.length, from + a.length + 40) // text typed after it is not part of it
        } else {
            let r = ns.range(of: a.suffix, options: [], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { return nil }
            to = r.location
        }
        guard to >= from, to - from <= a.length * 2 + 60 else { return nil }
        return ns.substring(with: NSRange(location: from, length: to - from))
    }

    // MARK: - Storing

    /// Counts the pairs in learned.txt and returns them, so the caller can say what was learned.
    /// Set by `--probe-learn` so a live check can show what would be learned without touching learned.txt.
    static var dryRun = false

    @discardableResult
    static func learn(_ pairs: [Pair], weight: Int = 1) -> [Pair] {
        guard !pairs.isEmpty else { return [] }
        if dryRun { return pairs }
        var f = LearnedFile.load()
        f.record(pairs, weight: weight, today: Settings.today)
        f.save()
        Settings.shared.addFixes(pairs.count)
        return pairs
    }

    static func isEnglishWord(_ w: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}

/// learned.txt: plain text you can read and edit. Delete a line to forget it.
struct LearnedFile {
    struct Fix {
        var wrong: String
        var right: String
        var votes: Int
        var last: String
    }

    struct Term {
        var term: String
        var votes: Int
        var last: String
    }

    var fixes: [Fix] = []
    var terms: [Term] = []

    static let header = """
    # Learned by Purrscribe from your corrections. This file stays on this Mac.
    # Delete a line to forget it. Changes apply to the next thing you dictate.
    # fix | what it heard | what you meant | times | last seen
    # term | word | times | last seen
    """

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ text: String) -> LearnedFile {
        var f = LearnedFile()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 5, parts[0] == "fix", !parts[1].isEmpty, !parts[2].isEmpty, let v = Int(parts[3]) {
                f.fixes.append(Fix(wrong: parts[1], right: parts[2], votes: v, last: parts[4]))
            } else if parts.count >= 4, parts[0] == "term", !parts[1].isEmpty, let v = Int(parts[2]) {
                f.terms.append(Term(term: parts[1], votes: v, last: parts[3]))
            }
        }
        return f
    }

    func render() -> String {
        var lines = [Self.header, ""]
        for x in fixes.sorted(by: { ($0.votes, $0.last) > ($1.votes, $1.last) }) {
            lines.append("fix | \(Self.clean(x.wrong)) | \(Self.clean(x.right)) | \(x.votes) | \(x.last)")
        }
        lines.append("")
        for x in terms.sorted(by: { ($0.votes, $0.last) > ($1.votes, $1.last) }) {
            lines.append("term | \(Self.clean(x.term)) | \(x.votes) | \(x.last)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func load() -> LearnedFile {
        parse((try? String(contentsOf: Paths.learned, encoding: .utf8)) ?? "")
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? render().write(to: Paths.learned, atomically: true, encoding: .utf8)
    }

    mutating func record(_ pairs: [Learning.Pair], weight: Int = 1, today: String) {
        for p in pairs {
            if let i = fixes.firstIndex(where: { $0.wrong.lowercased() == p.wrong.lowercased() && $0.right == p.right }) {
                fixes[i].votes += weight
                fixes[i].last = today
            } else {
                fixes.append(Fix(wrong: p.wrong, right: p.right, votes: weight, last: today))
            }
            if let i = terms.firstIndex(where: { $0.term == p.right }) {
                terms[i].votes += weight
                terms[i].last = today
            } else {
                terms.append(Term(term: p.right, votes: weight, last: today))
            }
        }
        prune(today: today)
    }

    /// Single fixes fade after half a year; the lists stay small.
    mutating func prune(today: String, keep: Int = 300) {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        if let d = fmt.date(from: today), let cutoff = Calendar.current.date(byAdding: .day, value: -180, to: d) {
            let c = fmt.string(from: cutoff)
            fixes.removeAll { $0.votes <= 1 && $0.last < c }
            terms.removeAll { $0.votes <= 1 && $0.last < c }
        }
        if fixes.count > keep { fixes = Array(fixes.sorted { ($0.votes, $0.last) > ($1.votes, $1.last) }.prefix(keep)) }
        if terms.count > keep { terms = Array(terms.sorted { ($0.votes, $0.last) > ($1.votes, $1.last) }.prefix(keep)) }
    }

    /// How many times the same fix must be made before it is applied on its own.
    /// A made-up word ("Ranklor") is safe to swap after one fix; a real English word ("their") is not.
    static func votesNeeded(for wrong: String, isCommon: (String) -> Bool) -> Int {
        let toks = Learning.tokenize(wrong)
        if toks.count != 1 || Learning.hasCJK(wrong) { return 2 }
        return isCommon(wrong) ? 3 : 1
    }

    func activeFixes(isCommon: (String) -> Bool) -> [(wrong: String, right: String)] {
        var best: [String: Fix] = [:]
        var runnerUp: [String: Int] = [:]
        for f in fixes {
            let k = f.wrong.lowercased()
            if let cur = best[k] {
                if f.votes > cur.votes { runnerUp[k] = cur.votes; best[k] = f } else { runnerUp[k] = max(runnerUp[k] ?? 0, f.votes) }
            } else {
                best[k] = f
            }
        }
        return best.values
            .filter { f in
                let k = f.wrong.lowercased()
                // "Kobi" -> "Kobi Wong" would turn an already-right "Kobi Wong" into "Kobi Wong Wong".
                return !Self.containsAsWholeWord(k, in: f.right.lowercased())
                    && f.votes >= Self.votesNeeded(for: f.wrong, isCommon: isCommon)
                    && f.votes > (runnerUp[k] ?? 0)
            }
            .sorted { ($0.votes, $0.last) > ($1.votes, $1.last) }
            .map { ($0.wrong, $0.right) }
    }

    /// True when `needle` sits inside `text` as its own word(s) and `text` is longer: "kobi" in "kobi wong", not "ranklor" in "ranklore".
    static func containsAsWholeWord(_ needle: String, in text: String) -> Bool {
        guard text != needle else { return false }
        var pattern = NSRegularExpression.escapedPattern(for: needle)
        if needle.first.map({ $0.isLetter || $0.isNumber }) == true { pattern = "(?<![\\p{L}\\p{N}])" + pattern }
        if needle.last.map({ $0.isLetter || $0.isNumber }) == true { pattern += "(?![\\p{L}\\p{N}])" }
        return (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func topTerms(_ n: Int) -> [String] {
        terms.sorted { ($0.votes, $0.last) > ($1.votes, $1.last) }.prefix(n).map { $0.term }
    }
}

/// After Purrscribe types, reads that one text box for a while to see which words the user changed.
/// Skips password fields, keeps nothing but the word pairs, and does nothing without Accessibility.
final class CorrectionWatcher {
    var onLearned: (([Learning.Pair]) -> Void)?

    private var element: AXUIElement?
    private var anchors: Learning.Anchors?
    private var pasted = ""
    private var timer: Timer?
    private var started = Date()
    private var lastSpan: String?
    private var changedAt = Date()

    private let giveUpAfter: TimeInterval = 240      // people often read it through before they fix a word
    private let settledFor: TimeInterval = 8

    var isWatching: Bool { timer != nil }

    func begin(pasted text: String) {
        finish()
        guard Settings.shared.learnFromFixes, AXIsProcessTrusted(),
              let snap = Inserter.caretSnapshot() else { return }
        let ns = snap.value as NSString
        let len = (text as NSString).length
        var start = snap.caret - len
        if start < 0 || start + len > ns.length || ns.substring(with: NSRange(location: start, length: len)) != text {
            let r = ns.range(of: text, options: .backwards)
            guard r.location != NSNotFound else { return }
            start = r.location
        }
        guard let a = Learning.anchors(in: snap.value, start: start, length: len) else { return }
        element = snap.element
        anchors = a
        pasted = text
        started = Date()
        lastSpan = nil
        changedAt = Date()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard let el = element, let a = anchors, let value = Inserter.readValue(el) else { return finish() }
        if let span = Learning.span(a, in: value), span != lastSpan {
            lastSpan = span
            changedAt = Date()
        }
        let differs = (lastSpan ?? pasted).trimmingCharacters(in: .whitespacesAndNewlines) != pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if Date().timeIntervalSince(started) > giveUpAfter || (differs && Date().timeIntervalSince(changedAt) >= settledFor) {
            finish()
        }
    }

    /// Judges the last settled version of the text, once.
    func finish() {
        timer?.invalidate()
        timer = nil
        defer { element = nil; anchors = nil; lastSpan = nil; pasted = "" }
        guard let edited = lastSpan else { return }
        let before = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before != after else { return }
        let learned = Learning.learn(Learning.pairs(original: before, edited: after))
        if !learned.isEmpty { onLearned?(learned) }
    }
}
