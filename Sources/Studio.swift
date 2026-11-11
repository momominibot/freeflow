import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

// MARK: - What the window can ask the app to do

final class AppBridge {
    var hotkeysChanged: () -> Void = {}
    var engineChosen: (SpeechEngine) -> Void = { _ in }
    var cleanupChanged: () -> Void = {}
    var commandModeChanged: () -> Void = {}
    var idleBarChanged: () -> Void = {}
    var toggleLogin: () -> Void = {}
    var correctLast: () -> Void = {}
    var forgetLearned: () -> Void = {}
    var chooseTeamFolder: () -> Void = {}
    var clearTeamFolder: () -> Void = {}
    var copyMCP: () -> Void = {}
    var copyMCPConfig: () -> Void = {}
    var allowMic: () -> Void = {}
    var allowAccessibility: () -> Void = {}
    var showTakes: () -> Void = {}
    var deleteTakes: () -> Void = {}
    var editStyles: () -> Void = {}
    var startMeeting: () -> Void = {}
    var stopMeeting: () -> Void = {}
    var openMeetings: () -> Void = {}
    var allowScreenAudio: () -> Void = {}
    var meetingNow: () -> (app: String, seconds: Int)? = { nil }
    var transcribeFile: (URL) -> Void = { _ in }
    var fileJob: () -> (name: String, progress: Double)? = { nil }
    var summarizeNote: (URL) -> Void = { _ in }
    var summarizing: () -> Set<String> = { [] }
    var status: () -> (text: String, ok: Bool) = { ("Starting…", false) }
    var aiReady: () -> Bool = { false }
    var installingQwen: () -> Bool = { false }
    var workdayChanged: () -> Void = {}
    var detailChanged: () -> Void = {}
    var dockChanged: () -> Void = {}
    var typingChanged: () -> Void = {}
}

// MARK: - Reading the files on disk

struct HistoryEntry: Identifiable {
    let id: Int
    let date: Date
    let app: String
    let mode: String
    let text: String
    var raw: String = ""
    var secs: Double = 0
}

enum HistoryReader {
    private static let iso = ISO8601DateFormatter()

    /// Every dictation in the last part of the history file, oldest first.
    static func readAll(url: URL = Paths.historyJSON) -> [HistoryEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 2_000_000
        let start = size > window ? size - window : 0
        try? h.seek(toOffset: start)
        guard let data = try? h.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var all: [HistoryEntry] = []
        for (i, line) in lines.enumerated() where !line.isEmpty {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let text = o["text"] as? String, !text.isEmpty,
                  let t = o["t"] as? String, let date = iso.date(from: t) else { continue }
            all.append(HistoryEntry(id: i, date: date, app: o["app"] as? String ?? "", mode: o["mode"] as? String ?? "", text: text,
                                    raw: o["raw"] as? String ?? "", secs: (o["secs"] as? Double) ?? 0))
        }
        return all
    }

    /// The newest dictations (from the end of history.jsonl) and the current day streak.
    static func load(url: URL = Paths.historyJSON, limit: Int = 400) -> (entries: [HistoryEntry], streak: Int) {
        let all = readAll(url: url)
        return (Array(all.suffix(limit).reversed()), streak(of: all.map { $0.date }))
    }

    /// Words dictated per day for the last `days` days, oldest first. Commands are not dictation, so they are left out.
    static func dailyWords(_ entries: [HistoryEntry], days: Int = 14, now: Date = Date(), calendar: Calendar = .current) -> [(day: Date, words: Int)] {
        let today = calendar.startOfDay(for: now)
        var out: [(Date, Int)] = []
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let n = entries.filter { $0.mode != "command" && calendar.isDate($0.date, inSameDayAs: day) }
                .reduce(0) { $0 + TextCleaner.wordCount($1.text) }
            out.append((day, n))
        }
        return out
    }

    /// Words per minute while talking, over the dictations that have a recorded length. Nil until there are enough to say.
    static func wordsPerMinute(_ entries: [HistoryEntry], minimum: Int = 3) -> Int? {
        let timed = entries.filter { $0.mode != "command" && $0.secs >= 1 }
        guard timed.count >= minimum else { return nil }
        let words = timed.reduce(0) { $0 + TextCleaner.wordCount($1.text) }
        let secs = timed.reduce(0.0) { $0 + $1.secs }
        guard secs > 0 else { return nil }
        return Int((Double(words) / (secs / 60)).rounded())
    }

    static func streak(of dates: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while days.contains(day) {
            n += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return n
    }
}

