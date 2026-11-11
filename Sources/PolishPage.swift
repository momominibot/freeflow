import SwiftUI
import AppKit

// MARK: - The model behind the Polish page

/// Checks the text you type or paste, a moment after you stop. Everything runs on this Mac (the grammar checker is built in; the
/// rewrites use the local AI).
final class PolishModel: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { scheduleCheck() } } }
    @Published private(set) var issues: [PolishIssue] = []
    @Published private(set) var stats: WritingStats?
    @Published private(set) var tone: [ToneTag] = []
    @Published var filter: PolishKind?
    @Published var mode: RewriteMode = .clearer
    @Published private(set) var rewriting = false
    @Published private(set) var rewrite: String?
    @Published private(set) var rewriteError = ""
    @Published var lookup = ""
    @Published private(set) var synonyms: [String] = []
    @Published private(set) var checked = false

    /// Only for the picture of this page that `--render-ui` makes: some text with problems in it, already checked.
    static var renderSample: String?

    init() {
        guard let sample = Self.renderSample else { return }
        text = sample
        issues = GrammarChecker.check(sample)
        stats = WritingStats.of(sample)
        tone = ToneReader.read(sample)
        checked = true
        lookup = "good"
        synonyms = GrammarChecker.synonyms(for: "good")
        rewrite = "Please send the invoice to the client by Friday, and let me know if anything is unclear."
    }

    private var ignored = Set<String>()
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "freeflow.polish", qos: .userInitiated)

    /// What the checker must treat as correctly spelled: your dictionary and the team's.
    private var words: [String] { Personalization.load().vocab.terms }

    private func scheduleCheck() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func check() {
        let snapshot = text, words = self.words, ignored = self.ignored, dialect = Settings.shared.spellingVariety
        rewrite = nil
        rewriteError = ""
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues = []; stats = nil; tone = []; checked = false
            return
        }
        queue.async { [weak self] in
            HarperEngine.dialect = dialect
            let found = GrammarChecker.check(snapshot, words: words, ignored: ignored)
            let numbers = WritingStats.of(snapshot)
            let voice = ToneReader.read(snapshot)
            DispatchQueue.main.async {
                guard let self = self, self.text == snapshot else { return }
                self.issues = found
                self.stats = numbers
                self.tone = voice
                self.checked = true
            }
        }
    }

    var visible: [PolishIssue] { filter.map { f in issues.filter { $0.kind == f } } ?? issues }

    func count(_ kind: PolishKind?) -> Int { kind.map { k in issues.filter { $0.kind == k }.count } ?? issues.count }

    func accept(_ issue: PolishIssue, fix: Int) {
        text = PolishText.apply(issue, fix: fix, to: text)
        check()
    }

    func ignore(_ issue: PolishIssue) {
        ignored.insert(issue.original.lowercased())
        check()
    }

    func addWord(_ issue: PolishIssue) {
        Vocabulary.add(issue.original)
        check()
    }

    func fixAll() {
        let result = GrammarChecker.autoFix(text, words: words)
        if result.fixed > 0 { text = result.text; check() }
    }

    var fixableCount: Int { issues.filter { $0.kind.isCorrectness && !$0.fixes.isEmpty }.count }

    func paste() {
        if let s = NSPasteboard.general.string(forType: .string) { text = s; check() }
    }

    func copy() { Inserter.copy(text) }

    func clear() { text = ""; filter = nil; ignored = [] }

    func find(_ word: String) {
        lookup = word
        synonyms = GrammarChecker.synonyms(for: word)
    }

    func runRewrite() {
        let source = text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rewriting else { return }
        rewriting = true
        rewrite = nil
        rewriteError = ""
        Rewriter.shared.rewrite(source, mode: mode, terms: words) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.rewriting = false
                guard self.text == source else { return }
                switch result {
                case .success(let out) where !out.isEmpty: self.rewrite = out
                case .success: self.rewriteError = "The AI returned nothing."
                case .failure(let e): self.rewriteError = e.localizedDescription
                }
            }
        }
    }

    func useRewrite() {
        guard let r = rewrite else { return }
        rewrite = nil
        text = r
        check()
    }
}

// MARK: - The page

struct PolishPage: View {
    @ObservedObject var model: StudioModel
    @StateObject private var polish = PolishModel()

