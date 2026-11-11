import SwiftUI
import AppKit

// The free way to run Purrscribe: two small helpers on your own Mac. Speech to text is Whisper, which the installer sets up.
// The rewrite model is optional: a Qwen model that Ollama runs, for tone by app, Edit by voice, Rewrites and meeting summaries.
// This file looks at what the Mac has and walks a new person through the rest (the "Set up the local AI" page, docs/LOCAL-MODEL-GUIDE.md).
// It never downloads, installs or starts anything by itself: every one of those is a button the person presses.

enum LocalModel {
    /// The model Purrscribe is built and tested with, and what the setting starts as.
    static let recommended = "qwen3.5:9b"
    /// What that download weighs (`ollama list` shows 7.6 GB).
    static let recommendedSize = "7.6 GB"
    static let downloadURL = URL(string: "https://ollama.com/download")!
    /// Ollama's normal address. Purrscribe does not look anywhere else.
    static let address = "127.0.0.1:11434"
    private static let tagsURL = URL(string: "http://127.0.0.1:11434/api/tags")!

    /// Where the Mac is on the way to a working rewrite model.
    enum Status: Equatable {
        case checking
        case notInstalled                 // no Ollama on this Mac
        case notRunning                   // Ollama is here but nothing answers at its address
        case missingModel(String)         // Ollama answers, but this model is not downloaded
        case ready(String)                // Ollama answers and has the model

        var isReady: Bool { if case .ready = self { return true } else { return false } }
        /// Ollama answered, with or without the model.
        var isRunning: Bool {
            switch self {
            case .missingModel, .ready: return true
            default: return false
            }
        }
    }

    // MARK: Pure parts (checked in `--test`, no network)

    /// The model names in Ollama's answer to GET /api/tags. Nil when the answer is not an Ollama list, so "nothing answered" and "answered, no models" stay apart.
    static func names(from data: Data) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// The exact name, the name with ":latest", or any tag of that name.
    static func hasModel(_ names: [String], wanted: String) -> Bool {
        names.contains { $0 == wanted || $0 == wanted + ":latest" || $0.hasPrefix(wanted) }
    }

    /// `answered` is what Ollama listed (nil when nothing answered). An answer beats the disk: Ollama in a container still counts.
    static func status(installed: Bool, answered: [String]?, wanted: String) -> Status {
        guard let names = answered else { return installed ? .notRunning : .notInstalled }
        return hasModel(names, wanted: wanted) ? .ready(wanted) : .missingModel(wanted)
    }

    static func summary(_ s: Status) -> String {
        switch s {
        case .checking: return "Looking…"
        case .notInstalled: return "Ollama is not installed"
        case .notRunning: return "Ollama is installed but not running"
        case .missingModel(let m): return "Ollama is running, \(m) is not downloaded yet"
        case .ready(let m): return "Ready · \(m)"
        }
    }

    // MARK: Looking at the Mac

