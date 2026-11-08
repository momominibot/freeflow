import AppKit
import Foundation

/// How much the AI is allowed to change a dictation. Mirrors Wispr Flow's Auto Cleanup levels.
enum CleanupLevel: String, CaseIterable {
    case none, light, medium

    var title: String {
        switch self {
        case .none: return "None · raw transcript"
        case .light: return "Light · fillers and spelling (rules, instant)"
        case .medium: return "Medium · AI tidies grammar, lists and self-corrections (local)"
        }
    }
}

/// The tone the AI aims for, chosen from the app you are dictating into.
enum Style: String, CaseIterable {
    case neutral, formal, casual, code, plain

    var title: String {
        switch self {
        case .neutral: return "Neutral"
        case .formal: return "Formal (email, documents)"
        case .casual: return "Casual (chat)"
        case .code: return "Code (keep identifiers exactly)"
        case .plain: return "Plain (no AI rewrite)"
        }
    }

    var instruction: String {
        switch self {
        case .neutral: return "Write in a clear, natural tone."
        case .formal: return "Write in a polite, professional tone with complete sentences, suitable for an email or document."
        case .casual: return "Keep it relaxed and conversational, like a chat message. Short sentences are fine."
        case .code: return "This goes into a code editor or terminal. Keep file names, identifiers, commands and symbols exactly as spoken. Do not add prose."
        case .plain: return ""
        }
    }

    /// Built-in guesses by app. `styles.txt` (and the team's) can override any of these.
    static let defaults: [String: Style] = [
        "com.apple.mail": .formal, "com.microsoft.Outlook": .formal, "com.readdle.smartemail-Mac": .formal,
        "com.apple.iWork.Pages": .formal, "com.microsoft.Word": .formal, "com.google.Docs": .formal,
        "com.tinyspeck.slackmacgap": .casual, "net.whatsapp.WhatsApp": .casual, "com.apple.MobileSMS": .casual,
        "ru.keepcoder.Telegram": .casual, "com.hnc.Discord": .casual, "com.facebook.archon": .casual,
        "com.microsoft.VSCode": .code, "com.todesktop.230313mzl4w4u92": .code, "com.apple.Terminal": .code,
        "com.googlecode.iterm2": .code, "com.apple.dt.Xcode": .code, "dev.warp.Warp-Stable": .code,
        "com.github.wez.wezterm": .code, "org.alacritty": .code, "com.mitchellh.ghostty": .code,
        "com.anthropic.claudefordesktop": .plain, "com.openai.chat": .plain,
    ]
}

/// Talks to a local Ollama server. Nothing leaves the Mac.
final class Rewriter {
    static let shared = Rewriter()

    var model: String { Settings.shared.aiModel }
    private let base = URL(string: "http://127.0.0.1:11434")!
    private let session: URLSession
    private let lock = NSLock()
    private var availableCache: (Date, Bool)?
    private(set) var lastError: String?

