import SwiftUI
import AppKit

// MARK: - The notes themselves

/// One note in the Scratchpad: a small text file in Application Support/FreeFlow/scratchpad.
struct ScratchNote: Identifiable, Equatable {
    let id: String
    var text: String
    var date: Date
    var url: URL
}

enum ScratchStore {
    private static let fm = FileManager.default

    /// Newest first.
    static func list(in dir: URL = Paths.scratchpad) -> [ScratchNote] {
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [ScratchNote] = []
        for f in files where f.pathExtension == "txt" {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            out.append(ScratchNote(id: f.deletingPathExtension().lastPathComponent, text: text, date: date, url: f))
        }
        return out.sorted { $0.date > $1.date }
    }

    @discardableResult
    static func create(text: String, in dir: URL = Paths.scratchpad, now: Date = Date()) -> ScratchNote? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        var name = f.string(from: now)
        var url = dir.appendingPathComponent(name + ".txt")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            name = f.string(from: now) + "-\(n)"
            url = dir.appendingPathComponent(name + ".txt")
            n += 1
        }
        guard (try? t.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return ScratchNote(id: name, text: t, date: now, url: url)
    }

    static func update(_ note: ScratchNote, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { delete(note) } else { try? t.write(to: note.url, atomically: true, encoding: .utf8) }
    }

    static func delete(_ note: ScratchNote) {
        try? fm.removeItem(at: note.url)
    }

    /// "Note to self, buy milk." gives "Buy milk." Only the spoken openers below count, so ordinary sentences are never taken.
    static func noteToSelf(_ text: String) -> String? {
        let pattern = #"^\s*(?:(?:a\s+)?notes?\s+to\s+self|(?:add|save|put)\s+(?:this\s+)?(?:to|in|on|into)\s+my\s+scratch\s?pad)\s*[,:;.\-–—]*\s*(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        var rest = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty, rest.rangeOfCharacter(from: .letters) != nil else { return nil }
        rest = rest.prefix(1).uppercased() + rest.dropFirst()
        return rest
    }
}

// MARK: - The page

struct ScratchpadPage: View {
    @ObservedObject var model: StudioModel
    @State private var draft = ""
    @State private var editing: String?
    @State private var editText = ""
    @State private var copied: String?

    private var stamp: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM · h:mm a"
        return f
    }

    var body: some View {
        PageScroll {
            HStack(alignment: .center, spacing: 14) {
                PageTitle(title: "Jots", subtitle: "A place for quick thoughts. Say \u{201C}note to self\u{201D} and what you want to remember, and it lands here instead of in the app in front.")
                Spacer(minLength: 0)
                if Art.image("sleepy") != nil { ArtView(name: "sleepy", size: 84) }
            }

            VStack(alignment: .leading, spacing: 12) {
                MultiField(placeholder: "Write something down…", text: $draft)
                HStack {
                    Text("Notes stay on this Mac.").font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
                    Spacer()
                    Button("Save note", action: add).buttonStyle(PrimaryButton(small: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 20)

            if model.scratch.isEmpty {
                EmptyNote(text: "Nothing here yet. Hold the talk key and say \u{201C}note to self, call the dentist\u{201D}.", art: "sleepy")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.scratch.enumerated()), id: \.element.id) { i, note in
                        row(note)
                        if i < model.scratch.count - 1 { SoftDivider().padding(.horizontal, 16) }
                    }
                }
                .rtCard(padding: 6, radius: 18)
            }
        }
    }

    @ViewBuilder
    private func row(_ note: ScratchNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stamp.string(from: note.date).uppercased()).font(Fonts.sans(11, .heavy)).foregroundColor(RT.ink3).tracking(1)
                Spacer()
                if editing != note.id {
                    Button {
                        Inserter.copy(note.text)
                        copied = note.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if copied == note.id { copied = nil } }
                    } label: {
                        Image(systemName: copied == note.id ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .semibold))
                            .foregroundColor(copied == note.id ? RT.ok : RT.ink3).frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Copy")
                    Button("Edit") { editing = note.id; editText = note.text }.buttonStyle(GhostButton())
                    TrashButton { ScratchStore.delete(note); model.reload() }
                }
            }
            if editing == note.id {
                MultiField(placeholder: "", text: $editText)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.buttonStyle(GhostButton())
                    Button("Save") { ScratchStore.update(note, text: editText); editing = nil; model.reload() }
                        .buttonStyle(PrimaryButton(small: true))
                }
            } else {
                Text(note.text).font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private func add() {
        ScratchStore.create(text: draft)
        draft = ""
        model.reload()
    }
}
