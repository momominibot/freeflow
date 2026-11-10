import SwiftUI
import UIKit

// MARK: - Moving text between the tabs

/// Which tab is showing, and the text the "Polish" button on a dictation hands over.
@MainActor
final class Router: ObservableObject {
    enum Tab: Hashable { case talk, polish }
    @Published var tab: Tab = .talk
    @Published var draft: String?

    init() {
        // For pictures and tests of the Polish tab: launch with --show-polish to open it on some example text.
        if CommandLine.arguments.contains("--show-polish") {
            tab = .polish
            draft = PhonePolish.example
        } else if CommandLine.arguments.contains("--show-polish-empty") {
            tab = .polish   // the empty tab, with Rhea's picture in the corner of the box
        }
    }

    func polish(_ text: String) {
        draft = text
        tab = .polish
    }
}

// MARK: - The model behind the Polish tab

/// Checks the text you type or paste, a moment after you stop. The grammar checker (Harper) is built into the app and the
/// rewrites use Apple's on-device model, so nothing leaves the iPhone.
@MainActor
final class PhonePolish: ObservableObject {
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
    @Published private(set) var lookedUp = false
    @Published private(set) var checked = false

    /// Your dictionary: words that are never misspellings.
    var words: [String] = []
    /// Adds a word to the dictionary (set by the view, which owns the dictionary).
    var addToDictionary: (String) -> Void = { _ in }

    private var ignored = Set<String>()
    private var checkTask: Task<Void, Never>?
    private var rewriteTask: Task<Void, Never>?

    static let example = "i think we should of sent the the invoice yesterday, it was a unusual delay and their going to recieve it in order to review it."

    private func scheduleCheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    /// Checks at once instead of after the pause.
    func recheck() {
        checkTask?.cancel()
        checkTask = Task { [weak self] in await self?.check() }
    }

    func check() async {
        let snapshot = text, words = self.words, ignored = self.ignored
        rewrite = nil
        rewriteError = ""
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues = []; stats = nil; tone = []; checked = false
            return
        }
        let found = await Task.detached(priority: .userInitiated) {
            (GrammarChecker.check(snapshot, words: words, ignored: ignored), WritingStats.of(snapshot), ToneReader.read(snapshot))
        }.value
        guard !Task.isCancelled, text == snapshot else { return }
        issues = found.0
        stats = found.1
        tone = found.2
        checked = true
    }

    var visible: [PolishIssue] { filter.map { f in issues.filter { $0.kind == f } } ?? issues }

    func count(_ kind: PolishKind?) -> Int { kind.map { k in issues.filter { $0.kind == k }.count } ?? issues.count }

    var fixableCount: Int { issues.filter { $0.kind.isCorrectness && !$0.fixes.isEmpty }.count }

    func accept(_ issue: PolishIssue, fix: Int) {
        text = PolishText.apply(issue, fix: fix, to: text)
        recheck()
    }

    func ignore(_ issue: PolishIssue) {
        ignored.insert(issue.original.lowercased())
        recheck()
    }

    func addWord(_ issue: PolishIssue) {
        addToDictionary(issue.original)
        words.append(issue.original)
        recheck()
    }

    func fixAll() {
        let result = GrammarChecker.autoFix(text, words: words)
        if result.fixed > 0 { text = result.text; recheck() }
    }

    func paste() {
        if let s = UIPasteboard.general.string, !s.isEmpty { text = s; filter = nil; recheck() }
    }

    func clear() {
        rewriteTask?.cancel()
        text = ""; filter = nil; ignored = []; rewriting = false
    }

    func find(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        lookup = clean
        synonyms = clean.isEmpty ? [] : GrammarChecker.synonyms(for: clean)
        lookedUp = !clean.isEmpty
    }

    func runRewrite() {
        let source = text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !rewriting else { return }
        rewriting = true
        rewrite = nil
        rewriteError = ""
        let mode = self.mode, terms = words
        rewriteTask = Task { [weak self] in
            do {
                let out = try await PhoneRewriter.rewrite(source, mode: mode, terms: terms)
                guard let self, self.text == source else { self?.rewriting = false; return }
                self.rewriting = false
                if out.isEmpty { self.rewriteError = "The model returned nothing. Try again." } else { self.rewrite = out }
            } catch {
                guard let self else { return }
                self.rewriting = false
                if self.text == source { self.rewriteError = error.localizedDescription }
            }
        }
    }

    func useRewrite() {
        guard let r = rewrite else { return }
        rewrite = nil
        text = r
        recheck()
    }
}

// MARK: - The tab

struct PolishView: View {
    @EnvironmentObject var d: Dictation
    @EnvironmentObject var router: Router
    @StateObject private var p = PhonePolish()
    @FocusState private var typing: Bool
    @State private var rewriteAvailability = PhoneRewriter.availability