/// One line of the dictionary or the snippets file, as shown in the window.
struct ListLine: Identifiable {
    let id: Int
    let raw: String
    let left: String
    let right: String?
}

enum ListFile {
    /// Lines that are not blank or comments. `a => b` lines get a left and a right side.
    static func read(_ url: URL) -> [ListLine] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var out: [ListLine] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let arrow = line.range(of: "=>") {
                let l = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let r = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                out.append(ListLine(id: i, raw: line, left: l, right: r.replacingOccurrences(of: "\\n", with: "\n")))
            } else {
                out.append(ListLine(id: i, raw: line, left: line, right: nil))
            }
        }
        return out
    }

    /// Removes the first line equal to `raw`, keeping every comment and the order of the rest.
    static func remove(_ raw: String, from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == raw }) { lines.remove(at: i) }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ line: String, to url: URL) {
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let sep = existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n"
        try? (existing + sep + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - The model behind the window

final class StudioModel: ObservableObject {
    /// True while the cats are on the strip above the window (CatPerch.swift); then the top bar inside the window has no cats.
    @Published var catPerched = false
    enum Page: String, CaseIterable, Identifiable {
        case home, polish, meetings, insights, dictionary, snippets, modes, transforms, scratchpad, workday, learning, help, localModel
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: return "Home"
            case .polish: return "Polish"
            case .meetings: return "Meetings"
            case .insights: return "Stats"
            case .dictionary: return "Words"
            case .snippets: return "Phrases"
            case .modes: return "Tone"
            case .transforms: return "Rewrites"
            case .scratchpad: return "Jots"
            case .workday: return "Workday"
            case .learning: return "Learning"
            case .help: return "Help"
            case .localModel: return "Set up the local AI"
            }
        }
        var icon: String {
            switch self {
            case .home: return "mic"
            case .polish: return "checkmark.seal"
            case .meetings: return "record.circle"
            case .insights: return "chart.bar"
            case .dictionary: return "character.book.closed"
            case .snippets: return "scissors"
            case .modes: return "textformat"
            case .transforms: return "wand.and.stars"
            case .scratchpad: return "note.text"
            case .workday: return "calendar.badge.clock"
            case .learning: return "sparkles"
            case .help: return "questionmark.circle"
            case .localModel: return "cpu"
            }
        }
    }

    struct SetupStep: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let action: () -> Void
    }

    let bridge: AppBridge
    let settings = Settings.shared

    @Published var page: Page = .home {
        didSet { if page == .insights { daily = HistoryReader.dailyWords(HistoryReader.readAll()) } }
    }
    @Published var entries: [HistoryEntry] = []
    @Published var streak = 0
    @Published var dictionary: [ListLine] = []
    @Published var snippets: [ListLine] = []
    @Published var learned = LearnedFile()
    @Published var statusText = ""
    @Published var statusOK = false
    @Published var micOK = false
    @Published var axOK = false
    @Published var loginOK = false
    @Published var aiOK = false
    /// Where the Mac is on the way to the free rewrite model, from the last look at Ollama (LocalModel.swift). Home, Help and the Local AI page read it.
    @Published var aiStatus: LocalModel.Status = .checking
    @Published var aiModels: [String] = []
    @Published var aiChecking = false
    /// The pictures from `--render-ui` draw a chosen state, so they never look at the machine.
    var aiFrozen = false
    private var aiInFlight = false
    @Published var installing = false
    @Published var notes: [MeetingNote] = []
    @Published var modesFile = ModesFile()
    @Published var meetingNow: (app: String, seconds: Int)?
    @Published var screenOK = false
    @Published var workdayToday: [WorkdayAnalysis.AppTime] = []
    @Published var workdayDays = 0
    @Published var detailToday: (screen: Int, typing: Int) = (0, 0)
    @Published var screenAllowed = false
    @Published var suggestions: [Suggestion] = []
    @Published var learningWeeks: (this: LearningStats.Week, last: LearningStats.Week) = (LearningStats.Week(fixes: 0, words: 0), LearningStats.Week(fixes: 0, words: 0))
    @Published var fileJob: (name: String, progress: Double)?
    @Published var summarizing: Set<String> = []
    @Published var scratch: [ScratchNote] = []
    @Published var settingsTab: SettingsTab?
    /// Bumped when the colourway changes: the whole window is rebuilt with it, so every colour is read again.
    @Published var colourTick = 0
    @Published var sidebarHidden = false
    @Published var daily: [(day: Date, words: Int)] = []

    init(bridge: AppBridge) {
        self.bridge = bridge
        reload()
    }

    func reload() {
        let h = HistoryReader.load()
        entries = h.entries
        streak = h.streak
        dictionary = ListFile.read(Paths.dictionary)
        snippets = ListFile.read(Paths.snippets)
        learned = LearnedFile.load()
        let s = bridge.status()
        statusText = s.text
        statusOK = s.ok
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axOK = AXIsProcessTrusted()
        loginOK = SMAppService.mainApp.status == .enabled
        aiOK = bridge.aiReady()
        installing = bridge.installingQwen()
        notes = MeetingFile.list()
        modesFile = ModeStore.load()
        meetingNow = bridge.meetingNow()
        screenOK = ScreenAudio.allowed
        fileJob = bridge.fileJob()
        summarizing = bridge.summarizing()
        scratch = ScratchStore.list()
        if page == .insights { daily = HistoryReader.dailyWords(HistoryReader.readAll()) }
        if page == .learning {
            learningWeeks = LearningStats.weeks(fixesByDay: settings.fixesByDay, daily: HistoryReader.dailyWords(HistoryReader.readAll()))
        }
        if page == .workday {
            let segs = WorkdayStore.load()
            workdayToday = WorkdayAnalysis.today(segs)
            workdayDays = WorkdayAnalysis.daysWithData(segs)
            detailToday = (DetailStore.count(kind: "screen"), DetailStore.count(kind: "typing"))
            screenAllowed = ScreenText.allowed
            suggestions = Suggestions.list(segments: segs, history: h.entries)
        }
    }

    func openSettings(_ tab: SettingsTab = .general) { settingsTab = tab }

    /// One look at Ollama in the background. `manual` shows "Checking…" on the page's button while it runs.
    func lookForLocalAI(manual: Bool = false) {
        if aiFrozen || aiInFlight { return }
        aiInFlight = true
        if manual { aiChecking = true }
        LocalModel.check(wanted: settings.aiModel) { [weak self] st, found in
            guard let self = self else { return }
            self.aiStatus = st
            self.aiModels = found
            self.aiOK = st.isReady
            self.aiChecking = false
            self.aiInFlight = false
        }
    }

    /// The short list in the sidebar that walks through setting up meeting notes.
    var setupSteps: [SetupStep] {
        [SetupStep(id: "try", title: "Try meeting notes", done: !notes.isEmpty, action: { [weak self] in self?.page = .meetings }),
         SetupStep(id: "others", title: "Hear the other people", done: screenOK, action: { [weak self] in self?.bridge.allowScreenAudio() }),
         SetupStep(id: "file", title: "Write down a recording", done: notes.contains { $0.kind == "file" }, action: { [weak self] in self?.page = .meetings }),
         SetupStep(id: "claude", title: "Connect your AI tools", done: settings.mcpCopied, action: { [weak self] in self?.openSettings(.mcp) })]
    }

    var setupDone: Bool { setupSteps.allSatisfy { $0.done } }

    /// A binding to one setting. Writing it saves the setting, tells the app, and redraws the window.
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void, then: @escaping () -> Void = {}) -> Binding<T> {
        Binding(get: get, set: { [weak self] v in
            set(v)
            then()
            self?.objectWillChange.send()
        })
    }
}