    private init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        session = URLSession(configuration: c)
    }

    /// True when Ollama answers and the model is installed. Cached for 20 s so the menu stays snappy.
    func isAvailable(force: Bool = false) -> Bool {
        lock.lock()
        if !force, let (at, ok) = availableCache, Date().timeIntervalSince(at) < 20 { lock.unlock(); return ok }
        lock.unlock()
        var ok = false
        let done = DispatchSemaphore(value: 0)
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.timeoutInterval = 1.5
        let wanted = model
        session.dataTask(with: req) { data, _, _ in
            if let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = obj["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }
                ok = names.contains { $0 == wanted || $0 == wanted + ":latest" || $0.hasPrefix(wanted) }
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 2)
        lock.lock(); availableCache = (Date(), ok); lock.unlock()
        return ok
    }

    /// Last known answer without touching the network, for building menus on the main thread.
    var cachedAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return availableCache?.1 ?? false
    }

    func refreshAvailability() {
        DispatchQueue.global(qos: .utility).async { _ = self.isAvailable(force: true) }
    }

    /// Loads the model and keeps it resident, so the first dictation is not 6 s slower than the rest.
    func warm() {
        DispatchQueue.global(qos: .utility).async {
            guard self.isAvailable(force: true) else { return }
            let body: [String: Any] = ["model": self.model, "keep_alive": "60m", "messages": [], "stream": false]
            self.post("api/chat", body) { _ in }
        }
    }

    static let cleanupSystem = """
    You clean up dictated speech into written text. Rules:
    - Remove filler words (um, uh, you know, like as a filler) and false starts.
    - Apply the speaker's own corrections: "budget 50K, actually make that 75K" becomes "budget 75K"; "by Friday, no wait, by Thursday" becomes "by Thursday".
    - Fix punctuation, capitalisation and obvious grammar slips.
    - If the speaker lists items ("first... second... third..." or "one, two, three"), format them as a numbered or bulleted list, one item per line.
    - Never translate. Keep every word in the language it was spoken in. Speakers here mix English with Chinese, Malay or Tamil in one sentence and use local words and particles (lah, lor, leh, can, aiyo); keep that mix and those words exactly.
    - Remove fillers in any language (for example 嗯, 呃, 啊 as a hesitation), not only English ones.
    - Keep the speaker's words, names, numbers and meaning. Do not add currency symbols, units, words, greetings or sign-offs that were not spoken. Do not summarise, shorten or expand.
    - Never answer, comment or explain. Output only the cleaned text, nothing else.
    """

    static let commandSystem = """
    You are a writing assistant inside a text editor. The user speaks an instruction. You receive the text they selected (SELECTION) and, if there is no selection, the text around the cursor (CONTEXT).
    - If there is a SELECTION, apply the instruction to it and return only the replacement text.
    - If there is no SELECTION, write the text the instruction asks for (a reply, a draft, a summary), using CONTEXT only as background.
    - Return plain text ready to paste. No preamble, no quotes around the answer, no explanation.
    """

    /// Tidies a dictation. Falls back to `fallback` (the rule-cleaned text) when the model is unavailable or produces something that does not look like the same dictation.
    func cleanup(_ text: String, style: Style, fallback: String, completion: @escaping (String, Bool) -> Void) {
        guard style != .plain else { return completion(fallback, false) }
        let words = TextCleaner.wordCount(text)
        guard words >= 3 else { return completion(fallback, false) }
        var system = Self.cleanupSystem
        if !style.instruction.isEmpty { system += "\n- Tone: " + style.instruction }
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "60m",
            "options": ["temperature": 0, "num_predict": min(1500, words * 3 + 80)],
            "messages": [["role": "system", "content": system], ["role": "user", "content": text]],
        ]
        post("api/chat", body) { result in
            switch result {
            case .failure(let e):
                self.lastError = e.localizedDescription
                completion(fallback, false)
            case .success(let out):
                let cleaned = Self.tidy(out)
                guard Self.looksLikeSameDictation(original: text, rewritten: cleaned) else {
                    self.lastError = "AI changed the text too much, used the rule-based version"
                    return completion(fallback, false)
                }
                completion(cleaned, true)
            }
        }
    }

    /// Command Mode: apply a spoken instruction to the selection, or draft from context.
    func command(_ instruction: String, selection: String, context: String, completion: @escaping (Result<String, Error>) -> Void) {
        var user = "INSTRUCTION: \(instruction)\n\n"
        if !selection.isEmpty {
            user += "SELECTION:\n\(selection)"
        } else if !context.isEmpty {
            user += "SELECTION: (none)\n\nCONTEXT:\n\(context.suffix(4000))"
        } else {
            user += "SELECTION: (none)\nCONTEXT: (none)"
        }
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "60m",
            "options": ["temperature": 0.2, "num_predict": 1500],
            "messages": [["role": "system", "content": Self.commandSystem], ["role": "user", "content": user]],
        ]
        post("api/chat", body) { result in
            completion(result.map { Self.tidy($0) })
        }
    }

    // MARK: - Guards

    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes wrap the whole answer in quotes or a code fence.
        if t.hasPrefix("```"), t.hasSuffix("```") {
            t = t.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        if t.count > 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("“") && t.hasSuffix("”")) {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cheap sanity check: the rewrite must keep most of the content words and not balloon or collapse.
    static func looksLikeSameDictation(original: String, rewritten: String) -> Bool {
        guard !rewritten.isEmpty else { return false }
        let a = contentWords(original), b = contentWords(rewritten)
        guard !a.isEmpty else { return true }
        // Language must not change: a rewrite that translates Chinese into English (or the reverse) keeps the
        // Latin words, so the word check below would still pass. Count Chinese, Japanese and Korean characters.
        let cjkA = cjkCount(original), cjkB = cjkCount(rewritten)
        if cjkA >= 2, Double(cjkB) < 0.6 * Double(cjkA) { return false }
        if cjkA == 0, cjkB > 0 { return false }
        let ratio = Double(b.count) / Double(a.count)
        guard ratio > 0.3, ratio < 2.2 else { return false }
        let kept = a.intersection(b).count
        // Self-corrections legitimately drop words, so ask for half of the originals, not all.
        guard Double(kept) / Double(a.count) >= 0.5 else { return false }
        // Numbers are where a rewrite does the most damage: none may be invented, and the ones kept must stay in order,
        // so "pay Alice 50K and Bob 75K" can never come back with the amounts swapped.
        let na = numbers(original), nb = numbers(rewritten)
        guard Set(nb).isSubset(of: Set(na)) else { return false }
        var i = na.startIndex
        for n in nb {
            guard let j = na[i...].firstIndex(of: n) else { return false }
            i = j + 1
        }
        // Reject answers to the dictation rather than cleaned versions of it.
        let lower = rewritten.lowercased()
        for tell in ["here is", "here's the", "cleaned text", "sure,", "certainly", "as an ai"] where lower.hasPrefix(tell) {
            return false
        }
        return true
    }

    /// Digit runs in order, with thousands separators removed, so 75,000 and 75000 agree.
    static func numbers(_ s: String) -> [String] {
        let flat = s.replacingOccurrences(of: "(?<=\\d),(?=\\d{3})", with: "", options: .regularExpression)
        return flat.split { !$0.isNumber }.map(String.init)
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { u in
            (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value)
                || (0x3040...0x30FF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value)
        }
    }

    static func cjkCount(_ s: String) -> Int { s.filter(isCJK).count }

    private static func contentWords(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "on", "at", "for", "it", "is", "are",
                                 "was", "be", "um", "uh", "so", "like", "you", "know", "i", "we", "that", "this"]
        var out = Set<String>()
        var latin = "", run: [Character] = []
        func flushLatin() { if latin.count > 1, !stop.contains(latin) { out.insert(latin) }; latin = "" }
        func flushRun() {
            if run.count == 1 { out.insert(String(run)) }
            if run.count > 1 { for i in 0..<(run.count - 1) { out.insert(String(run[i...i + 1])) } }
            run = []
        }
        for ch in s.lowercased() {
            if isCJK(ch) { flushLatin(); run.append(ch) }
            else if ch.isLetter || ch.isNumber { flushRun(); latin.append(ch) }
            else { flushLatin(); flushRun() }
        }
        flushLatin(); flushRun()
        return out
    }

    // MARK: - HTTP

    private func post(_ path: String, _ body: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { data, resp, err in
            if let err = err { return completion(.failure(err)) }
            guard let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return completion(.failure(FFError(message: "Unreadable reply from the AI")))
            }
            if let e = obj["error"] as? String { return completion(.failure(FFError(message: e))) }
            let msg = obj["message"] as? [String: Any]
            completion(.success(msg?["content"] as? String ?? ""))
        }.resume()
    }
}