    private func tint(_ k: PolishKind) -> Color {
        switch k {
        case .spelling, .grammar: return RT.live
        case .punctuation: return Color(UIColor(hex: 0xD99A2B))
        case .clarity: return RT.primary
        case .style: return RT.ok
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editor
                    if p.checked { suggestions }
                    rewriteCard.id("rewrite")
                    wordCard.id("words")
                    Text("Spelling and grammar are checked by Harper, which is built into this app. Rewrites use Apple Intelligence on this iPhone. What you write is never sent anywhere.")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(RT.ink3)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
            .task {
                // For pictures of the lower cards: launch with --scroll-to rewrite (or words).
                let args = CommandLine.arguments
                guard let i = args.firstIndex(of: "--scroll-to"), i + 1 < args.count else { return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                proxy.scrollTo(args[i + 1], anchor: .top)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(RT.paper.ignoresSafeArea())
            .navigationTitle("Polish")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }
                }
            }
            }
        }
        .tint(RT.plum)
        .onAppear { sync() }
        .onChange(of: d.dictionaryText) { _ in sync() }
        .onChange(of: d.variety) { _ in p.recheck() }
        .onChange(of: router.draft) { _ in takeDraft() }
    }

    private func sync() {
        p.words = Vocabulary.parse(d.dictionaryText).terms
        p.addToDictionary = { word in
            let current = d.dictionaryText
            d.dictionaryText = current + (current.hasSuffix("\n") || current.isEmpty ? "" : "\n") + word + "\n"
        }
        rewriteAvailability = PhoneRewriter.availability
        takeDraft()
    }

    private func takeDraft() {
        guard let draft = router.draft else { return }
        router.draft = nil
        p.text = draft
        p.filter = nil
        p.recheck()
    }

    // MARK: Writing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $p.text)
                    .focused($typing)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 17)).foregroundColor(RT.ink)
                    .autocorrectionDisabled()
                    .frame(minHeight: 170)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                if p.text.isEmpty {
                    Text("Write or paste something here…")
                        .font(.system(size: 17)).foregroundColor(RT.ink3)
                        .padding(.horizontal, 12).padding(.vertical, 12).allowsHitTesting(false)
                }
                if p.text.isEmpty, let cat = CatArt.image("learning") {
                    Image(uiImage: cat).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 92, height: 92)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(RT.paper2))

            HStack(spacing: 8) {
                Button("Paste") { p.paste() }.buttonStyle(SoftButton())
                if p.text.isEmpty {
                    Button("Try an example") { p.text = PhonePolish.example; p.recheck() }.buttonStyle(SoftButton())
                } else {
                    Button(d.copiedFlash ? "Copied" : "Copy") { d.copy(p.text) }.buttonStyle(SoftButton())
                    Button("Clear") { p.clear() }.buttonStyle(SoftButton())
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            if p.fixableCount > 0 {
                Button("Fix \(p.fixableCount) mistake\(p.fixableCount == 1 ? "" : "s")") { p.fixAll(); typing = false }
                    .buttonStyle(SoftButton(prominent: true))
            }

            if let s = p.stats {
                FlowLayout(spacing: 8) {
                    PolishChip(text: "\(s.words) words")
                    if s.readingSeconds >= 5 { PolishChip(text: s.readingSeconds >= 60 ? "\(s.readingSeconds / 60) min read" : "\(s.readingSeconds) sec read") }
                    if !s.ease.isEmpty { PolishChip(text: s.ease) }
                    ForEach(p.tone, id: \.name) { PolishChip(text: $0.name, strong: true) }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(RT.card))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }

    // MARK: Problems

    @ViewBuilder private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(p.issues.isEmpty ? "Looks good" : "\(p.issues.count) suggestion\(p.issues.count == 1 ? "" : "s")")
                .font(.system(size: 20, weight: .bold)).foregroundColor(RT.ink)
            if p.issues.isEmpty {
                Text("No spelling, grammar or wording problems found.").font(.system(size: 14, weight: .medium)).foregroundColor(RT.ink2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterPill(title: "All \(p.count(nil))", on: p.filter == nil) { p.filter = nil }
                        ForEach(PolishKind.allCases, id: \.self) { k in
                            if p.count(k) > 0 {
                                FilterPill(title: "\(k.title) \(p.count(k))", on: p.filter == k) { p.filter = p.filter == k ? nil : k }
                            }
                        }
                    }
                }
                let shown = Array(p.visible.prefix(40).enumerated())
                VStack(spacing: 10) {
                    ForEach(shown, id: \.element.id) { _, issue in
                        IssueCard(issue: issue, text: p.text, tint: tint(issue.kind),
                                  accept: { p.accept(issue, fix: $0); typing = false },
                                  ignore: { p.ignore(issue) },
                                  addWord: { p.addWord(issue) })
                    }
                }
                if p.visible.count > 40 {
                    Text("Showing the first 40. Fix these and the rest will appear.").font(.system(size: 12, weight: .medium)).foregroundColor(RT.ink3)
                }
            }
        }
    }

    // MARK: Rewrites

    private var rewriteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rewrite it").font(.system(size: 20, weight: .bold)).foregroundColor(RT.ink)
                FlowLayout(spacing: 8) {
                    ForEach(RewriteMode.writing) { m in
                        FilterPill(title: m.title, on: p.mode == m) { p.mode = m }
                    }
                }
                Text("For AI builders").font(.system(size: 12, weight: .bold)).foregroundColor(RT.ink3).padding(.top, 2)
                FlowLayout(spacing: 8) {
                    ForEach(RewriteMode.builders) { m in
                        FilterPill(title: m.title, on: p.mode == m) { p.mode = m }
                    }
                }
                Text(p.mode.instruction).font(.system(size: 13, weight: .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)

                if case .unavailable(let why) = rewriteAvailability {
                    Text(why).font(.system(size: 13.5, weight: .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RT.paper2))
                } else {
                    Button(p.rewriting ? "Working…" : "Rewrite") { typing = false; p.runRewrite() }
                        .buttonStyle(SoftButton(prominent: true))
                        .disabled(p.rewriting || p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !p.rewriteError.isEmpty {
                    Text(p.rewriteError).font(.system(size: 13.5, weight: .medium)).foregroundColor(RT.live).fixedSize(horizontal: false, vertical: true)
                }
                if let r = p.rewrite {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(r).font(.system(size: 16)).foregroundColor(RT.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Use this") { p.useRewrite() }.buttonStyle(SoftButton(prominent: true))
                            Button("Try again") { p.runRewrite() }.buttonStyle(SoftButton())
                            Button("Copy") { d.copy(r) }.buttonStyle(SoftButton())
                        }
                        .lineLimit(1)
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(RT.paper2))
                }
            }
        }
    }

    // MARK: Other words

    private var wordCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Find another word").font(.system(size: 20, weight: .bold)).foregroundColor(RT.ink)
                HStack(spacing: 10) {
                    TextField("A word you keep using", text: $p.lookup)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { p.find(p.lookup) }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RT.paper2))
                    Button("Look up") { p.find(p.lookup); UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .buttonStyle(SoftButton())
                }
                if !p.synonyms.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(p.synonyms, id: \.self) { w in
                            Button { d.copy(w) } label: {
                                Text(w).font(.system(size: 15, weight: .semibold)).foregroundColor(RT.plum)
                                    .padding(.horizontal, 14).padding(.vertical, 8).background(Capsule().fill(RT.paper2))
                            }
                        }
                    }
                    Text("Tap a word to copy it.").font(.system(size: 12, weight: .medium)).foregroundColor(RT.ink3)
                } else if p.lookedUp {
                    Text("No other words found for \"\(p.lookup)\".").font(.system(size: 13, weight: .medium)).foregroundColor(RT.ink3)
                }
            }
        }
    }
}