// MARK: - Window

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @Environment(\.colorScheme) private var scheme
    let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !model.sidebarHidden {
                    Sidebar(model: model).frame(width: 236).transition(.move(edge: .leading))
                }
                ZStack {
                    RT.paper
                    Group {
                        switch model.page {
                        case .home: HomePage(model: model)
                        case .polish: PolishPage(model: model)
                        case .meetings: MeetingsPage(model: model)
                        case .insights: InsightsPage(model: model)
                        case .dictionary: DictionaryPage(model: model)
                        case .snippets: SnippetsPage(model: model)
                        case .modes: ModesPage(model: model)
                        case .transforms: TransformsPage(model: model)
                        case .scratchpad: ScratchpadPage(model: model)
                        case .workday: WorkdayPage(model: model)
                        case .learning: LearningPage(model: model)
                        case .help: HelpPage(model: model)
                        case .localModel: LocalModelPage(model: model)
                        }
                    }
                    .id(model.page)
                    .transition(.opacity)
                }
            }

            // Along the top, like Wispr: the sidebar switch on the left, your account on the right.
            HStack(spacing: 0) {
                Button { model.sidebarHidden.toggle() } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 14, weight: .semibold)).foregroundColor(RT.ink2)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(model.sidebarHidden ? "Show the sidebar" : "Hide the sidebar")
                .padding(.leading, 82)
                Spacer()
                Button {
                    model.settings.appearance = scheme == .dark ? .light : .dark
                    AppearanceChoice.applySaved()
                    model.objectWillChange.send()
                } label: {
                    Image(systemName: scheme == .dark ? "sun.max" : "moon").font(.system(size: 15, weight: .regular)).foregroundColor(RT.ink2)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(scheme == .dark ? "Light colours" : (Colorway.current == .sunset ? "Dark brown" : "Dark purple"))
                Button { model.openSettings(.account) } label: {
                    Image(systemName: "person.crop.circle").font(.system(size: 17, weight: .regular)).foregroundColor(RT.ink2)
                        .frame(width: 30, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Account")
                .padding(.trailing, 18)
            }
            .padding(.top, 10)

            // The cats live only on the strip above the window (CatPerch.swift), never inside it (the owner, 10 Nov 2026). The window keeps
            // room above itself for them: see StudioWindow.

            if model.settingsTab != nil {
                SettingsDialog(model: model).transition(.opacity).zIndex(2)
            }
        }
        .frame(minWidth: 860, minHeight: 720)
        .background(RT.paper)
        .animation(.easeInOut(duration: 0.18), value: model.page)
        .animation(.easeInOut(duration: 0.18), value: model.settingsTab)
        .animation(.easeInOut(duration: 0.2), value: model.sidebarHidden)
        .onReceive(tick) { _ in model.reload() }
        .id(model.colourTick)
    }
}

