import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// Deeper workday notes. Workday keeps which app and window you are in; this adds, each part off until you switch it on:
//   screen text   the words on the front window every couple of minutes, read on this Mac (the picture is thrown away at once)
//   typing        how much you type and delete each minute, and the lines you finish writing, cleaned
//   pictures      small pictures of the front window, kept for 3 days (a third switch, for an agent that can look at images)
// Everything is plain files in the workday folder on this Mac, so an agent such as Hermes can read them and look for routines
// worth automating. Emails, links, keys, long numbers and any line that mentions a password are swapped for a tag before anything
// is written. Password managers, terminals, private windows, the words in exclude.txt and FreeFlow itself are never read.

// MARK: - Cleaning text before it is kept

extension Redact {
    /// Lines that mention these are replaced whole, whatever is on them.
    static let secretWords = ["password", "passcode", "passwd", "one-time", "verification code", "security code", "secret", "api key", "apikey",
                              "token", "cvv", "card number", "iban", "account number", "private key", "recovery phrase", "seed phrase"]

    /// One line, with emails, links, keys and long numbers swapped for a tag. A line about a password becomes "<hidden line>".
    static func line(_ s: String) -> String {
        let lower = s.lowercased()
        if secretWords.contains(where: { lower.contains($0) }) { return "<hidden line>" }
        var out = s
        for (r, w) in patterns { out = r.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: w) }
        return out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - What is kept

/// One thing noticed. kind "screen": the text on the front window. kind "typing": one minute of typing and the lines finished in it.
struct DetailRecord: Codable, Equatable {
    var t: Date
    var kind: String
    var app: String
    var name: String
    var title: String
    var text: String
    var typed: Int
    var deleted: Int
    var secs: Int

    enum CodingKeys: String, CodingKey { case t, kind, app, name, title, text, typed, deleted, secs }

    init(t: Date, kind: String, app: String, name: String, title: String, text: String, typed: Int = 0, deleted: Int = 0, secs: Int = 0) {
        self.t = t; self.kind = kind; self.app = app; self.name = name; self.title = title; self.text = text
        self.typed = typed; self.deleted = deleted; self.secs = secs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .t))
        kind = try c.decode(String.self, forKey: .kind)
        app = try c.decode(String.self, forKey: .app)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? app
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        typed = try c.decodeIfPresent(Int.self, forKey: .typed) ?? 0
        deleted = try c.decodeIfPresent(Int.self, forKey: .deleted) ?? 0
        secs = try c.decodeIfPresent(Int.self, forKey: .secs) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t.timeIntervalSince1970.rounded(), forKey: .t)
        try c.encode(kind, forKey: .kind)
        try c.encode(app, forKey: .app)
        try c.encode(name, forKey: .name)
        if !title.isEmpty { try c.encode(title, forKey: .title) }
        if !text.isEmpty { try c.encode(text, forKey: .text) }
        if typed > 0 { try c.encode(typed, forKey: .typed) }
        if deleted > 0 { try c.encode(deleted, forKey: .deleted) }
        if secs > 0 { try c.encode(secs, forKey: .secs) }
    }
}

enum DetailStore {
    static let keepDays = 7
    static let keepPictureDays = 3
    static var dir: URL { Paths.workday.appendingPathComponent("detail", isDirectory: true) }
    private static let day: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    static func dayString(_ d: Date) -> String { day.string(from: d) }
    static func file(kind: String, date: Date, in dir: URL = DetailStore.dir) -> URL { dir.appendingPathComponent("\(kind)-\(day.string(from: date)).jsonl") }
    static func picturesDir(in dir: URL = DetailStore.dir) -> URL { dir.appendingPathComponent("pictures", isDirectory: true) }

