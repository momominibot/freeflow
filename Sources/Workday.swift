import AppKit
import ApplicationServices
import Foundation

// Workday: a private log of which app and window you are in, so FreeFlow can spot routines worth automating.
// By itself it keeps no screenshots and no text from your screen: only the app, a cleaned-up window title and the time, on this Mac,
// for 14 days. Password managers and private windows are never recorded. Detail.swift holds the optional deeper notes.

// MARK: - What is stored

struct WorkSegment: Codable, Equatable {
    var start: Date
    var end: Date
    var bundle: String
    var name: String
    var title: String
    var idle: Bool

    var seconds: Double { end.timeIntervalSince(start) }

    enum CodingKeys: String, CodingKey { case s, e, app, name, title, idle }

    init(start: Date, end: Date, bundle: String, name: String, title: String, idle: Bool) {
        self.start = start; self.end = end; self.bundle = bundle; self.name = name; self.title = title; self.idle = idle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .s))
        end = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .e))
        bundle = try c.decode(String.self, forKey: .app)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? bundle
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        idle = try c.decodeIfPresent(Bool.self, forKey: .idle) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start.timeIntervalSince1970.rounded(), forKey: .s)
        try c.encode(end.timeIntervalSince1970.rounded(), forKey: .e)
        try c.encode(bundle, forKey: .app)
        try c.encode(name, forKey: .name)
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        if idle { try c.encode(true, forKey: .idle) }
    }
}

// MARK: - Keeping private things out

enum Redact {
    /// Never recorded at all: the app is not even counted.
    static let neverRecord = ["com.1password", "com.agilebits", "com.bitwarden", "com.apple.keychainaccess", "com.apple.passwords",
                              "org.keepassxc", "com.lastpass", "com.dashlane"]
    static let hideWords = ["private browsing", "incognito", "inprivate", "private window"]

    static func skips(bundle: String) -> Bool {
        let b = bundle.lowercased()
        return neverRecord.contains { b.hasPrefix($0) }
    }

    /// The app is counted but its window title is replaced by "(hidden)".
    static func hidden(title: String, extra: [String]) -> Bool {
        let t = title.lowercased()
        return (hideWords + extra).contains { !$0.isEmpty && t.contains($0.lowercased()) }
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static let patterns: [(NSRegularExpression, String)] = [
        (re("[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"), "<email>"),
        (re("https?://\\S+"), "<link>"),
        (re("\\b(?:sk|pk|shpat|shpss|ghp|gho|xox[bap])[-_][A-Za-z0-9_-]{8,}"), "<key>"),
        (re("\\b[A-Za-z0-9_-]{28,}\\b"), "<key>"),
        (re("\\d[\\d ,.\\-]{7,}\\d"), "<number>"),
    ]

    /// A window title with emails, links, keys and long numbers swapped for a tag, and cut to 100 characters.
    static func title(_ s: String) -> String {
        var out = s
        for (r, w) in patterns { out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: w) }
        out = out.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(out.prefix(100))
    }
}

// MARK: - Turning samples into segments

/// Feed it what is in front every few seconds; it hands back a segment each time the app, window or idleness changes.
struct SegmentBuilder {
    private(set) var current: WorkSegment?

    mutating func observe(at now: Date, bundle: String, name: String, title: String, idle: Bool) -> WorkSegment? {
        if var c = current, c.bundle == bundle, c.title == title, c.idle == idle {
            c.end = now
            current = c
            return nil
        }
        var closed = current
        closed?.end = now
        current = WorkSegment(start: now, end: now, bundle: bundle, name: name, title: title, idle: idle)
        return closed
    }

    mutating func flush(at now: Date) -> WorkSegment? {
        guard var c = current else { return nil }
        c.end = now
        current = nil
        return c
    }
}

enum WorkdayStore {
    static let keepDays = 14
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    static func file(for date: Date, in dir: URL = Paths.workday) -> URL { dir.appendingPathComponent(day.string(from: date) + ".jsonl") }

