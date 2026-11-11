import AppKit
import ApplicationServices
import Foundation

// Learning from your own typing, and showing whether Purrscribe is getting better for you.
//
// Purrscribe already learns when you fix a word in text it typed. This adds, once you switch it on, the fixes you make in your
// own typing: you type a name wrongly, backspace and write it again. It does not record keystrokes. It looks at the line you are
// on every half second, and only when a word on that line was replaced by an unusual word (a name, a product, jargon), and it is a clear spelling fix or has been seen twice, does it
// remember the spelling, which is then given to the speech engine as a hint. No text is kept, only that word. Password fields,
// password managers, terminals and Purrscribe itself are never looked at.

enum TypingRules {
    static let skipPrefixes = Redact.neverRecord + ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp", "com.mitchellh.ghostty",
                                                    "net.kovidgoyal.kitty", "org.alacritty", "com.momominibot.freeflow"]

    static func skips(bundle: String) -> Bool {
        let b = bundle.lowercased()
        return skipPrefixes.contains { b.hasPrefix($0) }
    }

    /// The line the caret is on (cut to 400 characters around the caret) and where it starts in the whole text.
    static func line(in value: String, caret: Int) -> (text: String, start: Int) {
        let ns = value as NSString
        let c = max(0, min(caret, ns.length))
        let lr = ns.lineRange(for: NSRange(location: c, length: 0))
        var start = lr.location, end = lr.location + lr.length
        if end - start > 400 { start = max(start, c - 200); end = min(end, c + 200) }
        let text = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .newlines)
        return (text, start)
    }

    /// A word on the line replaced by an unusual word or a name: kept. A typo fixed into an everyday word, a rewrite, an addition: not kept.
    static func pairs(previous: String, current: String, isCommon: (String) -> Bool) -> [Learning.Pair] {
        guard previous != current, !previous.isEmpty, !current.isEmpty, previous.count <= 400, current.count <= 400 else { return [] }
        return Learning.pairs(original: previous, edited: current).filter { p in
            // finishing the word you were still typing ("Ranklo" then "Ranklore" at the end of the line) is not a correction
            !(previous.hasSuffix(p.wrong) && p.right.lowercased().hasPrefix(p.wrong.lowercased()))
                && !Learning.hasCJK(p.wrong) && !Learning.hasCJK(p.right)
                && p.right.count >= 4 && !p.right.contains(" ") && !p.right.contains { $0.isNumber }
                && !(isCommon(p.right) && isCommon(p.right.lowercased()))     // a name the Mac knows only with its capital is still a name
        }
    }

    /// Clear enough to keep the first time: close in spelling to what it replaced, and not a word being deleted or typed.
    /// Spaces and capitals do not count, so "live loom" becoming "LifeLoom" is one letter away.
    static func confident(_ p: Learning.Pair) -> Bool {
        let w = Array(p.wrong.lowercased().filter { !$0.isWhitespace })
        let r = Array(p.right.lowercased().filter { !$0.isWhitespace })
        guard w.count >= 3, r.count >= 4, p.wrong != p.right else { return false }
        if w.count > r.count && w.starts(with: r) { return false }            // "store da" cut down to "stor": a word being deleted
        if r.starts(with: w) && r.count - w.count > 2 { return false }        // a word still being typed
        return Learning.distance(w, r) <= max(2, r.count / 4)
    }
}

/// A spelling that is not clearly a fix is only remembered after you have fixed it the same way twice, so one slip teaches nothing.
struct TypingSeen {
    var counts: [String: Int] = [:]
    static let keep = 200

    mutating func see(_ pairs: [Learning.Pair], needed: Int = 2) -> [Learning.Pair] {
        var ready: [Learning.Pair] = []
        for p in pairs {
            let key = p.wrong.lowercased() + " > " + p.right
            counts[key, default: 0] += 1
            if counts[key, default: 0] >= needed { counts[key] = nil; ready.append(p) }
        }
        if counts.count > Self.keep {
            for k in counts.sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) }).prefix(counts.count - Self.keep) { counts[k.key] = nil }
        }
        return ready
    }
}