struct Sidebar: View {
    @ObservedObject var model: StudioModel
    private let top: [StudioModel.Page] = [.home, .polish, .meetings, .insights, .dictionary, .snippets, .modes, .transforms, .scratchpad, .learning, .workday]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Emblem(size: 36)
                Wordmark(size: 27)
            }
            .padding(.top, 38).padding(.horizontal, 22).padding(.bottom, 8)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(top, id: \.self) { navItem($0) }
                }
                .padding(.horizontal, 12)
                if !model.setupDone {
                    SetupCard(model: model).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                }
            }

            VStack(spacing: 2) {
                utilityItem("Share with team", "person.badge.plus", on: false) { model.openSettings(.team) }
                utilityItem("Settings", "gearshape", on: model.settingsTab != nil) { model.openSettings() }
                navItem(.help)
            }
            .padding(.horizontal, 12).padding(.top, 8)

            // the cats' toy box: tidy, in the app; click a toy and it bounces up to the cats on the window's top edge (CatPerch.swift)
            if model.settings.catTheme && model.settings.catRunner {
                CatToyBox(stripInset: model.catPerched ? CatPerch.sideInset : 0).padding(.horizontal, 26).padding(.top, 10)
            }

            HStack(spacing: 8) {
                Circle().fill(model.statusOK ? RT.ok : RT.warn).frame(width: 8, height: 8)
                Text(model.statusOK ? "Ready · \(Settings.shared.engine.short)" : model.statusText)
                    .font(Fonts.sans(11.5, .semibold)).foregroundColor(RT.ink2).lineLimit(1)
            }
            .padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity)
        .background(RT.paper2)
    }

    private func navItem(_ p: StudioModel.Page) -> some View {
        // The Local AI page is reached from Help, so Help stays lit while it is open.
        let lit = model.page == p || (p == .help && model.page == .localModel)
        return rowButton(p.title, p.icon, on: lit && model.settingsTab == nil) { model.settingsTab = nil; model.page = p }
    }

    private func utilityItem(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        rowButton(title, icon, on: on, action: action)
    }

    private func rowButton(_ title: String, _ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).frame(width: 22)
                Text(title).font(Fonts.sans(14, on ? .heavy : .bold))
                Spacer()
            }
            .foregroundColor(on ? RT.plum : RT.ink2)
              .padding(.horizontal, 14).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous)
                    .fill(on ? RT.card : Color.clear)
                    .shadow(color: on ? RT.lift : .clear, radius: 8, y: 3)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Set up Notetaker": four small steps with a progress bar. Tapping a step does it.