    static func append(_ s: WorkSegment, in dir: URL = Paths.workday) {
        guard s.seconds >= 1 else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard var line = try? JSONEncoder().encode(s) else { return }
        line.append(0x0A)
        let url = file(for: s.start, in: dir)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    static func load(in dir: URL = Paths.workday) -> [WorkSegment] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [WorkSegment] = []
        for f in files {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for l in text.split(separator: "\n") {
                if let d = l.data(using: .utf8), let s = try? JSONDecoder().decode(WorkSegment.self, from: d) { out.append(s) }
            }
        }
        return out
    }

    /// Deletes day files older than `keepDays`.
    static func purge(in dir: URL = Paths.workday, now: Date = Date()) {
        let cutoff = day.string(from: now.addingTimeInterval(-Double(keepDays) * 86_400))
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
            if f.deletingPathExtension().lastPathComponent < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    static func forgetAll(in dir: URL = Paths.workday) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
            try? FileManager.default.removeItem(at: f)
        }
    }

    static var exclusionsFile: URL { Paths.workday.appendingPathComponent("exclude.txt") }

    /// Extra words that hide a window title, one per line, from `exclude.txt`.
    static func exclusions() -> [String] {
        ((try? String(contentsOf: exclusionsFile, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func ensureExclusionsFile() {
        try? FileManager.default.createDirectory(at: Paths.workday, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: exclusionsFile.path) {
            let text = "# Words that hide a window title in the workday notes, one per line (case does not matter).\n# Password managers and private browser windows are always left out. Example:\n# client name\n# payroll\n"
            try? text.write(to: exclusionsFile, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - The recorder

final class WorkdayRecorder {
    private var timer: Timer?
    private var builder = SegmentBuilder()
    private var lastCut = Date()
    var log: (String) -> Void = { _ in }
    var running: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        WorkdayStore.purge()
        lastCut = Date()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.shared.workdayInterval, repeats: true) { [weak self] _ in self?.tick() }
        log("workday notes: on")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let s = builder.flush(at: Date()) { WorkdayStore.append(s) }
        log("workday notes: off")
    }

    /// Writes what has been seen so far to disk (a check can then read it at once).
    func flush() {
        if let s = builder.flush(at: Date()) { WorkdayStore.append(s) }
    }

    private func tick() {
        let now = Date()
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return }
        if Redact.skips(bundle: bundle) {
            if let s = builder.flush(at: now) { WorkdayStore.append(s) }
            return
        }
        let idle = Self.idleSeconds() > 180 || Self.screenLocked()
        var title = idle ? "" : Self.windowTitle(pid: app.processIdentifier)
        title = Redact.hidden(title: title, extra: WorkdayStore.exclusions()) ? "(hidden)" : Redact.title(title)
        if let closed = builder.observe(at: now, bundle: bundle, name: app.localizedName ?? bundle, title: title, idle: idle) {
            WorkdayStore.append(closed)
        }
        // Cut the open segment every minute so little is lost if the app quits; the analysis joins neighbours again.
        if now.timeIntervalSince(lastCut) > 60 {
            if let s = builder.flush(at: now) { WorkdayStore.append(s) }
            lastCut = now
        }
    }

    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static func screenLocked() -> Bool {
        ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static func windowTitle(pid: pid_t) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w else { return "" }
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return "" }
        return t as? String ?? ""
    }
}

// MARK: - Finding routines

enum WorkdayAnalysis {
    struct AppTime: Equatable { let name: String; let bundle: String; let minutes: Int }
    struct Habit: Equatable { let name: String; let bundle: String; let minuteOfDay: Int; let days: Int; let ofDays: Int; let weekdaysOnly: Bool }
    struct Loop: Equatable { let names: [String]; let times: Int; let days: Int; let minutes: Int }
    struct Phrase: Equatable { let text: String; let times: Int }

    static let ownBundle = "com.momominibot.freeflow"

    /// Sorted, with neighbours that are the same app, window and state (cut by the recorder) joined again.
    static func merged(_ segs: [WorkSegment]) -> [WorkSegment] {
        var out: [WorkSegment] = []
        for s in segs.sorted(by: { $0.start < $1.start }) where s.seconds >= 1 {
            if var last = out.last, last.bundle == s.bundle, last.title == s.title, last.idle == s.idle, s.start.timeIntervalSince(last.end) < 20 {
                last.end = max(last.end, s.end)
                out[out.count - 1] = last
            } else {
                out.append(s)
            }
        }
        return out
    }

    static func today(_ segs: [WorkSegment], now: Date = Date(), cal: Calendar = .current) -> [AppTime] {
        var secs: [String: (String, Double)] = [:]
        for s in segs where !s.idle && s.bundle != ownBundle && cal.isDate(s.start, inSameDayAs: now) {
            secs[s.bundle] = (s.name, (secs[s.bundle]?.1 ?? 0) + s.seconds)
        }
        return secs.map { AppTime(name: $0.value.0, bundle: $0.key, minutes: Int(($0.value.1 / 60).rounded())) }
            .filter { $0.minutes >= 1 }.sorted { ($0.minutes, $1.name, $1.bundle) > ($1.minutes, $0.name, $0.bundle) }
    }

    static func daysWithData(_ segs: [WorkSegment], cal: Calendar = .current) -> Int {
        Set(segs.filter { !$0.idle }.map { cal.startOfDay(for: $0.start) }).count
    }

    /// Apps you reach for at about the same time on most days: the first real use of each app per day, then a one-hour window
    /// that holds the most days. Needs 3 days and at least half of the days with data.
    static func habits(_ segs: [WorkSegment], cal: Calendar = .current) -> [Habit] {
        let real = merged(segs).filter { !$0.idle && $0.bundle != ownBundle && $0.seconds >= 60 }
        let ofDays = daysWithData(segs, cal: cal)
        guard ofDays >= 3 else { return [] }
        var first: [String: [Date: (minute: Int, weekday: Int, name: String)]] = [:]
        for s in real {
            let d = cal.startOfDay(for: s.start)
            if first[s.bundle]?[d] != nil { continue }
            let c = cal.dateComponents([.hour, .minute, .weekday], from: s.start)
            first[s.bundle, default: [:]][d] = ((c.hour ?? 0) * 60 + (c.minute ?? 0), c.weekday ?? 1, s.name)
        }
        var out: [Habit] = []
        for (bundle, days) in first where days.count >= 3 {
            let items = days.values.sorted { $0.minute < $1.minute }
            var best: ArraySlice<(minute: Int, weekday: Int, name: String)> = []
            for i in 0..<items.count {
                var j = i
                while j + 1 < items.count, items[j + 1].minute - items[i].minute <= 60 { j += 1 }
                if j - i + 1 > best.count { best = items[i...j] }
            }
            guard best.count >= 3, Double(best.count) / Double(ofDays) >= 0.5 else { continue }
            let mins = best.map { $0.minute }.sorted()
            let weekdays = best.map { $0.weekday }          // Calendar: 1 = Sunday ... 7 = Saturday
            out.append(Habit(name: best.first?.name ?? bundle, bundle: bundle, minuteOfDay: mins[mins.count / 2], days: best.count,
                             ofDays: ofDays, weekdaysOnly: weekdays.allSatisfy { (2...6).contains($0) }))
        }
        // ties are broken by the app, so the order never depends on how a dictionary happened to be laid out
        return out.sorted { ($0.days, -$0.minuteOfDay, $1.bundle) > ($1.days, -$1.minuteOfDay, $0.bundle) }
    }

    /// Runs of three steps between apps (A, then B, then C) that keep coming back, so a copy-and-paste loop shows up.
    static func loops(_ segs: [WorkSegment], cal: Calendar = .current, minTimes: Int = 6) -> [Loop] {
        let real = merged(segs).filter { !$0.idle && $0.bundle != ownBundle && $0.seconds >= 8 }
        var runs: [[WorkSegment]] = []
        for s in real {
            if var last = runs.last, let l = last.last, s.start.timeIntervalSince(l.end) <= 600 {
                if l.bundle != s.bundle { last.append(s); runs[runs.count - 1] = last }
            } else {
                runs.append([s])
            }
        }
        var counts: [String: (names: [String], times: Int, days: Set<Date>, secs: Double)] = [:]
        for run in runs where run.count >= 3 {
            for i in 0...(run.count - 3) {
                let tri = Array(run[i..<(i + 3)])
                guard Set(tri.map { $0.bundle }).count >= 2 else { continue }
                let key = tri.map { $0.bundle }.joined(separator: ">")
                var e = counts[key] ?? (tri.map { $0.name }, 0, [], 0)
                e.times += 1
                e.days.insert(cal.startOfDay(for: tri[0].start))
                e.secs += tri.reduce(0) { $0 + $1.seconds }
                counts[key] = e
            }
        }
        return counts.values.filter { $0.times >= minTimes && $0.days.count >= 2 }
            .map { Loop(names: $0.names, times: $0.times, days: $0.days.count, minutes: Int(($0.secs / 60).rounded())) }
            .sorted { ($0.times, $0.minutes, $1.names.joined(separator: ">")) > ($1.times, $1.minutes, $0.names.joined(separator: ">")) }
    }

    /// Sentences you have dictated again and again, found by how many 3-word runs they share.
    static func phrases(_ entries: [HistoryEntry], minTimes: Int = 3) -> [Phrase] {
        struct Cluster { var sample: String; var shingles: Set<String>; var ids: Set<Int> }
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        var clusters: [Cluster] = []
        for e in entries {
            for raw in e.text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
                let w = words(raw)
                guard w.count >= 7 else { continue }
                let sh = Set((0...(w.count - 3)).map { w[$0...($0 + 2)].joined(separator: " ") })
                if let i = clusters.firstIndex(where: { Double($0.shingles.intersection(sh).count) / Double($0.shingles.union(sh).count) >= 0.6 }) {
                    clusters[i].ids.insert(e.id)
                } else {
                    clusters.append(Cluster(sample: raw.trimmingCharacters(in: .whitespacesAndNewlines), shingles: sh, ids: [e.id]))
                }
            }
        }
        return clusters.filter { $0.ids.count >= minTimes }.map { Phrase(text: $0.sample, times: $0.ids.count) }.sorted { ($0.times, $1.text) > ($1.times, $0.text) }
    }
}

// MARK: - Things FreeFlow can set up

/// An app-opening routine that runs on a schedule. macOS runs it like a cron job; the cron line is shown for anyone who prefers it.
struct ScheduledTask: Equatable {
    let id: String
    let title: String
    let hour: Int
    let minute: Int
    let weekdays: [Int]          // 1 = Monday ... 7 = Sunday
    let apps: [String]
    let why: String

    var label: String { "com.momominibot.freeflow.task.\(id)" }

    var cron: String {
        let days = weekdays == [1, 2, 3, 4, 5] ? "1-5" : (weekdays.count == 7 ? "*" : weekdays.map(String.init).joined(separator: ","))
        return "\(minute) \(hour) * * \(days)"
    }

    var when: String {
        let t = String(format: "%02d:%02d", hour, minute)
        return (weekdays == [1, 2, 3, 4, 5] ? "Weekdays " : (weekdays.count == 7 ? "Every day " : "On chosen days ")) + t
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func script(log: String) -> String {
        let list = apps.map(Self.shq).joined(separator: " ")
        return """
        #!/bin/bash
        # FreeFlow task: \(title.replacingOccurrences(of: "\n", with: " "))
        # Made from your workday notes. It only opens apps; it changes nothing else.
        # Check it first with:  bash <this file> --dry-run
        # Remove it in FreeFlow: Workday > the task > Remove.
        set -u
        DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
        LOCK="/tmp/freeflow-task-\(id).lock"
        mkdir "$LOCK" 2>/dev/null || { echo "already running"; exit 0; }
        trap 'rmdir "$LOCK"' EXIT
        for app in \(list); do
          if [ "$DRY" = 1 ]; then echo "would open: $app"
          elif open -a "$app" 2>/dev/null; then echo "$(date '+%F %T') opened $app"
          else echo "$(date '+%F %T') could not open $app"; fi
        done

        """
    }

    func plist(script: String, log: String) -> Data? {
        let days: [[String: Int]] = weekdays.map { ["Hour": hour, "Minute": minute, "Weekday": $0 % 7] }   // launchd: 0 or 7 = Sunday
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/bash", script],
            "StartCalendarInterval": days,
            "StandardOutPath": log,
            "StandardErrorPath": log,
            "RunAtLoad": false,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }
}

struct LaunchAgentStore {
    var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    var tasks = Paths.workday.appendingPathComponent("tasks", isDirectory: true)
    var load = true

    func scriptURL(_ t: ScheduledTask) -> URL { tasks.appendingPathComponent("\(t.id).sh") }
    func logURL(_ t: ScheduledTask) -> URL { tasks.appendingPathComponent("\(t.id).log") }
    func plistURL(_ t: ScheduledTask) -> URL { dir.appendingPathComponent("\(t.label).plist") }
    func isInstalled(_ t: ScheduledTask) -> Bool { FileManager.default.fileExists(atPath: plistURL(t).path) }

    @discardableResult
    private func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    func install(_ t: ScheduledTask) throws {
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sh = scriptURL(t), log = logURL(t)
        try t.script(log: log.path).write(to: sh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sh.path)
        guard let data = t.plist(script: sh.path, log: log.path) else { throw FFError(message: "Could not make the schedule file") }
        if load { launchctl(["bootout", "gui/\(getuid())/\(t.label)"]) }
        try data.write(to: plistURL(t), options: .atomic)
        if load {
            let r = launchctl(["bootstrap", "gui/\(getuid())", plistURL(t).path])
            if r.0 != 0 { try? FileManager.default.removeItem(at: plistURL(t)); throw FFError(message: "macOS would not load it: \(r.1.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
    }

    func remove(_ t: ScheduledTask) {
        if load { launchctl(["bootout", "gui/\(getuid())/\(t.label)"]) }
        try? FileManager.default.removeItem(at: plistURL(t))
        try? FileManager.default.removeItem(at: scriptURL(t))
    }
}

// MARK: - Suggestions

struct Suggestion: Identifiable {
    enum Kind { case schedule, hermes, phrase }
    let id: String
    let kind: Kind
    let title: String
    let why: String
    var cue = ""              // phrase: what to say
    var text = ""             // phrase: what appears; hermes: the brief
    var task: ScheduledTask?  // schedule
}

enum Suggestions {
    static func stableId(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
        return String(h % 1_000_000_007, radix: 36)
    }

    static func clock(_ minuteOfDay: Int) -> String { String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60) }

    static func list(segments: [WorkSegment], history: [HistoryEntry], cal: Calendar = .current) -> [Suggestion] {
        var out: [Suggestion] = []

        // Apps you open at the same time on most days become one "morning set-up" task.
        let habits = WorkdayAnalysis.habits(segments, cal: cal).sorted { $0.minuteOfDay < $1.minuteOfDay }
        var group: [WorkdayAnalysis.Habit] = []
        func closeGroup() {
            defer { group = [] }
            guard group.count >= 2, let first = group.first else { return }
            let start = max(0, (group.map { $0.minuteOfDay }.min() ?? first.minuteOfDay) - 5)
            let rounded = start / 5 * 5
            let weekdaysOnly = group.allSatisfy { $0.weekdaysOnly }
            let apps = group.map { $0.name }
            let days = group.map { $0.days }.min() ?? 0, of = first.ofDays
            let list = apps.count > 1 ? apps.dropLast().joined(separator: ", ") + " and " + apps.last! : apps[0]
            let t = ScheduledTask(id: stableId("open|" + group.map { $0.bundle }.sorted().joined(separator: ",")),
                                  title: "Open \(list)", hour: rounded / 60, minute: rounded % 60,
                                  weekdays: weekdaysOnly ? [1, 2, 3, 4, 5] : [1, 2, 3, 4, 5, 6, 7], apps: apps,
                                  why: "\(list) were among the first things you opened on at least \(days) of \(of) days, around \(clock(first.minuteOfDay)).")
            out.append(Suggestion(id: t.id, kind: .schedule, title: t.title + " at " + clock(rounded), why: t.why, task: t))
        }
        for h in habits {
            if let f = group.first, h.minuteOfDay - f.minuteOfDay > 45 { closeGroup() }
            group.append(h)
        }
        closeGroup()

        // Back-and-forth between the same apps: worth asking whether something is copied by hand.
        for l in WorkdayAnalysis.loops(segments, cal: cal).prefix(2) {
            let path = l.names.joined(separator: " → ")
            let why = "You went \(path) \(l.times) times over \(l.days) days (about \(l.minutes) min in all). If you copy something between them by hand, this can be automated."
            let brief = hermesBrief(title: "Automate: \(path)", evidence: why, cron: nil,
                                    ask: "Find out what is moved between these apps and propose the smallest automation (a script first). Do not publish, send or spend anything without approval.")
            out.append(Suggestion(id: stableId("loop|" + path), kind: .hermes, title: "Look at \(path)", why: why, text: brief))
        }

        // The same sentence dictated again and again.
        for p in WorkdayAnalysis.phrases(history).prefix(3) {
            let words = p.text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 }
            let key = words.max(by: { $0.count < $1.count }) ?? "usual"
            out.append(Suggestion(id: stableId("phrase|" + p.text), kind: .phrase, title: "You keep saying this",
                                  why: "\u{201C}\(String(p.text.prefix(110)))\u{201D} came up in \(p.times) of your dictations. Save it once and say a short cue instead.",
                                  cue: "my \(key) text", text: p.text))
        }
        return out
    }

    /// A card another agent can act on. It names apps and counts, never window titles or screen text.
    static func hermesBrief(title: String, evidence: String, cron: String?, ask: String) -> String {
        var s = "Found by FreeFlow's workday notes (kept on this Mac; only app names and counts are shared here).\n\n\(title)\n\nEvidence: \(evidence)\n\nPlease: \(ask)\n"
        if let c = cron { s += "Suggested schedule (cron): \(c)\n" }
        s += "Done when: a dry run passes, one real run is logged, and there is a one-line way to switch it off.\n"
        return s
    }
}

enum Hermes {
    static var hermesPath: String { NSHomeDirectory() + "/.local/bin/hermes" }
    static var bridgePath: String { NSHomeDirectory() + "/.local/bin/fleet-bridge" }
    private static func isExecutable(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
    static var available: Bool { isExecutable(hermesPath) || isExecutable(bridgePath) }

    // MARK: pure pieces (so they can be checked without Hermes)

    /// The words of the command that makes a card. The brief itself goes in on standard input, never on the command line.
    static func cardArguments(title: String, assignee: String?) -> [String] {
        var a = ["kanban", "create", title, "--body-file", "-", "--created-by", "freeflow", "--json"]
        if let who = assignee { a += ["--assignee", who] }
        return a
    }

    /// The card's id from what `hermes kanban create --json` printed (it can print a line of its own before the JSON).
    static func cardID(from output: String) -> String? {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The older route, when only fleet-bridge is installed. Its last word is a priority and must be a number.
    static func bridgeArguments(title: String, body: String, agent: String) -> [String] { ["send", agent, title, body, "0"] }

    /// The agent that gets the briefs (a setting), and its name for a sentence.
    static var agent: () -> String = { Settings.shared.hermesAgent }
    static func agentName(_ id: String) -> String { id.prefix(1).uppercased() + id.dropFirst() }
    static func hasAgent(_ id: String) -> Bool { FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.hermes/profiles/\(id)") }

    // MARK: running it

    /// Runs a command with a time limit. The app is started from the Dock with almost no PATH, so the usual places are added.
    private static func run(_ path: String, _ args: [String], input: String? = nil, timeout: TimeInterval = 60) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + (env["PATH"] ?? "").split(separator: ":").map(String.init)).joined(separator: ":")
        p.environment = env
        let outP = Pipe(), errP = Pipe()
        p.standardOutput = outP; p.standardError = errP
        let inP = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inP
        do { try p.run() } catch { return (127, "", error.localizedDescription) }
        if let text = input {
            inP.fileHandleForWriting.write(Data(text.utf8))
            try? inP.fileHandleForWriting.close()
        }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let out = outP.fileHandleForReading.readDataToEndOfFile()
        let err = errP.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let text = { (d: Data) in (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return (p.terminationStatus, text(out), text(err))
    }

    /// Makes one card on the Hermes board; the id on success. `assignee` nil leaves it for nobody to pick up (the connection test).
    private static func makeCard(_ title: String, _ body: String, assignee: String?) -> Result<String, FFError> {
        let r = run(hermesPath, cardArguments(title: title, assignee: assignee), input: body, timeout: 60)
        if r.status == 0, let id = cardID(from: r.out) { return .success(id) }
        let why = [r.err, r.out].filter { !$0.isEmpty }.joined(separator: " ")
        return .failure(FFError(message: r.status == 0 ? "Hermes answered, but not with a card id. \(String(why.prefix(200)))" : "Hermes said: \(String(why.prefix(300)))"))
    }

    /// Hands a brief to the Hermes fleet as a card for its orchestrator. Runs only when you press the button.
    static var send: (String, String) -> Result<String, FFError> = { title, body in
        let who = agent()
        if !hasAgent(who) { return .failure(FFError(message: "Hermes has no agent called \(agentName(who)). Pick another one under Send to.")) }
        if isExecutable(hermesPath) {
            switch makeCard(title, body, assignee: who) {
            case .success(let id): return .success("\(agentName(who)) has it as card \(id).")
            case .failure(let e): return .failure(e)
            }
        }
        let r = run(bridgePath, bridgeArguments(title: title, body: body, agent: who), timeout: 30)
        let text = [r.out, r.err].filter { !$0.isEmpty }.joined(separator: " ")
        return r.status == 0 ? .success(text) : .failure(FFError(message: String(text.prefix(300))))
    }

    /// The same, off the main thread (starting Hermes takes a few seconds), answering on the main thread.
    static func sendAsync(_ title: String, _ body: String, done: @escaping (Result<String, FFError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = send(title, body)
            DispatchQueue.main.async { done(r) }
        }
    }

    /// Is the hand-over working? Makes a card nobody is assigned to, then closes it. Nothing runs and nothing is spent.
    static func check(done: @escaping (Result<String, FFError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<String, FFError>
            if !isExecutable(hermesPath) {
                result = .failure(FFError(message: "Hermes is not installed at \(hermesPath)."))
            } else if !hasAgent(agent()) {
                result = .failure(FFError(message: "Hermes has no agent called \(agentName(agent())). Pick another one under Send to."))
            } else {
                switch makeCard("FreeFlow connection check (ignore)", "Sent by FreeFlow's connection test. Closed right away; nothing to do.", assignee: nil) {
                case .failure(let e): result = .failure(e)
                case .success(let id):
                    let c = run(hermesPath, ["kanban", "complete", id, "--result", "FreeFlow connection check; closed by the test, nothing to do"], timeout: 60)
                    result = c.status == 0 ? .success("Hermes answered and took a card (\(id)), and \(agentName(agent())) is there to get your briefs. The test card is closed.")
                                           : .failure(FFError(message: "Hermes took the card (\(id)) but would not close it: \(String((c.err + c.out).prefix(200)))"))
                }
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    static func saveBrief(_ s: Suggestion) {
        let dir = Paths.workday.appendingPathComponent("briefs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? s.text.write(to: dir.appendingPathComponent("\(s.id).md"), atomically: true, encoding: .utf8)
    }
}
