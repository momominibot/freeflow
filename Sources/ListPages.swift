import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Where a dictionary or snippet entry came from.
enum EntrySource { case personal, team, learned }

struct EntryRow: Identifiable {
    let id: String
    let left: String
    let right: String?
    let source: EntrySource
    let raw: String
    let order: Int
}

/// Reading and writing the files behind the Dictionary and Snippets pages.
enum ListPageData {
    static func teamFile(_ name: String) -> URL? {
        Settings.shared.teamFolderURL?.appendingPathComponent(name)
    }

    static func rows(personal: [ListLine], teamFileName: String, learned: LearnedFile?) -> [EntryRow] {
        var out: [EntryRow] = []
        for (i, l) in personal.enumerated() {
            out.append(EntryRow(id: "p\(l.id)", left: l.left, right: l.right, source: .personal, raw: l.raw, order: i))
        }
        if let t = teamFile(teamFileName) {
            for (i, l) in ListFile.read(t).enumerated() {
                out.append(EntryRow(id: "t\(l.id)", left: l.left, right: l.right, source: .team, raw: l.raw, order: i))
            }
        }
        if let learned = learned {
            for (i, f) in learned.fixes.enumerated() {
                out.append(EntryRow(id: "lf\(i)", left: f.wrong, right: f.right, source: .learned, raw: "", order: i))
            }
            for (i, t) in learned.terms.enumerated() {
                out.append(EntryRow(id: "lt\(i)", left: t.term, right: nil, source: .learned, raw: "", order: i))
            }
        }
        return out
    }