struct SetupCard: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        let steps = model.setupSteps
        let done = steps.filter { $0.done }.count
        VStack(alignment: .leading, spacing: 7) {
            Text("Getting started").font(Fonts.sans(13, .heavy)).foregroundColor(RT.plum)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(RT.lilac2)
                    Capsule().fill(RT.primary).frame(width: max(6, g.size.width * CGFloat(done) / CGFloat(max(1, steps.count))))
                }
            }
            .frame(height: 5)
            ForEach(steps) { step in
                Button { step.action() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15)).foregroundColor(step.done ? RT.ok : RT.lilac)
                        Text(step.title).font(Fonts.sans(12.5, .semibold)).foregroundColor(step.done ? RT.ink3 : RT.ink)
                            .strikethrough(step.done, color: RT.ink3)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.card.opacity(0.85)))
    }
}

// MARK: - Shared page pieces

struct PageScroll<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 46).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PageTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Fonts.serif(34)).foregroundColor(RT.plum)
            Text(subtitle).font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(Fonts.serif(20)).foregroundColor(RT.plum)
    }
}

struct SoftField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Fonts.sans(14, .medium))
            .foregroundColor(RT.ink)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.paper2))
            .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).strokeBorder(RT.line2, lineWidth: 1))
    }
}

struct TrashButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").font(.system(size: 13, weight: .semibold)).foregroundColor(RT.ink3)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove")
    }
}

enum AppInfo {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(_ bundleId: String) -> String {
        if bundleId.isEmpty { return "Somewhere" }
        if let n = names[bundleId] { return n }
        var n = bundleId
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            n = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        names[bundleId] = n
        return n
    }

    static func icon(_ bundleId: String) -> NSImage? {
        if let i = icons[bundleId] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleId] = i
        return i
    }
}

// MARK: - Shared stat card

struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Circle().fill(RT.lilac2).frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundColor(RT.mauve)
            }
            Text(value).font(Fonts.serif(32)).foregroundColor(RT.plum)
            Text(label).font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 18)
    }
}

struct SoftDivider: View {
    var body: some View { Rectangle().fill(RT.lilac2).frame(height: 1) }
}

struct EmptyNote: View {
    let text: String
    var art: String = "sleepy"
    var body: some View {
        HStack(spacing: 14) {
            ArtView(name: art, size: Art.image(art) == nil ? 88 : 96)
            Text(text).font(Fonts.sans(14, .medium)).foregroundColor(RT.ink2)
            Spacer()
        }
        .rtCard(padding: 20)
    }
}

// MARK: - Learning

struct LearningPage: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        let on = model.bind({ model.settings.learnFromFixes }, { model.settings.learnFromFixes = $0 })
        let typing = model.bind({ model.settings.learnFromTyping }, { model.settings.learnFromTyping = $0 }, then: model.bridge.typingChanged)
        PageScroll {
            PageTitle(title: "Learning", subtitle: "Fix a word in the text Purrscribe typed and it remembers. The more you use it, the more it sounds like you.")

            VStack(alignment: .leading, spacing: 8) {
                Text("Is it getting better?").font(Fonts.serif(20)).foregroundColor(RT.plum)
                HStack(spacing: 22) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f", model.learningWeeks.this.per100)).font(Fonts.serif(30)).foregroundColor(RT.plum)
                        Text("fixes per 100 words this week").font(Fonts.sans(12, .bold)).foregroundColor(RT.ink2)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.learningWeeks.last.words >= 100 ? String(format: "%.1f", model.learningWeeks.last.per100) : "\u{2013}").font(Fonts.serif(30)).foregroundColor(RT.ink2)
                        Text("last week").font(Fonts.sans(12, .bold)).foregroundColor(RT.ink3)
                    }
                }
                Text(LearningStats.verdict(this: model.learningWeeks.this, last: model.learningWeeks.last))
                    .font(Fonts.sans(13, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                Text("A fix is a word you corrected after Purrscribe typed it. Fewer per 100 words, over weeks, means it is getting more accurate for you. This is the vocabulary it learns (spellings and swaps), not a retrained voice model.")
                    .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 22)

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: typing) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Learn from my own typing").font(Fonts.sans(15, .heavy)).foregroundColor(RT.ink)
                        Text("When you type a name wrongly, backspace and write it again, Purrscribe remembers the spelling, so it hears it right next time: the first time when it is plainly a spelling fix (a few letters off), after the second time otherwise. It does not record keystrokes: it looks at the line you are typing on every half second and keeps only that word. Never in password fields, password managers or terminals. Off until you switch it on.")
                            .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(RhythmeToggleStyle())
            }
            .rtCard(padding: 20)
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: on) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Learn from my corrections").font(Fonts.sans(15, .heavy)).foregroundColor(RT.ink)
                        Text("It reads that text box for about a minute, never password fields. Only the word pairs are kept, on this Mac.")
                            .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(RhythmeToggleStyle())
                HStack(spacing: 10) {
                    Button("Correct my last dictation…") { model.bridge.correctLast() }.buttonStyle(GhostButton())
                    Button("Forget everything") { model.bridge.forgetLearned() }.buttonStyle(GhostButton(danger: true))
                }
            }
            .rtCard(padding: 20)

            HStack(spacing: 14) {
                StatCard(icon: "arrow.left.arrow.right", value: "\(model.learned.fixes.count)", label: "spelling fixes")
                StatCard(icon: "textformat", value: "\(model.learned.terms.count)", label: "words it knows")
            }

            if model.learned.fixes.isEmpty && model.learned.terms.isEmpty {
                EmptyNote(text: "Nothing learned yet. Dictate something, fix a word, and it will show up here.", art: "learning")
            }
            if !model.learned.fixes.isEmpty {
                SectionTitle(text: "Fixes")
                VStack(spacing: 0) {
                    ForEach(Array(model.learned.fixes.enumerated()), id: \.offset) { i, f in
                        HStack(spacing: 12) {
                            Text(f.wrong).font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink2)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundColor(RT.ink3)
                            Text(f.right).font(Fonts.sans(14.5, .bold)).foregroundColor(RT.ink)
                            Spacer()
                            Text("×\(f.votes)").font(Fonts.sans(12, .heavy)).foregroundColor(RT.mauve)
                                .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(RT.lilac2))
                            TrashButton { forgetFix(f.wrong) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        if i < model.learned.fixes.count - 1 { SoftDivider().padding(.horizontal, 14) }
                    }
                }
                .rtCard(padding: 6, radius: 18)
            }
            if !model.learned.terms.isEmpty {
                SectionTitle(text: "Words")
                FlowChips(items: model.learned.terms.map { $0.term })
            }
        }
    }

    private func forgetFix(_ wrong: String) {
        var f = LearnedFile.load()
        f.fixes.removeAll { $0.wrong == wrong }
        f.save()
        model.reload()
    }
}

