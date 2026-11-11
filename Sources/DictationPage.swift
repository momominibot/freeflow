import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A page that is wide enough for a main column and a side panel.
struct WidePageScroll<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 46).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A soft banner with a title, a line of text, a picture and room for buttons. Closing it is remembered.
struct TipBanner<Content: View>: View {
    let key: String
    let title: String
    let text: String
    var art: String = "hello"
    @ObservedObject var model: StudioModel
    let content: Content

    init(key: String, title: String, text: String, art: String = "hello", model: StudioModel, @ViewBuilder content: () -> Content) {
        self.key = key; self.title = title; self.text = text; self.art = art; self.model = model; self.content = content()
    }

    var body: some View {
        if !model.settings.isDismissed(key) {
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        // fixedSize: a long banner must wrap its title, never cut it to "Turn on free r..."
                        Text(title).font(Fonts.serif(25)).foregroundColor(RT.plum).fixedSize(horizontal: false, vertical: true)
                        Text(text).font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                        content
                    }
                    Spacer(minLength: 8)
                    if Art.image(art) != nil { ArtView(name: art, size: 104) }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                Button {
                    model.settings.dismiss(key)
                    model.objectWillChange.send()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundColor(RT.ink2)
                        .frame(width: 24, height: 24).background(Circle().fill(RT.card.opacity(0.7)))
                }
                .buttonStyle(.plain).padding(10).help("Close")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RT.radius, style: .continuous)
                    .fill(LinearGradient(colors: [RT.lilac2, RT.blush2], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
    }
}

extension TipBanner where Content == EmptyView {
    init(key: String, title: String, text: String, art: String = "hello", model: StudioModel) {
        self.init(key: key, title: title, text: text, art: art, model: model) { EmptyView() }
    }
}

struct ContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Tabs with an underline, like Wispr's All / Personal / Shared.
struct TabStrip: View {
    let tabs: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 24) {
            ForEach(tabs, id: \.self) { t in
                let on = t == selection
                Button { selection = t } label: {
                    VStack(spacing: 7) {
                        Text(t).font(Fonts.sans(14, on ? .heavy : .bold)).foregroundColor(on ? RT.plum : RT.ink3).lineLimit(1).fixedSize()
                        Rectangle().fill(on ? RT.plum : Color.clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(RT.lilac2).frame(height: 1).offset(y: 0) }
    }
}

/// A little round icon button for the end of a tab strip or a list header.
struct IconButton: View {
    let symbol: String
    var on = false
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundColor(on ? RT.plum : RT.ink3)
                .frame(width: 30, height: 30).background(Circle().fill(on ? RT.lilac2 : Color.clear)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - The Dictation page

struct HomePage: View {
    @ObservedObject var model: StudioModel
    @State private var searching = false
    @State private var query = ""
    @State private var shown = 40
    @State private var exported = ""
    @State private var contentWidth: CGFloat = 900

    private func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private var filtered: [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.entries }
        return model.entries.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.raw.localizedCaseInsensitiveContains(q) || AppInfo.name($0.app).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let key = model.settings.talkKey
        let name = model.settings.firstName.trimmingCharacters(in: .whitespaces)
        let list = filtered
        WidePageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Text(name.isEmpty ? "Welcome back" : "Welcome back, \(name)").font(Fonts.serif(36)).foregroundColor(RT.plum)
                HStack(spacing: 8) {
                    Text(model.settings.doubleTapToStart ? "Double-tap" : "Tap").font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink2)
                    KeyCap(text: key.short)
                    Text(model.settings.doubleTapToStart ? "to start, double-tap again to finish. Or hold it and talk." : "to start, tap again to finish. Or hold it and talk.").font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in Color.clear.preference(key: ContentWidthKey.self, value: g.size.width) })
            .onPreferenceChange(ContentWidthKey.self) { contentWidth = $0 }

            // Wide enough, the numbers sit beside the list. In a narrow window they go on top, so the banner keeps room to read.
            let narrow = contentWidth < 640
            if narrow { statsPanel }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    LocalAIBanner(model: model)
                    TipBanner(key: "tip.scratchpad", title: "Jot it down, don\u{2019}t type it",
                              text: "Start with \u{201C}note to self\u{201D} and the rest goes to your Jots instead of the app in front.",
                              art: "sleepy", model: model) {
                        Button("Open Jots") { model.page = .scratchpad }.buttonStyle(GhostButton())
                    }

                    if model.entries.isEmpty {
                        firstTime(key)
                    } else {
                        HStack(spacing: 6) {
                            SectionTitle(text: "Recent")
                            Spacer()
                            IconButton(symbol: "magnifyingglass", on: searching, help: "Search your dictations") {
                                searching.toggle()
                                if !searching { query = "" }
                            }
                            Menu {
                                Button("Markdown…") { export("md") }
                                Button("Plain text…") { export("txt") }
                                Button("JSON…") { export("json") }
                            } label: {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold)).foregroundColor(RT.ink3)
                                    .frame(width: 30, height: 30)
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30).help("Export your dictations")
                        }
                        if searching { SoftField(placeholder: "Search what you said, or an app", text: $query) }
                        if !exported.isEmpty { Text(exported).font(Fonts.sans(12, .semibold)).foregroundColor(RT.ok) }
                        if list.isEmpty {
                            Text("Nothing matches that.").font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink2)
                        } else {
                            HistoryList(entries: Array(list.prefix(shown)))
                            if list.count > shown {
                                Button("Show more") { shown += 40 }.buttonStyle(GhostButton())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !narrow { statsPanel }
            }
        }
        .onAppear { model.lookForLocalAI() }
    }