// MARK: - Pieces

private struct PolishChip: View {
    let text: String
    var strong = false
    var body: some View {
        Text(text).font(.system(size: 13, weight: strong ? .heavy : .bold))
            .foregroundColor(strong ? RT.plum : RT.ink2)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(RT.paper2))
    }
}

private struct FilterPill: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold))
                .foregroundColor(on ? .white : RT.plum)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(Capsule().fill(on ? RT.primary : RT.paper2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct IssueCard: View {
    let issue: PolishIssue
    let text: String
    let tint: Color
    let accept: (Int) -> Void
    let ignore: () -> Void
    let addWord: () -> Void

    private var highlighted: AttributedString {
        let c = PolishText.context(of: issue, in: text)
        var out = AttributedString(c.before)
        var mid = AttributedString(c.problem.isEmpty ? "·" : c.problem)
        mid.foregroundColor = tint
        mid.font = .system(size: 16, weight: .bold)
        mid.underlineStyle = .single
        out += mid
        out += AttributedString(c.after)
        return out
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(issue.kind.title).font(.system(size: 12, weight: .bold)).foregroundColor(tint).textCase(.uppercase)
                }
                Text(highlighted).font(.system(size: 16)).foregroundColor(RT.ink).fixedSize(horizontal: false, vertical: true)
                Text(issue.message).font(.system(size: 14, weight: .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8) {
                    ForEach(Array(issue.fixes.prefix(3).enumerated()), id: \.offset) { i, fix in
                        Button { accept(i) } label: {
                            Text(fix.isEmpty ? "Remove" : fix).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 8).frame(minWidth: 40)
                                .background(Capsule().fill(RT.primary))
                        }
                    }
                    Button("Ignore", action: ignore).buttonStyle(SoftButton())
                    if issue.kind == .spelling {
                        Button("Add to dictionary", action: addWord).buttonStyle(SoftButton())
                    }
                }
            }
        }
    }
}

/// Chips that wrap onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