/// Words laid out in rows, wrapping like text.
struct FlowChips: View {
    let items: [String]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { w in
                Text(w).font(Fonts.sans(13.5, .bold)).foregroundColor(RT.plum)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(Capsule().fill(RT.card))
                    .overlay(Capsule().strokeBorder(RT.lilac, lineWidth: 1))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Settings

struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(Fonts.serif(20)).foregroundColor(RT.plum)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 22)
    }
}

struct RowLabel: View {
    let title: String
    let note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.ink)
            if let note = note, !note.isEmpty {
                Text(note).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let note: String?
    let control: Control
    init(title: String, note: String?, @ViewBuilder control: () -> Control) { self.title = title; self.note = note; self.control = control() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RowLabel(title: title, note: note)
            control
        }
    }
}

struct PermissionRow: View {
    let title: String
    let ok: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17)).foregroundColor(ok ? RT.ok : RT.warn)
            Text(title).font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.ink)
            Spacer()
            if !ok { Button("Allow…", action: action).buttonStyle(GhostButton()) }
            else { Text("Allowed").font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink3) }
        }
    }
}

extension TalkKey {
    var chipTitle: String {
        switch self {
        case .rightOption: return "Right Option"
        case .fn: return "Fn"
        case .leftControl: return "Left Control"
        case .rightCommand: return "Right Command"
        case .rightControl: return "Right Control"
        }
    }
}

extension Language {
    /// The short name for a chip: no brackets with the native script.
    var chipTitle: String {
        switch self {
        case .mixed: return "English + 中文"
        case .chinese: return "中文"
        case .tamil: return "தமிழ்"
        case .hindi: return "हिन्दी"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        default: return title
        }
    }
}

extension CleanupLevel {
    var chipTitle: String {
        switch self {
        case .none: return "Raw"
        case .light: return "Light"
        case .medium: return "AI tidy"
        }
    }

    var explain: String {
        switch self {
        case .none: return "Exactly what was heard, no changes."
        case .light: return "Fillers and spelling by rules. Instant."
        case .medium: return "A local AI fixes grammar, lists and self-corrections, in the tone of the app you are in."
        }
    }
}

// MARK: - The window itself