    private func tint(_ k: PolishKind) -> Color {
        switch k {
        case .spelling, .grammar: return RT.high
        case .punctuation: return RT.warn
        case .clarity: return RT.mauve
        case .style: return RT.ok
        }
    }

    var body: some View {
        PageScroll {
            PageTitle(title: "Polish", subtitle: "Spelling, grammar, clearer wording and word swaps, checked on this Mac. Paste or write something and take what helps.")

            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $polish.text)
                        .scrollContentBackground(.hidden)
                        .font(Fonts.sans(15, .medium)).foregroundColor(RT.ink)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(minHeight: 170)
                    if polish.text.isEmpty {
                        Text("Write or paste something here…")
                            .font(Fonts.sans(15, .medium)).foregroundColor(RT.ink3)
                            .padding(.horizontal, 15).padding(.vertical, 16).allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.paper2))
                .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).strokeBorder(RT.line2, lineWidth: 1))

                HStack(spacing: 8) {
                    Button("Paste", action: polish.paste).buttonStyle(GhostButton())
                    Button("Copy", action: polish.copy).buttonStyle(GhostButton()).disabled(polish.text.isEmpty)
                    Button("Clear", action: polish.clear).buttonStyle(GhostButton()).disabled(polish.text.isEmpty)
                    Spacer()
                    if polish.fixableCount > 0 {
                        Button("Fix \(polish.fixableCount) mistake\(polish.fixableCount == 1 ? "" : "s")", action: polish.fixAll)
                            .buttonStyle(PrimaryButton(small: true))
                    }
                }

                if let s = polish.stats {
                    FlowLayout(spacing: 8) {
                        Chip(text: "\(s.words) words")
                        if s.readingSeconds >= 5 { Chip(text: s.readingSeconds >= 60 ? "\(s.readingSeconds / 60) min read" : "\(s.readingSeconds) sec read") }
                        if !s.ease.isEmpty { Chip(text: s.ease) }
                        ForEach(polish.tone, id: \.name) { Chip(text: $0.name, strong: true).help($0.note) }
                    }
                }
            }
            .rtCard(padding: 18)

            if polish.checked {
                issuesSection
            }

            rewriteSection
            wordsSection

            Text("The checker is Harper (Apache-2.0), built into Purrscribe, so what you write never leaves this Mac. Rewrites use the local AI and are refused if they change a number, one of your words or the language.")
                .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
        }
    }

    // MARK: Problems

    @ViewBuilder private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: polish.issues.isEmpty ? "Looks good" : "\(polish.issues.count) suggestion\(polish.issues.count == 1 ? "" : "s")")
                Spacer()
            }
            if !polish.issues.isEmpty {
                FlowLayout(spacing: 8) {
                    FilterChip(title: "All \(polish.count(nil))", on: polish.filter == nil) { polish.filter = nil }
                    ForEach(PolishKind.allCases, id: \.self) { k in
                        if polish.count(k) > 0 {
                            FilterChip(title: "\(k.title) \(polish.count(k))", on: polish.filter == k) { polish.filter = polish.filter == k ? nil : k }
                        }
                    }
                }
                VStack(spacing: 0) {
                    let shown = Array(polish.visible.prefix(60).enumerated())
                    ForEach(shown, id: \.element.id) { i, issue in
                        IssueRow(issue: issue, text: polish.text, tint: tint(issue.kind),
                                 accept: { polish.accept(issue, fix: $0) },
                                 ignore: { polish.ignore(issue) },
                                 addWord: { polish.addWord(issue) })
                        if i < shown.count - 1 { SoftDivider().padding(.horizontal, 16) }
                    }
                }
                .rtCard(padding: 6, radius: 18)
                if polish.visible.count > 60 {
                    Text("Showing the first 60. Fix these and the rest will appear.").font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
                }
            } else {
                Text("No spelling, grammar or wording problems found.").font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink2)
            }
        }
    }

    // MARK: Rewrites

    @ViewBuilder private var rewriteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Rewrite it")
            WrapChipPicker(options: RewriteMode.writing.map { ($0, $0.title) }, selection: $polish.mode)
            Text("For AI builders").font(Fonts.sans(11.5, .bold)).foregroundColor(RT.ink3).padding(.top, 2)
            WrapChipPicker(options: RewriteMode.builders.map { ($0, $0.title) }, selection: $polish.mode)
            Text(polish.mode.instruction).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(polish.rewriting ? "Working…" : "Rewrite", action: polish.runRewrite)
                    .buttonStyle(PrimaryButton(small: true))
                    .disabled(polish.rewriting || polish.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.aiOK)
                if !model.aiOK {
                    Text("Rewrites need the local AI.").font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink3)
                    Button("Set it up") { model.page = .localModel }.buttonStyle(GhostButton())
                }
            }
            if !polish.rewriteError.isEmpty {
                Text(polish.rewriteError).font(Fonts.sans(13, .medium)).foregroundColor(RT.high).fixedSize(horizontal: false, vertical: true)
            }
            if let r = polish.rewrite {
                VStack(alignment: .leading, spacing: 10) {
                    Text(r).font(Fonts.sans(14.5, .medium)).foregroundColor(RT.ink).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Use this", action: polish.useRewrite).buttonStyle(PrimaryButton(small: true))
                        Button("Try again", action: polish.runRewrite).buttonStyle(GhostButton())
                        Button("Copy") { Inserter.copy(r) }.buttonStyle(GhostButton())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.lilac2))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 18)
    }

    // MARK: Other words

    @ViewBuilder private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Find another word")
            HStack(spacing: 10) {
                SoftField(placeholder: "A word you keep using", text: $polish.lookup)
                    .onSubmit { polish.find(polish.lookup) }
                Button("Look up") { polish.find(polish.lookup) }.buttonStyle(GhostButton())
            }
            if !polish.synonyms.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(polish.synonyms, id: \.self) { w in
                        Button { Inserter.copy(w) } label: {
                            Text(w).font(Fonts.sans(13.5, .bold)).foregroundColor(RT.plum)
                                .padding(.horizontal, 14).padding(.vertical, 7).background(Capsule().fill(RT.lilac2))
                        }
                        .buttonStyle(.plain).help("Copy \(w)")
                    }
                }
                Text("Click a word to copy it.").font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
            } else if !polish.lookup.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Press return to look it up.").font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 18)
    }
}