    private var statsPanel: some View {
        let s = model.settings
        let wpm = HistoryReader.wordsPerMinute(model.entries)
        let saved = InsightMath.timeSavedMinutes(words: s.wordsTotal)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                statLine(number(s.wordsTotal), "total words")
                statLine(wpm.map { "\($0)" } ?? "\u{2013}", "wpm")
                statLine("\(model.streak)", model.streak == 1 ? "day streak" : "day streak")
            }
            .padding(22)
            SoftDivider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(s.wordsToday)).font(Fonts.sans(15, .heavy)).foregroundColor(RT.mauve)
                    Text("words today").font(Fonts.sans(14, .bold)).foregroundColor(RT.ink)
                }
                Text(saved > 0 ? "About \(InsightMath.hoursAndMinutes(saved)) saved so far, against typing." : "Talk a little and the time you save shows up here.")
                    .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                Button("See your insights") { model.page = .insights }.buttonStyle(GhostButton())
            }
            .padding(22)
        }
        .frame(width: contentWidth < 640 ? nil : 252)
        .frame(maxWidth: contentWidth < 640 ? .infinity : nil, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: RT.radius, style: .continuous).fill(RT.card))
        .shadow(color: RT.lift, radius: 16, y: 6)
    }

    private func statLine(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(Fonts.serif(30)).foregroundColor(RT.plum)
            Text(label).font(Fonts.sans(14, .bold)).foregroundColor(RT.ink2)
        }
    }

    private func firstTime(_ key: TalkKey) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it now").font(Fonts.serif(22)).foregroundColor(RT.plum)
            HStack(spacing: 8) {
                KeyCap(text: key.short)
                Text(model.settings.doubleTapToStart ? "double-tap it, say anything, double-tap it to finish." : "tap it, say anything, tap it again.").font(Fonts.sans(14, .medium)).foregroundColor(RT.ink2)
            }
            HStack(spacing: 8) {
                KeyCap(text: model.settings.commandKey.short)
                Text("hold it with text selected, and say what to change.").font(Fonts.sans(14, .medium)).foregroundColor(RT.ink2)
            }
            Text("Your words are typed into whatever app you are in. They show up here too.")
                .font(Fonts.sans(13, .medium)).foregroundColor(RT.ink3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 24)
    }

    private func export(_ ext: String) {
        let all = HistoryReader.readAll()
        guard !all.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Purrscribe dictations.\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String
        switch ext {
        case "md": text = HistoryExport.markdown(all)
        case "json": text = HistoryExport.json(all)
        default: text = HistoryExport.plain(all)
        }
        if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
            exported = "Saved \(all.count) dictations to \(url.lastPathComponent)"
        } else {
            exported = "Could not save that file."
        }
    }
}

struct HistoryList: View {
    let entries: [HistoryEntry]

    private var groups: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        var order: [String] = []
        var map: [String: [HistoryEntry]] = [:]
        for e in entries {
            let label: String
            if cal.isDateInToday(e.date) { label = "Today" }
            else if cal.isDateInYesterday(e.date) { label = "Yesterday" }
            else { label = f.string(from: e.date) }
            if map[label] == nil { order.append(label) }
            map[label, default: []].append(e)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.0.uppercased()).font(Fonts.sans(11.5, .heavy)).foregroundColor(RT.ink3).tracking(1.2)
                    VStack(spacing: 0) {
                        ForEach(Array(group.1.enumerated()), id: \.element.id) { i, e in
                            HistoryRow(entry: e)
                            if i < group.1.count - 1 { SoftDivider().padding(.leading, 76) }
                        }
                    }
                    .rtCard(padding: 6, radius: 18)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var copied = false
    @State private var showOriginal = false

    private var time: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: entry.date).lowercased()
    }

    private var changed: Bool {
        let a = entry.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !a.isEmpty && a != entry.text.trimmingCharacters(in: .whitespacesAndNewlines) && entry.mode != "command"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(time).font(Fonts.sans(12, .bold)).foregroundColor(RT.ink3)
                if let icon = AppInfo.icon(entry.app) {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20).help(AppInfo.name(entry.app))
                }
            }
            .frame(width: 62, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                if entry.mode == "command" {
                    Text("Command").font(Fonts.sans(10.5, .heavy)).foregroundColor(RT.plum)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(RT.blush2))
                }
                Text(showOriginal ? entry.raw : entry.text).font(Fonts.sans(14.5, .medium)).foregroundColor(showOriginal ? RT.ink2 : RT.ink)
                    .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                if changed {
                    Button(showOriginal ? "Show the tidied text" : "Show what I said") { showOriginal.toggle() }
                        .buttonStyle(.plain).font(Fonts.sans(11.5, .bold)).foregroundColor(RT.mauve)
                }
            }
            Spacer(minLength: 8)

            Button {
                Inserter.copy(showOriginal ? entry.raw : entry.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(copied ? RT.ok : RT.ink3).frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}