    /// Filters by tab and search text, then sorts A to Z, or newest first.
    static func visible(_ rows: [EntryRow], tab: String, query: String, newestFirst: Bool) -> [EntryRow] {
        var r = rows.filter {
            switch tab {
            case "Personal": return $0.source == .personal
            case "Learned": return $0.source == .learned
            case "Shared with team": return $0.source == .team
            default: return true
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { r = r.filter { $0.left.localizedCaseInsensitiveContains(q) || ($0.right ?? "").localizedCaseInsensitiveContains(q) } }
        if newestFirst { r.sort { $0.order > $1.order } }
        else { r.sort { $0.left.localizedCaseInsensitiveCompare($1.left) == .orderedAscending } }
        return r
    }

    /// Asks for a file and returns its text and lower-case extension.
    static func pickFile() -> (String, String)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .json, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return (text, url.pathExtension.lowercased())
    }

    static func exportFile(_ source: URL, name: String) -> String {
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return "There is nothing to export yet." }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? "Saved \(url.lastPathComponent)" : "Could not save that file."
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @ObservedObject var model: StudioModel
    @State private var tab = "All"
    @State private var query = ""
    @State private var searching = false
    @State private var newestFirst = false
    @State private var adding = false
    @State private var draft = ""
    @State private var note = ""

    private var rows: [EntryRow] { ListPageData.rows(personal: model.dictionary, teamFileName: TeamFolder.dictionary, learned: model.learned) }

    var body: some View {
        let shown = ListPageData.visible(rows, tab: tab, query: query, newestFirst: newestFirst)
        WidePageScroll {
            HStack(alignment: .center) {
                Text("Words").font(Fonts.serif(34)).foregroundColor(RT.plum)
                Spacer()
                importMenu
                Button("Add new") { adding.toggle() }.buttonStyle(PrimaryButton(small: true))
            }

            HStack(spacing: 4) {
                TabStrip(tabs: ["All", "Personal", "Learned", "Shared with team"], selection: $tab)
                IconButton(symbol: "magnifyingglass", on: searching, help: "Search") { searching.toggle(); if !searching { query = "" } }
                IconButton(symbol: "arrow.up.arrow.down", on: newestFirst, help: newestFirst ? "Newest first. Tap for A to Z" : "A to Z. Tap for newest first") { newestFirst.toggle() }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { model.reload() }
            }
            if searching { SoftField(placeholder: "Search words", text: $query) }

            if adding {
                VStack(alignment: .leading, spacing: 10) {
                    SoftField(placeholder: "Ranklore   or   Rank Lore => Ranklore", text: $draft).onSubmit(add)
                    HStack {
                        Text("To always swap a spelling, write wrong => right.").font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
                        Spacer()
                        Button("Cancel") { adding = false; draft = "" }.buttonStyle(GhostButton())
                        Button("Add", action: add).buttonStyle(PrimaryButton(small: true))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .rtCard(padding: 18)
            }

            TipBanner(key: "banner.dictionary", title: "Teach it your words.",
                      text: "Add a name once, or correct a word after FreeFlow types it. Names, jargon and uncommon words then come out spelled your way.",
                      art: "words", model: model) {
                HStack(spacing: 8) {
                    Button("Add new word") { adding = true }.buttonStyle(PrimaryButton(small: true))
                    ForEach(model.learned.terms.prefix(4), id: \.term) { t in
                        Text(t.term).font(Fonts.sans(12.5, .bold)).foregroundColor(RT.plum)
                            .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(RT.card.opacity(0.75)))
                    }
                }
            }

            if !note.isEmpty { Text(note).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ok) }

            if shown.isEmpty {
                EmptyNote(text: emptyText, art: "words")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                        HStack(spacing: 12) {
                            if let right = row.right {
                                Text(row.left).font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink2)
                                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundColor(RT.ink3)
                                Text(right).font(Fonts.sans(14.5, .bold)).foregroundColor(RT.ink)
                            } else {
                                Text(row.left).font(Fonts.sans(14.5, .bold)).foregroundColor(RT.ink)
                            }
                            if row.source == .learned { Text("\u{2728}").font(.system(size: 13)).help("Learned from your corrections") }
                            if row.source == .team { badge("Team") }
                            Spacer()
                            if row.source == .personal { TrashButton { remove(row) } }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        if i < shown.count - 1 { SoftDivider().padding(.horizontal, 14) }
                    }
                }
                .rtCard(padding: 4, radius: 18)
            }
        }
    }

    private var emptyText: String {
        if !query.isEmpty { return "No word matches that." }
        switch tab {
        case "Learned": return "Nothing learned yet. Fix a word in the text FreeFlow typed and it will show up here."
        case "Shared with team": return model.settings.teamFolderURL == nil ? "No team folder yet. Pick one in Settings \u{203A} Team." : "Your team has not added any words."
        default: return "No words yet. Add a name Whisper keeps getting wrong."
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(Fonts.sans(10.5, .heavy)).foregroundColor(RT.plum).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(RT.lilac2))
    }

    private var importMenu: some View {
        Menu {
            Button("From a file…") { importFile() }
            Button("From the clipboard") { importText(NSPasteboard.general.string(forType: .string) ?? "", ext: "txt") }
            Divider()
            Button("Export…") { note = ListPageData.exportFile(Paths.dictionary, name: "FreeFlow dictionary.txt") }
        } label: {
            Text("Import").font(Fonts.sans(13, .bold)).foregroundColor(RT.ink2)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.card.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).strokeBorder(RT.line, lineWidth: 1.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func importFile() {
        guard let (text, ext) = ListPageData.pickFile() else { return }
        importText(text, ext: ext)
    }

    private func importText(_ text: String, ext: String) {
        let lines = ListImport.dictionaryLines(from: text, ext: ext)
        let fresh = ListImport.fresh(lines, existing: model.dictionary.map { $0.raw })
        for l in fresh { Vocabulary.add(l) }
        note = fresh.isEmpty ? (lines.isEmpty ? "Found nothing to add in that." : "Those words are already in your dictionary.") : "Added \(fresh.count) \(fresh.count == 1 ? "word" : "words")."
        model.reload()
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Vocabulary.add(t)
        draft = ""
        note = ""
        model.reload()
    }

    private func remove(_ row: EntryRow) {
        ListFile.remove(row.raw, from: Paths.dictionary)
        model.reload()
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @ObservedObject var model: StudioModel
    @State private var tab = "All"
    @State private var query = ""
    @State private var searching = false
    @State private var newestFirst = false
    @State private var adding = false
    @State private var cue = ""
    @State private var expansion = ""
    @State private var error = ""
    @State private var note = ""

    private var rows: [EntryRow] { ListPageData.rows(personal: model.snippets, teamFileName: TeamFolder.snippets, learned: nil) }

    var body: some View {
        let shown = ListPageData.visible(rows, tab: tab, query: query, newestFirst: newestFirst)
        WidePageScroll {
            HStack(alignment: .center) {
                Text("Phrases").font(Fonts.serif(34)).foregroundColor(RT.plum)
                Spacer()
                importMenu
                Button("Add new") { adding.toggle() }.buttonStyle(PrimaryButton(small: true))
            }

            HStack(spacing: 4) {
                TabStrip(tabs: ["All", "Personal", "Shared with team"], selection: $tab)
                IconButton(symbol: "magnifyingglass", on: searching, help: "Search") { searching.toggle(); if !searching { query = "" } }
                IconButton(symbol: "arrow.up.arrow.down", on: newestFirst, help: newestFirst ? "Newest first. Tap for A to Z" : "A to Z. Tap for newest first") { newestFirst.toggle() }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { model.reload() }
            }
            if searching { SoftField(placeholder: "Search snippets", text: $query) }

            if adding {
                VStack(alignment: .leading, spacing: 10) {
                    SoftField(placeholder: "When I say…   (my email address)", text: $cue)
                    MultiField(placeholder: "Type this…", text: $expansion)
                    HStack {
                        if !error.isEmpty { Text(error).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.high) }
                        Spacer()
                        Button("Cancel") { adding = false; cue = ""; expansion = ""; error = "" }.buttonStyle(GhostButton())
                        Button("Add snippet", action: add).buttonStyle(PrimaryButton(small: true))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .rtCard(padding: 18)
            }

            TipBanner(key: "banner.snippets", title: "Say a little, type a lot.",
                      text: "Keep the text you type again and again, an email address, a reply, a prompt. Say its short cue and the whole thing appears.",
                      art: "snippets", model: model) {
                VStack(alignment: .leading, spacing: 6) {
                    example("\u{201C}my LinkedIn\u{201D}", "https://www.linkedin.com/in/your-name/")
                    example("\u{201C}rewrite prompt\u{201D}", "Rewrite this to be more concise\u{2026}")
                    Button("Add new snippet") { adding = true }.buttonStyle(PrimaryButton(small: true)).padding(.top, 4)
                }
            }

            if !note.isEmpty { Text(note).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ok) }

            if shown.isEmpty {
                EmptyNote(text: !query.isEmpty ? "No snippet matches that." : "No snippets yet. Add the things you type again and again.", art: "snippets")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, row in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("\u{201C}\(row.left)\u{201D}").font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.plum)
                                    if row.source == .team {
                                        Text("Team").font(Fonts.sans(10.5, .heavy)).foregroundColor(RT.plum)
                                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(RT.lilac2))
                                    }
                                }
                                Text(row.right ?? "").font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink2)
                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if row.source == .personal { TrashButton { remove(row) } }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        if i < shown.count - 1 { SoftDivider().padding(.horizontal, 14) }
                    }
                }
                .rtCard(padding: 4, radius: 18)
            }
        }
    }

    private func example(_ cue: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(cue).font(Fonts.sans(12.5, .bold)).foregroundColor(RT.plum).italic()
                .padding(.horizontal, 11).padding(.vertical, 6).background(Capsule().fill(RT.card.opacity(0.75)))
            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(RT.ink3)
            Text(text).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2).lineLimit(1)
                .padding(.horizontal, 11).padding(.vertical, 6).background(Capsule().fill(RT.card.opacity(0.75)))
        }
    }

    private var importMenu: some View {
        Menu {
            Button("From a file…") {
                guard let (text, ext) = ListPageData.pickFile() else { return }
                importText(text, ext: ext)
            }
            Button("From the clipboard") { importText(NSPasteboard.general.string(forType: .string) ?? "", ext: "txt") }
            Divider()
            Button("Export…") { note = ListPageData.exportFile(Paths.snippets, name: "FreeFlow snippets.txt") }
        } label: {
            Text("Import").font(Fonts.sans(13, .bold)).foregroundColor(RT.ink2)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.card.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).strokeBorder(RT.line, lineWidth: 1.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func importText(_ text: String, ext: String) {
        let lines = ListImport.snippetLines(from: text, ext: ext).filter { line in
            guard let arrow = line.range(of: "=>") else { return false }
            let c = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.count <= 60
        }
        let fresh = ListImport.fresh(lines, existing: model.snippets.map { $0.raw })
        _ = Personalization.load()
        for l in fresh { ListFile.append(l, to: Paths.snippets) }
        note = fresh.isEmpty ? (lines.isEmpty ? "Found no cue and text pairs in that." : "Those snippets are already saved.") : "Added \(fresh.count) \(fresh.count == 1 ? "snippet" : "snippets")."
        model.reload()
    }

    private func add() {
        let c = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !e.isEmpty else { error = "Fill in both boxes."; return }
        guard !c.contains("=>"), c.count <= 60, Snippet(cue: c, expansion: e) != nil else {
            error = "That cue is too long or has no words in it."
            return
        }
        if model.snippets.contains(where: { $0.left.caseInsensitiveCompare(c) == .orderedSame }) {
            error = "You already have a snippet with that cue."
            return
        }
        _ = Personalization.load()   // makes sure the file and its header exist
        ListFile.append("\(c) => \(e.replacingOccurrences(of: "\n", with: "\\n"))", to: Paths.snippets)
        cue = ""
        expansion = ""
        error = ""
        adding = false
        model.reload()
    }

    private func remove(_ row: EntryRow) {
        ListFile.remove(row.raw, from: Paths.snippets)
        model.reload()
    }
}