    static let appPaths = ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"]
    static let binaryPaths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]

    static var ollamaApp: URL? {
        appPaths.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var installedOnDisk: Bool {
        ollamaApp != nil || binaryPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String]?
        func set(_ v: [String]?) { lock.lock(); value = v; lock.unlock() }
        func get() -> [String]? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        return URLSession(configuration: c)
    }()

    /// The models Ollama lists, or nil when nothing answers. Waits up to `timeout` seconds, so keep it off the main thread.
    static func installedNames(timeout: TimeInterval = 1.5) -> [String]? {
        var req = URLRequest(url: tagsURL)
        req.timeoutInterval = timeout
        let answer = Answer()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, _, _ in
            if let data = data { answer.set(names(from: data)) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 0.5)
        return answer.get()
    }

    /// One look at the machine, off the main thread. The answer arrives on the main thread, and the rest of the app hears it too,
    /// so the menu and the pages do not disagree for the next 20 seconds.
    static func check(wanted: String, _ done: @escaping (Status, [String]) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let found = installedNames()
            let st = status(installed: installedOnDisk, answered: found, wanted: wanted)
            Rewriter.shared.note(available: st.isReady)
            DispatchQueue.main.async { done(st, found ?? []) }
        }
    }

    // MARK: Buttons the page offers

    static func openOllama() {
        guard let app = ollamaApp else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    static func openTerminal() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                           configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

// MARK: - The page

/// "Set up the local AI": what the Mac has, then the steps in order with the first one that is not done open, and a way to use another model.
struct LocalModelPage: View {
    @ObservedObject var model: StudioModel
    @State private var copied = ""

    // The look at the machine lives on the model (StudioModel.lookForLocalAI), so Home, Help and this page agree.
    private var status: LocalModel.Status { model.aiStatus }
    private var names: [String] { model.aiModels }
    private var checking: Bool { model.aiChecking }

    private static let titles = ["Speech model", "Install Ollama", "Start Ollama", "Download the rewrite model"]
    private static let doneNotes = ["Running", "Installed", "Running", "Downloaded"]

    private var wanted: String { model.settings.aiModel }

    var body: some View {
        PageScroll {
            HStack(alignment: .center, spacing: 14) {
                PageTitle(title: "Set up the local AI",
                          subtitle: "Purrscribe is free when it runs on your own Mac. What you say and write is not uploaded anywhere.")
                Spacer(minLength: 0)
                if Art.image("learning") != nil { ArtView(name: "learning", size: 84) }
            }
            statusCard
            stepsCard
            if status.isRunning && !names.isEmpty { modelCard }
        }
        .onAppear { model.lookForLocalAI() }
        .task {
            // While the page is open it keeps looking, so it turns green by itself once the download finishes in Terminal.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { model.lookForLocalAI() }
            }
        }
    }

    // MARK: What the Mac has

    private var statusCard: some View {
        SettingsCard(title: "What your Mac has") {
            statusRow(ok: model.statusOK, pending: false, title: "Speech to text",
                      detail: model.statusOK ? "Running · \(model.settings.engine.short)" : (model.statusText.isEmpty ? "Not running yet" : model.statusText))
            statusRow(ok: status.isReady, pending: status == .checking, title: "Rewrite model", detail: LocalModel.summary(status))
            HStack(spacing: 12) {
                Button(checking ? "Checking…" : "Check again") { model.lookForLocalAI(manual: true) }
                    .buttonStyle(GhostButton()).disabled(checking)
                Text(status.isReady
                     ? "Tidy-ups, Edit by voice, Rewrites and meeting summaries all run on this Mac."
                     : "Dictation works without it. Tone by app, Edit by voice, Rewrites and meeting summaries need it.")
                    .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(ok: Bool, pending: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: pending ? "circle.dotted" : (ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                .font(.system(size: 17)).foregroundColor(pending ? RT.ink3 : (ok ? RT.ok : RT.warn))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.ink)
                Text(detail).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: The steps

    /// Each step done (true), not done (false) or not known yet (nil, while the first look is still going).
    private var stepsDone: [Bool?] {
        let speech: Bool? = model.statusOK
        if status == .checking { return [speech, nil, nil, nil] }
        let running = status.isRunning
        return [speech, running || status == .notRunning, running, status.isReady]
    }

    private var stepsCard: some View {
        let done = stepsDone
        var current = -1
        for (i, v) in done.enumerated() {
            if v == false { current = i; break }
            if v == nil { break }
        }
        return SettingsCard(title: status.isReady ? "How it was set up" : "Step by step") {
            ForEach(0..<4, id: \.self) { i in step(i, done: done[i], current: i == current) }
        }
    }

    private func step(_ i: Int, done: Bool?, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            badge(i, done: done, current: current)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Self.titles[i]).font(Fonts.sans(14.5, .heavy)).foregroundColor(done == true || current ? RT.ink : RT.ink2)
                    Spacer(minLength: 8)
                    if done == true { Text(Self.doneNotes[i]).font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink3) }
                }
                .frame(minHeight: 26)
                if current { detail(i) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ i: Int, done: Bool?, current: Bool) -> some View {
        ZStack {
            Circle().fill(done == true ? AnyShapeStyle(RT.ok) : (current ? AnyShapeStyle(RT.primary) : AnyShapeStyle(RT.paper2)))
            if done == true {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
            } else {
                Text("\(i + 1)").font(Fonts.sans(12.5, .heavy)).foregroundColor(current ? .white : RT.ink3)
            }
        }
        .frame(width: 26, height: 26)
    }

    @ViewBuilder
    private func detail(_ i: Int) -> some View {
        switch i {
        case 0:
            note("Purrscribe shows Ready at the bottom of the sidebar when speech is working. Right now it says: \(model.statusText.isEmpty ? "nothing yet" : model.statusText).")
            note("Run this from the folder you downloaded. It sets up the speech engine and checks the model file.")
            codeLine("./install.sh")
        case 1:
            note("Ollama is a free app that runs the rewrite model on your Mac.")
            HStack(spacing: 12) {
                Button("Get Ollama") { NSWorkspace.shared.open(LocalModel.downloadURL) }.buttonStyle(PrimaryButton(small: true))
                Text("Opens ollama.com in your browser.").font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink3)
            }
            codeLine("brew install ollama", lead: "Or with Homebrew:")
            note("Open Ollama once after you install it, so it starts.")
        case 2:
            note("Ollama is installed, but nothing answers at its address yet.")
            if LocalModel.ollamaApp != nil {
                Button("Open Ollama") { LocalModel.openOllama() }.buttonStyle(PrimaryButton(small: true))
            }
            codeLine("brew services start ollama", lead: "Installed with Homebrew?")
            note("Purrscribe looks for Ollama at \(LocalModel.address), its normal address.")
        default:
            note(wanted == LocalModel.recommended
                 ? "Ollama is running. One more download: \(wanted), about \(LocalModel.recommendedSize). Paste this in Terminal."
                 : "Ollama is running, but \(wanted) is not downloaded. Paste this in Terminal, or pick a model you already have below.")
            HStack(spacing: 12) {
                codeLine("ollama pull \(wanted)")
                Button("Open Terminal") { LocalModel.openTerminal() }.buttonStyle(GhostButton())
            }
            note("Leave Terminal open until it finishes. This page notices by itself, or press Check again.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
    }

    private func codeLine(_ command: String, lead: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let lead = lead { Text(lead).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2) }
            HStack(spacing: 10) {
                Text(command).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundColor(RT.plum)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RT.paper2))
                Button(copied == command ? "Copied" : "Copy") { copy(command) }.buttonStyle(GhostButton())
            }
        }
    }

    private func copy(_ text: String) {
        Inserter.copy(text)
        copied = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == text { copied = "" } }
    }

    // MARK: Another model

    private var modelCard: some View {
        SettingsCard(title: "Use a different model") {
            note("Purrscribe is built and tested with \(LocalModel.recommended). Any model Ollama has will run, but we have not tested their quality or speed, so go back if the tidy-up gets worse.")
            WrapChipPicker(options: names.map { ($0, $0) },
                           selection: Binding(get: { model.settings.aiModel }, set: { choose($0) }))
            if wanted != LocalModel.recommended {
                Button("Back to \(LocalModel.recommended)") { choose(LocalModel.recommended) }.buttonStyle(GhostButton())
            }
        }
    }

    private func choose(_ name: String) {
        model.settings.aiModel = name
        model.objectWillChange.send()
        model.lookForLocalAI(manual: true)
    }
}

// MARK: - The banner on Home

/// A soft banner on Home for someone who has not got the rewrite model yet. It reads the model's own look at the machine,
/// so it never nags someone who is ready, and says nothing until the first look is done.
struct LocalAIBanner: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        if model.aiStatus != .checking && !model.aiStatus.isReady {
            TipBanner(key: "tip.localai", title: title, text: text, art: "learning", model: model) {
                Button("Set up the local AI") { model.page = .localModel }.buttonStyle(PrimaryButton(small: true))
            }
        }
    }

    private var title: String {
        switch model.aiStatus {
        case .notRunning: return "Start Ollama for rewrites"
        case .missingModel: return "One download left"
        default: return "Turn on free rewrites"
        }
    }

    private var text: String {
        switch model.aiStatus {
        case .notRunning:
            return "Ollama is installed but not running, so Purrscribe is using plain clean-up. Start it and the rewrites switch on."
        case .missingModel(let m):
            return "Ollama is running. Download \(m) and tone by app, Edit by voice, Rewrites and meeting summaries switch on."
        default:
            return "Dictation already works. The local AI adds tone by app, Edit by voice, Rewrites and meeting summaries. It runs on your Mac, so it is free and private."
        }
    }
}