    static func append(_ r: DetailRecord, in dir: URL = DetailStore.dir) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard var line = try? JSONEncoder().encode(r) else { return }
        line.append(0x0A)
        let url = file(kind: r.kind, date: r.t, in: dir)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    static func load(kind: String, date: Date, in dir: URL = DetailStore.dir) -> [DetailRecord] {
        guard let text = try? String(contentsOf: file(kind: kind, date: date, in: dir), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { l in l.data(using: .utf8).flatMap { try? JSONDecoder().decode(DetailRecord.self, from: $0) } }
    }

    static func files(in dir: URL = DetailStore.dir) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Deletes day files older than `keepDays` and pictures older than `keepPictureDays`.
    static func purge(in dir: URL = DetailStore.dir, now: Date = Date()) {
        let cutoff = day.string(from: now.addingTimeInterval(-Double(keepDays) * 86_400))
        for f in files(in: dir) {
            let name = f.deletingPathExtension().lastPathComponent          // screen-2026-11-09
            if String(name.suffix(10)) < cutoff { try? FileManager.default.removeItem(at: f) }
        }
        let picCutoff = day.string(from: now.addingTimeInterval(-Double(keepPictureDays) * 86_400))
        let pics = picturesDir(in: dir)
        for f in (try? FileManager.default.contentsOfDirectory(at: pics, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent < picCutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }

    static func forgetAll(in dir: URL = DetailStore.dir) {
        try? FileManager.default.removeItem(at: dir)
    }

    static func count(kind: String, date: Date = Date(), in dir: URL = DetailStore.dir) -> Int { load(kind: kind, date: date, in: dir).count }

    /// A small JPEG of the window, kept in pictures/<day>/. Returns the file written.
    @discardableResult
    static func savePicture(_ image: CGImage, app: String, at date: Date = Date(), in dir: URL = DetailStore.dir, maxWidth: Int = 1280) -> URL? {
        let folder = picturesDir(in: dir).appendingPathComponent(day.string(from: date), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        let safe = String(app.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }.prefix(40))
        let url = folder.appendingPathComponent("\(f.string(from: date))-\(safe).jpg")
        var img = image
        if image.width > maxWidth {
            let h = image.height * maxWidth / image.width
            if let ctx = CGContext(data: nil, width: maxWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: h))
                if let small = ctx.makeImage() { img = small }
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}

// MARK: - Screen text

enum ScreenText {
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    static func request() { _ = CGRequestScreenCaptureAccess() }

    /// Raw recognised lines, tidied: tiny and symbol-only lines dropped, repeats dropped, every line cleaned, cut to `limit` characters.
    static func clean(_ raw: String, limit: Int = 3000) -> String {
        var seen = Set<String>()
        var out: [String] = []
        var total = 0
        for l in raw.components(separatedBy: .newlines) {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3 else { continue }
            let letters = t.filter { $0.isLetter || $0.isNumber }.count
            guard Double(letters) >= Double(t.count) * 0.5 else { continue }
            let c = Redact.line(t)
            guard !seen.contains(c) else { continue }
            seen.insert(c)
            if total + c.count + 1 > limit { break }
            out.append(c)
            total += c.count + 1
        }
        return out.joined(separator: "\n")
    }

    static func recognize(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return "" }
        let obs = (req.results ?? []).sorted { a, b in
            abs(a.boundingBox.minY - b.boundingBox.minY) > 0.012 ? a.boundingBox.minY > b.boundingBox.minY : a.boundingBox.minX < b.boundingBox.minX
        }
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Takes one picture of the biggest window of the app with this pid, reads it, and hands both back on the main queue.
    static func read(pid: pid_t, completion: @escaping (Result<(text: String, image: CGImage), FFError>) -> Void) {
        guard #available(macOS 14.0, *) else {
            completion(.failure(FFError(message: "reading the screen needs macOS 14 or newer")))
            return
        }
        Task.detached(priority: .utility) {
            do {
                let image = try await capture(pid: pid)
                let text = recognize(image)
                await MainActor.run { completion(.success((text, image))) }
            } catch {
                let m = (error as? FFError)?.message ?? error.localizedDescription
                await MainActor.run { completion(.failure(FFError(message: m))) }
            }
        }
    }

    @available(macOS 14.0, *)
    private static func capture(pid: pid_t) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let wins = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 200 && $0.frame.height >= 150 }
        // the window nearest the front: on-screen windows are listed front to back; the biggest one is only the fallback
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let front = order.compactMap { id in wins.first { $0.windowID == id } }.first
        guard let w = front ?? wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw FFError(message: "no window of the front app to read")
        }
        let cfg = SCStreamConfiguration()
        let scale = min(2.0, 2400 / max(1, w.frame.width))
        cfg.width = Int(w.frame.width * scale)
        cfg.height = Int(w.frame.height * scale)
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
    }
}

// MARK: - Typing

/// Counts what is typed and deleted between looks at one text box. A jump of more than 40 characters at once is a paste or a
/// dictation, not typing, and is not counted.
struct TypingMeter: Equatable {
    private(set) var typed = 0
    private(set) var deleted = 0
    private(set) var seconds = 0
    private var last: Int?
    static let jump = 40

