import AppKit
import SwiftUI

/// Workday: switch the notes on, see where the time goes, and get ideas FreeFlow can set up for you.
struct WorkdayPage: View {
    @ObservedObject var model: StudioModel
    @State private var cues: [String: String] = [:]
    @State private var notes: [String: String] = [:]
    @State private var forgotten = false
    private let store = LaunchAgentStore()

    private func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min" }

    var body: some View {
        let on = model.bind({ model.settings.workdayOn }, { model.settings.workdayOn = $0 }, then: model.bridge.workdayChanged)
        PageScroll {
            PageTitle(title: "Workday",
                      subtitle: "FreeFlow can keep a private log of which app and window you are in, then point out routines worth automating. It keeps no screenshots and no text from your screen, nothing leaves this Mac, and it forgets after 14 days.")

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: on) {
                    RowLabel(title: "Keep workday notes",
                             note: "Records the app, a cleaned-up window title and the time, about every \(Int(model.settings.workdayInterval)) seconds while you work. Password managers and private browser windows are never recorded.")
                }
                .toggleStyle(RhythmeToggleStyle())
                HStack(spacing: 10) {
                    Circle().fill(model.settings.workdayOn ? RT.ok : RT.ink3).frame(width: 8, height: 8)
                    Text(model.settings.workdayOn ? "On" : "Off").font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink2)
                    Text("· \(model.workdayDays) \(model.workdayDays == 1 ? "day" : "days") of notes").font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink3)
                    Spacer()
                    Button("Hide more windows…") { WorkdayStore.ensureExclusionsFile(); NSWorkspace.shared.open(WorkdayStore.exclusionsFile) }.buttonStyle(GhostButton())
                    Button(forgotten ? "Forgotten" : "Forget everything") {
                        WorkdayStore.forgetAll(); forgotten = true; model.reload()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { forgotten = false }
                    }
                    .buttonStyle(GhostButton(danger: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 22)

            SectionTitle(text: "Today")
            if model.workdayToday.isEmpty {
                EmptyNote(text: model.settings.workdayOn ? "Nothing yet. Work for a few minutes and it shows up here." : "Switch the notes on to see where your day goes.", art: "sleepy")
            } else {
                let top = model.workdayToday.prefix(6)
                let most = max(1, top.first?.minutes ?? 1)
                VStack(spacing: 12) {
                    ForEach(Array(top), id: \.bundle) { a in
                        HStack(spacing: 12) {
                            Text(a.name).font(Fonts.sans(13.5, .bold)).foregroundColor(RT.ink).frame(width: 150, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                Capsule().fill(RT.soft).frame(width: max(8, g.size.width * CGFloat(a.minutes) / CGFloat(most)))
                            }
                            .frame(height: 8)
                            Text(minutes(a.minutes)).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2).frame(width: 74, alignment: .trailing)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .rtCard(padding: 22)
            }

            SectionTitle(text: "Ideas")
            if model.suggestions.isEmpty {
                EmptyNote(text: "Nothing to suggest yet. After a few days of notes, or after you dictate the same thing a few times, ideas for routines, shortcuts and scheduled tasks appear here.", art: "learning")
            } else {
                VStack(spacing: 14) { ForEach(model.suggestions) { row($0) } }
            }
        }
    }

    // MARK: - One idea

    private func row(_ s: Suggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(s.title).font(Fonts.serif(19)).foregroundColor(RT.plum)
            Text(s.why).font(Fonts.sans(13, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
            switch s.kind {
            case .schedule: scheduleControls(s)
            case .hermes: hermesControls(s)
            case .phrase: phraseControls(s)
            }
            if let n = notes[s.id], !n.isEmpty {
                Text(n).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.mauve).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 20)
    }

    @ViewBuilder
    private func scheduleControls(_ s: Suggestion) -> some View {
        if let t = s.task {
            let installed = store.isInstalled(t)
            Text("\(t.when) · cron form: \(t.cron) · it only opens apps").font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
            HStack(spacing: 10) {
                if installed {
                    Button("Run a check") { check(s, t) }.buttonStyle(GhostButton())
                    Button("Remove from my schedule") { store.remove(t); notes[s.id] = "Removed."; model.reload() }.buttonStyle(GhostButton(danger: true))
                } else {
                    Button("Add to my schedule") { add(s, t) }.buttonStyle(PrimaryButton(small: true))
                    Button("Run a check") { preview(s, t) }.buttonStyle(GhostButton())
                }
            }
        }
    }

    @ViewBuilder
    private func hermesControls(_ s: Suggestion) -> some View {
        HStack(spacing: 10) {
            if Hermes.available {
                Button("Send to Hermes") {
                    Hermes.saveBrief(s)
                    switch Hermes.send(s.title, s.text) {
                    case .success(let out): notes[s.id] = "Sent. " + out
                    case .failure(let e): notes[s.id] = "Could not send: \(e.message)"
                    }
                }
                .buttonStyle(PrimaryButton(small: true))
            }
            Button("Copy brief") { Hermes.saveBrief(s); Inserter.copy(s.text); notes[s.id] = "Copied. Paste it to any agent. A copy is in the workday folder." }
                .buttonStyle(GhostButton())
        }
    }

    @ViewBuilder
    private func phraseControls(_ s: Suggestion) -> some View {
        let cue = Binding(get: { cues[s.id] ?? s.cue }, set: { cues[s.id] = $0 })
        SoftField(placeholder: "What you will say", text: cue)
        Button("Make a phrase") { makePhrase(s, cue.wrappedValue) }.buttonStyle(PrimaryButton(small: true))
    }

    // MARK: - Doing it

    private func makePhrase(_ s: Suggestion, _ rawCue: String) {
        let c = rawCue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !c.contains("=>"), c.count <= 60, Snippet(cue: c, expansion: s.text) != nil else {
            notes[s.id] = "That cue is empty, too long or has no words in it."
            return
        }
        if model.snippets.contains(where: { $0.left.caseInsensitiveCompare(c) == .orderedSame }) {
            notes[s.id] = "You already have a phrase with that cue."
            return
        }
        _ = Personalization.load()
        ListFile.append("\(c) => \(s.text.replacingOccurrences(of: "\n", with: "\\n"))", to: Paths.snippets)
        notes[s.id] = "Done. Say \u{201C}\(c)\u{201D} and the text appears."
        model.reload()
    }

    private func add(_ s: Suggestion, _ t: ScheduledTask) {
        do {
            try store.install(t)
            notes[s.id] = "Added. It runs \(t.when.lowercased()) and writes to its log. Use Run a check to see what it would do."
        } catch {
            notes[s.id] = "Could not add it: \((error as? FFError)?.message ?? error.localizedDescription)"
        }
        model.reload()
    }

    /// What the task would do, without installing anything.
    private func preview(_ s: Suggestion, _ t: ScheduledTask) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("freeflow-preview-\(t.id).sh")
        try? t.script(log: "").write(to: tmp, atomically: true, encoding: .utf8)
        notes[s.id] = "Would run \(t.when.lowercased()): " + dryRun(tmp)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func check(_ s: Suggestion, _ t: ScheduledTask) {
        notes[s.id] = "Would run \(t.when.lowercased()): " + dryRun(store.scriptURL(t))
    }

    private func dryRun(_ script: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, "--dry-run"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "could not check (\(error.localizedDescription))" }
        p.waitUntilExit()
        let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .components(separatedBy: .newlines).filter { !$0.isEmpty }.map { $0.replacingOccurrences(of: "would open: ", with: "") }
        return p.terminationStatus == 0 ? "opens " + out.joined(separator: ", ") : "the check failed"
    }
}