/// Compares settled versions of the line you are typing on. While you backspace a word the line passes through half-deleted
/// states; those never count, only a version that stayed the same for a moment does.
struct TypingTracker {
    private var current: (text: String, start: Int, since: Date)?
    private var history: [(text: String, start: Int)] = []     // the last few settled versions of this line, oldest first
    private var processed: Date?
    static let settleAfter: TimeInterval = 1.2
    static let remember = 4

    mutating func reset() { current = nil; history = []; processed = nil }

    /// One look at the line. Returns the pairs found when the line has just settled in a new state. The new version is compared
    /// with the last few settled ones, because a pause after deleting a word leaves a half-deleted version that settles too; the
    /// fix is still found against the version from before the deletion.
    mutating func observe(text: String, start: Int, sameField: Bool, at now: Date, isCommon: (String) -> Bool) -> [Learning.Pair] {
        guard sameField, let c = current, c.start == start else {
            reset()
            current = (text, start, now)
            return []
        }
        if c.text != text {
            current = (text, start, now)
            return []
        }
        guard now.timeIntervalSince(c.since) >= Self.settleAfter, processed != c.since else { return [] }
        processed = c.since
        if history.last?.text == text { return [] }
        var found: [Learning.Pair] = []
        for old in history.reversed() where old.start == start {
            for p in TypingRules.pairs(previous: old.text, current: text, isCommon: isCommon) where !found.contains(p) { found.append(p) }
        }
        history.append((text, start))
        if history.count > Self.remember { history.removeFirst(history.count - Self.remember) }
        return found
    }
}

final class TypingLearner {
    var onLearned: (([Learning.Pair]) -> Void)?
    var log: (String) -> Void = { _ in }
    private var timer: Timer?
    private var element: AXUIElement?
    private var tracker = TypingTracker()
    private var seen = TypingSeen(counts: Settings.counts(Settings.shared.typingSeenRaw))
    /// Clear fixes waiting to stand for a while before they are kept, so a word you then change again is not kept.
    private var waiting: [(pair: Learning.Pair, since: Date)] = []
    static let keepAfter: TimeInterval = 20

    var running: Bool { timer != nil }

    func start() {
        guard timer == nil, AXIsProcessTrusted() else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        log("typing: learning from my typing is on")
        keepEarlierFixes()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        tracker.reset()
        log("typing: learning from my typing is off")
    }