/// The Studio window. While the cats are on, its top edge stays `CatPerch.want` points below the top of the screen's usable area, so the
/// cats always have their strip above the window, outside the app: a window dragged higher settles back down, a saved place that is too
/// high is moved down, and one too tall for the rest of the screen gets shorter (never below its smallest size).
final class StudioWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        var f = super.constrainFrameRect(frameRect, to: screen)
        let s = Settings.shared
        guard s.catTheme, s.catRunner, !styleMask.contains(.fullScreen), let vf = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else { return f }
        let top = vf.maxY - CatPerch.want
        guard f.maxY > top else { return f }
        if f.height > top - vf.minY { f.size.height = max(minSize.height, top - vf.minY) }
        f.origin.y = top - f.height
        return f
    }
}

final class StudioWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var perch: CatPerch?
    let model: StudioModel

    init(bridge: AppBridge) {
        model = StudioModel(bridge: bridge)
        super.init()
        NotificationCenter.default.addObserver(forName: .freeflowLookChanged, object: nil, queue: .main) { [weak self] _ in
            guard let w = self?.window else { return }
            w.backgroundColor = RT.windowBackground
            w.setFrame(w.constrainFrameRect(w.frame, to: w.screen), display: true)            // the cats were just turned on: make room
        }
    }

    var isOpen: Bool { window?.isVisible == true }

    func show(page: StudioModel.Page? = nil) {
        if let p = page { model.page = p }
        model.reload()
        if window == nil {
            let w = StudioWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = RT.windowBackground
            w.minSize = NSSize(width: 860, height: 720)
            w.contentView = NSHostingView(rootView: StudioView(model: model))
            w.delegate = self
            w.setFrameAutosaveName("FreeFlowStudio")
            if !w.setFrameUsingName("FreeFlowStudio") { centerOnMouseScreen(w) }
            // The sidebar needs about 720 points to show its setup list; an older, shorter saved window grows down to fit.
            if w.frame.height < 740 {
                var f = w.frame
                f.origin.y -= 740 - f.height
                f.size.height = 740
                w.setFrame(f, display: false)
            }
            w.setFrame(w.constrainFrameRect(w.frame, to: w.screen), display: false)   // an older saved place may leave the cats no room
            window = w
            let perch = CatPerch(window: w)
            perch.onPerched = { [weak self] on in if self?.model.catPerched != on { self?.model.catPerched = on } }
            self.perch = perch
        }
        // A menu-bar app has no Dock icon. While this window is open it gets one, so ⌘Tab, ⌘C and ⌘V work as usual.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        perch?.layout()
    }

    /// First time only: open on the screen you are looking at (where the pointer is), not always the main one.
    private func centerOnMouseScreen(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return w.center() }
        // Lower than the middle, so the cats have room to sit on the top edge (CatPerch.swift).
        let free = max(0, vf.height - w.frame.height)
        w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.minY + free * 0.2))
    }

    /// The green button fills the screen but leaves the cats their strip above the window.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.constrainFrameRect(newFrame, to: window.screen)
    }

    func windowWillClose(_ notification: Notification) {
        perch?.hide()
        // Back to the menu bar only, unless the Dock icon was asked for.
        NSApp.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
    }

    /// The window's id, for screenshots.
    var windowNumber: Int { window?.windowNumber ?? 0 }
}

// MARK: - Pictures of the interface, for checking the look without a screen

enum UIShots {
    private static var shotAppearance = NSAppearance(named: .aqua)
    /// FF_SHOT_WIDTH=860 draws the pages at the narrowest the window can be.
    private static let shotWidth = CGFloat(Double(ProcessInfo.processInfo.environment["FF_SHOT_WIDTH"] ?? "") ?? 960)

    /// Draws every page and every state of the floating bar to PNG files in `dir`, light, and again in dark royal purple in `dir/dark`.
    static func render(to dir: URL) {
        // FF_SHOT_COLOURWAY=sunset draws the Sunset colours without changing the saved choice.
        if let way = ProcessInfo.processInfo.environment["FF_SHOT_COLOURWAY"], let c = Colorway(rawValue: way) { Colorway.current = c }
        shotAppearance = NSAppearance(named: .aqua)
        renderSet(to: dir)
        shotAppearance = NSAppearance(named: .darkAqua)
        let dark = dir.appendingPathComponent("dark")
        try? FileManager.default.createDirectory(at: dark, withIntermediateDirectories: true)
        renderSet(to: dark)
    }