    var isEmpty: Bool { typed == 0 && deleted == 0 }

    mutating func observe(length: Int, sameBox: Bool) {
        defer { last = length }
        guard sameBox, let l = last, length != l else { return }
        let d = length - l
        guard abs(d) <= Self.jump else { return }
        if d > 0 { typed += d } else { deleted += -d }
        seconds += 1
    }

    mutating func clear() { typed = 0; deleted = 0; seconds = 0 }
}

// MARK: - The recorder

final class DetailRecorder {
    var log: (String) -> Void = { _ in }
    private var screenTimer: Timer?
    private var typingTimer: Timer?
    private var reading = false
    private var lastScreenHash: Int?
    private var deniedNoted = false

    // typing state
    private var element: AXUIElement?
    private var bundle = ""
    private var appName = ""
    private var pid: pid_t = 0
    private var meter = TypingMeter()
    private var minuteStart = Date()
    private var lineStart = -1
    private var lineText = ""
    private var lineChanged = Date()
    private var lineKept = ""
    private var lines: [String] = []
    static let quietLine: TimeInterval = 2.5

    var screenRunning: Bool { screenTimer != nil }
    var typingRunning: Bool { typingTimer != nil }

    /// Starts or stops each part to match the settings.
    func apply() {
        let s = Settings.shared
        if s.screenTextOn { startScreen() } else { stopScreen() }
        if s.typingDetailOn { startTyping() } else { stopTyping() }
        if s.screenTextOn || s.typingDetailOn { DetailStore.purge() }
    }

    func startScreen() {
        guard screenTimer == nil else { return }
        if !ScreenText.allowed { ScreenText.request() }
        screenTimer = Timer.scheduledTimer(withTimeInterval: Settings.shared.detailInterval, repeats: true) { [weak self] _ in self?.readNow() }
        log("screen: reading the text on the front window is on")
    }

    func stopScreen() {
        guard screenTimer != nil else { return }
        screenTimer?.invalidate(); screenTimer = nil
        log("screen: reading the text on the front window is off")
    }