    /// One look, described in words and numbers only (never the text), for the smoke test and for "why is it not learning".
    func probe() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return "typing: probe: no front app" }
        if TypingRules.skips(bundle: bundle) { return "typing: probe: \(bundle) is never looked at" }
        guard let snap = Inserter.caretSnapshot() else { return "typing: probe: \(bundle) shows no readable text box with the cursor in it" }
        let line = TypingRules.line(in: snap.value, caret: snap.caret)
        return "typing: probe: \(bundle), line of \(line.text.count) characters, running \(running), seen \(seen.counts.count)"
    }

    private func keep(_ pairs: [Learning.Pair]) {
        let learned = Learning.learn(pairs)
        if !learned.isEmpty {
            log("typing: learned \(learned.map { "\($0.wrong) -> \($0.right)" }.joined(separator: ", "))")
            onLearned?(learned)
        }
    }

    /// Keeps the clear fixes that have stood for `keepAfter` seconds.
    private func keepSettled(now: Date = Date()) {
        let due = waiting.filter { now.timeIntervalSince($0.since) >= Self.keepAfter }.map { $0.pair }
        guard !due.isEmpty else { return }
        waiting.removeAll { w in due.contains(w.pair) }
        keep(due)
    }

    /// Fixes that were seen once before "keep the first time" was on and pass the same check are kept now. A fix that was only a
    /// stage of a longer one (its right-hand side was later changed again) is not.
    func keepEarlierFixes() {
        guard Settings.shared.learnTypingAtOnce else { return }
        var pairs: [(key: String, pair: Learning.Pair)] = []
        for key in seen.counts.keys {
            let parts = key.components(separatedBy: " > ")
            if parts.count == 2 { pairs.append((key, Learning.Pair(wrong: parts[0], right: parts[1]))) }
        }
        let wrongs = Set(pairs.map { $0.pair.wrong.lowercased() })
        let ready = pairs.filter { TypingRules.confident($0.pair) && !wrongs.contains($0.pair.right.lowercased()) }
        guard !ready.isEmpty else { return }
        for r in ready { seen.counts[r.key] = nil }
        Settings.shared.typingSeenRaw = seen.counts
        keep(ready.map { $0.pair })
    }

    private func tick() {
        keepSettled()
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier, !TypingRules.skips(bundle: bundle),
              let snap = Inserter.caretSnapshot(), snap.value.utf16.count <= 60_000 else {
            element = nil; tracker.reset(); return
        }
        let line = TypingRules.line(in: snap.value, caret: snap.caret)
        let same = element.map { CFEqual($0, snap.element) } ?? false
        element = snap.element
        let found = tracker.observe(text: line.text, start: line.start, sameField: same, at: Date(), isCommon: Learning.isEnglishWord)
        guard !found.isEmpty else { return }
        // A clear spelling fix is kept the first time, once it has stood for a while; anything less clear needs a second sighting.
        var others = found
        if Settings.shared.learnTypingAtOnce {
            let sure = found.filter(TypingRules.confident)
            others = found.filter { !TypingRules.confident($0) }
            let now = Date()
            for p in sure {
                // a stage of a longer fix ("witsu" to "witzu" before "witzu" to "witzu.vercel.app") is not a spelling to keep
                if sure.contains(where: { $0.wrong.lowercased() == p.right.lowercased() }) { continue }
                waiting.removeAll { $0.pair.right.lowercased() == p.wrong.lowercased() }
                if !waiting.contains(where: { $0.pair == p }) { waiting.append((p, now)) }
            }
            if !sure.isEmpty { log("typing: a clear fix seen, kept in \(Int(Self.keepAfter)) seconds unless you change it again") }
        }
        guard !others.isEmpty else { return }
        let ready = seen.see(others)
        if ready.isEmpty { log("typing: a possible fix seen once, waiting to see it again before keeping it") }
        Settings.shared.typingSeenRaw = seen.counts
        guard !ready.isEmpty else { return }
        keep(ready)
    }
}

// MARK: - Is it getting better?

enum LearningStats {
    struct Week: Equatable {
        let fixes: Int
        let words: Int
        var per100: Double { words > 0 ? Double(fixes) * 100 / Double(words) : 0 }
    }

    static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// The last 7 days and the 7 before them: fixes you made, words you dictated.
    static func weeks(fixesByDay: [String: Int], daily: [(day: Date, words: Int)], cal: Calendar = .current) -> (this: Week, last: Week) {
        func week(_ days: ArraySlice<(day: Date, words: Int)>) -> Week {
            Week(fixes: days.reduce(0) { $0 + (fixesByDay[dayKey($1.day, cal)] ?? 0) }, words: days.reduce(0) { $0 + $1.words })
        }
        let d = daily.sorted { $0.day < $1.day }
        guard d.count >= 14 else { return (week(d.suffix(7)), Week(fixes: 0, words: 0)) }
        return (week(d.suffix(7)), week(d.dropLast(7).suffix(7)))
    }

    static func verdict(this: Week, last: Week) -> String {
        if this.words < 100 { return "Not enough dictation this week to tell. Keep going." }
        let now = String(format: "%.1f", this.per100)
        guard last.words >= 100 else { return "This week: \(now) fixes per 100 words. Next week there will be something to compare it with." }
        let before = String(format: "%.1f", last.per100)
        if this.per100 <= last.per100 * 0.8 { return "Down from \(before) to \(now) fixes per 100 words. It is getting more accurate for you." }
        if this.per100 >= last.per100 * 1.25 { return "Up from \(before) to \(now) fixes per 100 words. New names, new topics or a noisy room do that. It keeps learning." }
        return "About the same as last week: \(now) fixes per 100 words."
    }
}