    private static func renderSet(to dir: URL) {
        let bridge = AppBridge()
        bridge.status = { ("Whisper · offline, no word limit", true) }
        bridge.aiReady = { true }
        let model = StudioModel(bridge: bridge)
        model.aiFrozen = true                                       // draw the states below, never look at this Mac's Ollama
        model.aiStatus = .ready(LocalModel.recommended)
        model.aiModels = [LocalModel.recommended, "llama3.2:3b"]
        PolishModel.renderSample = "i think we should of sent the the invoice to the client yesterday. Its a very good chance that they will recieve it in order to review it before friday, but i am not sure."
        for page in StudioModel.Page.allCases {
            model.page = page
            // The Meetings page is long; draw it tall so the notes show.
            let tall: [StudioModel.Page: CGFloat] = [.meetings: 1500, .insights: 1000, .help: 1300, .scratchpad: 800, .polish: 1700, .localModel: 1500]
            let size = NSSize(width: shotWidth, height: tall[page] ?? 740)
            png(NSHostingView(rootView: StudioView(model: model)), size: size, to: dir.appendingPathComponent("page-\(page.rawValue).png"))
        }

        model.page = .home
        // General runs long (the cat size sits in Appearance), Account carries the plans and MCP has eight tiles in three rows, so those three are drawn tall.
        // The card is normally 600 high and scrolls, so a tall window alone would still clip it: raise its height to the window's (less the 28 of margin each side).
        let tallTab: [SettingsTab: CGFloat] = [.general: 1700, .account: 1300, .mcp: 840]
        for tab in SettingsTab.allCases {
            model.settingsTab = tab
            let height = tallTab[tab] ?? 740
            SettingsDialog.maxHeight = tallTab[tab] == nil ? 600 : height - 56
            png(NSHostingView(rootView: StudioView(model: model)), size: NSSize(width: shotWidth, height: height), to: dir.appendingPathComponent("settings-\(tab.rawValue).png"))
        }
        SettingsDialog.maxHeight = 600
        model.settingsTab = nil

        // The Local AI page at each point a new download can be at, and Home with the banner for someone who has not set it up.
        let aiStates: [(String, LocalModel.Status, [String])] = [
            ("not-installed", .notInstalled, []),
            ("not-running", .notRunning, []),
            ("model-missing", .missingModel(LocalModel.recommended), ["llama3.2:3b"]),
            ("ready", .ready(LocalModel.recommended), [LocalModel.recommended, "llama3.2:3b"]),
        ]
        for (name, st, found) in aiStates {
            model.aiStatus = st
            model.aiModels = found
            model.page = .localModel
            png(NSHostingView(rootView: StudioView(model: model)), size: NSSize(width: shotWidth, height: 1500), to: dir.appendingPathComponent("localmodel-\(name).png"))
        }
        model.aiStatus = .notInstalled
        model.aiModels = []
        model.page = .home
        png(NSHostingView(rootView: StudioView(model: model)), size: NSSize(width: shotWidth, height: 740), to: dir.appendingPathComponent("home-local-ai-banner.png"))
        model.aiStatus = .ready(LocalModel.recommended)
        model.page = .home

        let states: [(String, (PillModel) -> Void)] = [
            ("idle", { _ in }),
            ("listening", { m in
                m.kind = .listening
                m.levels = wave(0)
                m.level = 0.5
            }),
            ("handsfree", { m in
                m.kind = .listening
                m.text = "Hands-free · tap Fn to finish"
                m.levels = wave(1.3)
                m.level = 0.35
            }),
            ("working", { m in m.kind = .working; m.text = "Transcribing…" }),
            ("message", { m in m.kind = .message; m.text = "Learned: Ranklor → Ranklore" }),
            ("long", { m in m.kind = .message; m.text = "Copied · press ⌘V to paste (allow Accessibility to type automatically)" }),
        ]
        for (name, setup) in states {
            let m = PillModel()
            setup(m)
            let backdrop = ZStack {
                LinearGradient(colors: [Color(hex: 0xDDE4F0), Color(hex: 0xF3E7EE)], startPoint: .top, endPoint: .bottom)
                PillView(m: m)
            }
            png(NSHostingView(rootView: backdrop), size: PillView.size, to: dir.appendingPathComponent("pill-\(name).png"))
        }
    }

    private static func wave(_ phase: Double) -> [CGFloat] {
        var out: [CGFloat] = []
        for i in 0..<18 {
            let a = sin(Double(i) * 0.7 + phase)
            let b = cos(Double(i) * 0.27)
            out.append(CGFloat(0.12 + 0.7 * abs(a * b)))
        }
        return out
    }

    private static func png(_ view: NSView, size: NSSize, to url: URL) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = shotAppearance
        w.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }
}