    func startTyping() {
        guard typingTimer == nil, AXIsProcessTrusted() else { return }
        minuteStart = Date()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.typingTick() }
        RunLoop.main.add(t, forMode: .common)
        typingTimer = t
        log("typing notes: on")
    }

    func stopTyping() {
        guard typingTimer != nil else { return }
        flushTyping()
        typingTimer?.invalidate(); typingTimer = nil
        element = nil
        log("typing notes: off")
    }

    /// Writes what has been noticed so far (a check can then read it at once).
    func flush() { flushTyping() }

    // MARK: Screen

    /// Reads the front window now, if the switch is on. `force` skips the idle check (used by the check on this Mac).
    func readNow(force: Bool = false) {
        guard Settings.shared.screenTextOn else { log("screen: reading the text on the front window is switched off"); return }
        guard !reading else { if force { log("screen: still busy with the last read") }; return }
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return }
        if Redact.skips(bundle: id) || TypingRules.skips(bundle: id) { if force { log("screen: not reading \(id), it is never read") }; return }
        if !force && (WorkdayRecorder.idleSeconds() > 180 || WorkdayRecorder.screenLocked()) { return }
        guard ScreenText.allowed else {
            if !deniedNoted { log("screen: Screen Recording is not allowed for FreeFlow, so nothing is read (System Settings > Privacy & Security)"); deniedNoted = true }
            return
        }
        deniedNoted = false
        let raw = WorkdayRecorder.windowTitle(pid: app.processIdentifier)
        if Redact.hidden(title: raw, extra: WorkdayStore.exclusions()) { if force { log("screen: not reading, the window is hidden by a private-window rule or your list") }; return }
        let title = Redact.title(raw)
        let name = app.localizedName ?? id
        reading = true
        ScreenText.read(pid: app.processIdentifier) { [weak self] result in
            guard let self = self else { return }
            self.reading = false
            switch result {
            case .failure(let e):
                self.log("screen: could not read the window (\(e.message))")
            case .success(let r):
                let text = ScreenText.clean(r.text)
                guard text.count >= 20 else { self.log("screen: nothing readable on the window"); return }
                let h = (id + title + text).hashValue
                if h == self.lastScreenHash { self.log("screen: unchanged since the last read"); return }
                self.lastScreenHash = h
                DetailStore.append(DetailRecord(t: Date(), kind: "screen", app: id, name: name, title: title, text: text))
                self.log("screen: read \(text.count) characters from \(name)")
                if Settings.shared.keepPictures, DetailStore.savePicture(r.image, app: name) != nil { self.log("screen: a small picture was kept") }
            }
        }
    }

    // MARK: Typing

    private func typingTick() {
        let now = Date()
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              !Redact.skips(bundle: id), !TypingRules.skips(bundle: id),
              !(WorkdayRecorder.idleSeconds() > 180 || WorkdayRecorder.screenLocked()),
              let snap = Inserter.caretSnapshot(), snap.value.utf16.count <= 60_000 else {
            flushTyping(); element = nil; return
        }
        let same = element.map { CFEqual($0, snap.element) } ?? false
        if !same || id != bundle {
            flushTyping()
            element = snap.element; bundle = id; appName = app.localizedName ?? id; pid = app.processIdentifier
            meter = TypingMeter(); minuteStart = now; lineStart = -1; lineText = ""; lineKept = ""
        }
        meter.observe(length: snap.value.utf16.count, sameBox: same)
        let line = TypingRules.line(in: snap.value, caret: snap.caret)
        if line.start != lineStart {
            keepLine()
            lineStart = line.start; lineText = line.text; lineChanged = now
        } else if line.text != lineText {
            lineText = line.text; lineChanged = now
        } else if now.timeIntervalSince(lineChanged) >= Self.quietLine {
            lineKept = lineText                      // left alone for a moment: this is what was written
        }
        if now.timeIntervalSince(minuteStart) >= 60 { flushTyping() }
    }

    private func keepLine() {
        let t = lineKept.trimmingCharacters(in: .whitespacesAndNewlines)
        lineKept = ""
        guard t.count >= 12, lines.count < 20 else { return }
        let c = Redact.line(String(t.prefix(400)))
        if lines.last != c { lines.append(c) }
    }

    private func flushTyping() {
        keepLine()
        defer { meter.clear(); lines = []; minuteStart = Date() }
        guard !bundle.isEmpty, !meter.isEmpty || !lines.isEmpty else { return }
        var title = WorkdayRecorder.windowTitle(pid: pid)
        title = Redact.hidden(title: title, extra: WorkdayStore.exclusions()) ? "(hidden)" : Redact.title(title)
        DetailStore.append(DetailRecord(t: Date(), kind: "typing", app: bundle, name: appName, title: title, text: lines.joined(separator: "\n"),
                                        typed: meter.typed, deleted: meter.deleted, secs: meter.seconds))
        log("typing notes: wrote a minute (typed \(meter.typed), deleted \(meter.deleted), \(lines.count) finished lines) in \(appName)")
    }
}

// MARK: - Asking Hermes for a closer look

extension Hermes {
    /// The brief for a deeper review. It names the files on this Mac for the agent to read; it carries none of their text.
    static func deepReviewBrief(days: Int, workday: URL = Paths.workday, detail: URL = DetailStore.dir, now: Date = Date()) -> String {
        let counts = ["screen", "typing"].map { k in
            "\(k): \(DetailStore.count(kind: k, date: now, in: detail)) records today"
        }.joined(separator: ", ")
        return """
        FreeFlow has been keeping private notes on this Mac about how I work, and I would like a closer look at them.

        Files (plain text, one JSON record per line, newest last; read them directly on this Mac):
        - Apps and windows by time: \(workday.path)/YYYY-MM-DD.jsonl  (fields: s start, e end, app, name, title, idle)
        - Text read from my screen: \(detail.path)/screen-YYYY-MM-DD.jsonl  (text = what was on the front window)
        - How I type: \(detail.path)/typing-YYYY-MM-DD.jsonl  (typed and deleted counts per minute, and lines I finished writing)
        Today so far: \(counts). Look at the last \(days) days. Anything with <email>, <link>, <key> or <hidden line> was already cleaned; leave it that way.

        Please:
        1. Find the work I repeat: the same steps in the same apps, the same text typed again and again, the same pages visited in the same order, time that disappears into one place.
        2. For each one, say what it costs me (minutes a day) and how sure you are, quoting the file and time it came from.
        3. Turn the best ones into proposals I can accept or refuse: a cron task, a FreeFlow phrase, or an agent skill. Each proposal is a short brief with the schedule, what it would do, what it would touch and how to switch it off.
        4. Do not run, publish, send, buy or change anything outside this Mac. Wait for my yes on each proposal. Do not copy the contents of these files anywhere else.

        Done when: a short ranked list with minutes saved per proposal is waiting for me.
        """
    }
}
