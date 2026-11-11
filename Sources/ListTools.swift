import Foundation

/// Reading a list of words or snippets from a file someone else made: plain text, CSV or JSON.
/// Every format ends up as the lines Purrscribe already understands: `word` or `wrong => right`.
enum ListImport {
    /// Dictionary lines from the contents of a file. `ext` is the file extension, lower case.
    static func dictionaryLines(from text: String, ext: String) -> [String] {
        switch ext {
        case "json": return jsonLines(text, snippets: false)
        case "csv": return csvLines(text, snippets: false)
        default: return plainLines(text)
        }
    }

    /// Snippet lines (`cue => expansion`) from the contents of a file.
    static func snippetLines(from text: String, ext: String) -> [String] {
        switch ext {
        case "json": return jsonLines(text, snippets: true)
        case "csv": return csvLines(text, snippets: true)
        default: return plainLines(text).filter { $0.contains("=>") }
        }
    }

    /// One entry per line, or several separated by commas when there is only one line. Blank lines and # comments are skipped.
    static func plainLines(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        if lines.count == 1, !lines[0].contains("=>"), lines[0].contains(",") {
            return lines[0].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return lines
    }

    /// Splits one CSV line into fields, honouring double quotes.
    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var cur = ""
        var quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if quoted {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" { cur.append("\""); i = next } else { quoted = false }
                } else { cur.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { fields.append(cur); cur = "" }
            else { cur.append(c) }
            i = line.index(after: i)
        }
        fields.append(cur)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func csvLines(_ text: String, snippets: Bool) -> [String] {
        var out: [String] = []
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = csvFields(line)
            let a = f.first ?? ""
            let b = f.count > 1 ? f[1] : ""
            if n == 0, ["word", "term", "cue", "from", "phrase", "trigger"].contains(a.lowercased()) { continue }   // a header row
            if a.isEmpty { continue }
            if snippets {
                if !b.isEmpty { out.append("\(a) => \(b.replacingOccurrences(of: "\n", with: "\\n"))") }
            } else {
                out.append(b.isEmpty ? a : "\(a) => \(b)")
            }
        }
        return out
    }

    static func jsonLines(_ text: String, snippets: Bool) -> [String] {
        guard let data = text.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [Any] = []
        if let a = obj as? [Any] { items = a }
        else if let d = obj as? [String: Any] {
            for key in ["words", "dictionary", "terms", "entries", "snippets", "items"] { if let a = d[key] as? [Any] { items = a; break } }
        }
        var out: [String] = []
        for item in items {
            if let s = item as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !snippets { out.append(t) }
            } else if let d = item as? [String: Any] {
                func pick(_ keys: [String]) -> String? {
                    for k in keys { if let v = d[k] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v.trimmingCharacters(in: .whitespacesAndNewlines) } }
                    return nil
                }
                if snippets {
                    if let cue = pick(["cue", "trigger", "phrase", "shortcut", "name"]), let body = pick(["expansion", "text", "content", "replacement", "value"]) {
                        out.append("\(cue) => \(body.replacingOccurrences(of: "\n", with: "\\n"))")
                    }
                } else if let word = pick(["word", "term", "phrase", "from", "text", "wrong", "misspelling"]) {
                    if let right = pick(["replacement", "to", "right", "correct", "correction"]), right != word { out.append("\(word) => \(right)") }
                    else { out.append(word) }
                }
            }
        }
        return out
    }

    /// The lines that are not already in the list (compared without case), each only once.
    static func fresh(_ lines: [String], existing: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var out: [String] = []
        for l in lines {
            let key = l.lowercased()
            if !seen.contains(key), l.count <= 4_000 { seen.insert(key); out.append(l) }
        }
        return out
    }
}

/// Dictation history written out for sharing or keeping.
enum HistoryExport {
    static func markdown(_ entries: [HistoryEntry], now: Date = Date()) -> String {
        let day = DateFormatter(); day.dateFormat = "EEEE d MMMM yyyy"
        let time = DateFormatter(); time.dateFormat = "h:mm a"
        var out = "# Purrscribe dictations\n"
        var last = ""
        for e in entries.sorted(by: { $0.date < $1.date }) {
            let d = day.string(from: e.date)
            if d != last { out += "\n## \(d)\n\n"; last = d }
            out += "- \(time.string(from: e.date).lowercased())  \(e.text.replacingOccurrences(of: "\n", with: " "))\n"
        }
        return out
    }

    static func plain(_ entries: [HistoryEntry]) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        return entries.sorted(by: { $0.date < $1.date }).map { "\(f.string(from: $0.date))  \($0.text.replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\n"
    }

    static func json(_ entries: [HistoryEntry]) -> String {
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = entries.sorted(by: { $0.date < $1.date }).map {
            ["time": iso.string(from: $0.date), "app": $0.app, "mode": $0.mode, "text": $0.text, "original": $0.raw]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