// MARK: - Pieces

private struct Chip: View {
    let text: String
    var strong = false
    var body: some View {
        Text(text).font(Fonts.sans(12.5, strong ? .heavy : .bold))
            .foregroundColor(strong ? RT.plum : RT.ink2)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(strong ? RT.lilac2 : RT.paper2))
    }
}

private struct FilterChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Fonts.sans(12.5, on ? .heavy : .bold))
                .foregroundColor(on ? .white : RT.ink2)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? AnyShapeStyle(RT.primary) : AnyShapeStyle(RT.paper2)))
        }
        .buttonStyle(.plain)
    }
}

private struct IssueRow: View {
    let issue: PolishIssue
    let text: String
    let tint: Color
    let accept: (Int) -> Void
    let ignore: () -> Void
    let addWord: () -> Void

    var body: some View {
        let c = PolishText.context(of: issue, in: text)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(issue.kind.title).font(Fonts.sans(12, .heavy)).foregroundColor(tint)
                Text(issue.message).font(Fonts.sans(13, .semibold)).foregroundColor(RT.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            (Text(c.before).foregroundColor(RT.ink3)
                + Text(c.problem.isEmpty ? "·" : c.problem).foregroundColor(tint).fontWeight(.heavy)
                + Text(c.after).foregroundColor(RT.ink3))
                .font(Fonts.sans(13.5, .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8) {
                ForEach(Array(issue.fixes.prefix(4).enumerated()), id: \.offset) { i, fix in
                    Button { accept(i) } label: {
                        Text(fix.isEmpty ? "Take out" : fix).font(Fonts.sans(13, .heavy))
                            .foregroundColor(i == 0 ? .white : RT.plum)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(i == 0 ? AnyShapeStyle(RT.primary) : AnyShapeStyle(RT.lilac2)))
                    }
                    .buttonStyle(.plain)
                }
                Button("Ignore", action: ignore).buttonStyle(.plain)
                    .font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink3).padding(.horizontal, 6).padding(.vertical, 6)
                if issue.kind == .spelling {
                    Button("Add to my words", action: addWord).buttonStyle(.plain)
                        .font(Fonts.sans(12.5, .bold)).foregroundColor(RT.mauve).padding(.horizontal, 6).padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
