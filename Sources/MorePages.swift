import SwiftUI
import AppKit

// MARK: - Transforms

/// Saved prompts that rewrite the text you have selected: shorter, friendlier, a LinkedIn post, whatever you need often.
struct TransformsPage: View {
    @ObservedObject var model: StudioModel
    @State private var name = ""
    @State private var prompt = ""
    @State private var editing: String?

    private var file: ModesFile { model.modesFile }

    private func update(_ change: (inout ModesFile) -> Void) {
        var f = ModeStore.load()
        change(&f)
        ModeStore.save(f)
        model.reload()
    }

    var body: some View {
        PageScroll {
            PageTitle(title: "Rewrites", subtitle: "Save a rewrite you use often. Select text in any app, pick it from the Purrscribe menu bar menu, and the selection is replaced.")

            VStack(alignment: .leading, spacing: 12) {
                Text(editing == nil ? "New transform" : "Edit transform").font(Fonts.serif(20)).foregroundColor(RT.plum)
                SoftField(placeholder: "Name  (Make it a LinkedIn post)", text: $name)
                MultiField(placeholder: "What should it do to the selected text?  (Rewrite it as a short, friendly LinkedIn post. No hashtags.)", text: $prompt)
                HStack {
                    Spacer()
                    if editing != nil { Button("Cancel") { reset() }.buttonStyle(GhostButton()) }
                    Button(editing == nil ? "Add transform" : "Save transform", action: save).buttonStyle(PrimaryButton(small: true))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 20)

            if file.transforms.isEmpty {
                EmptyNote(text: "No transforms yet. Add one above and it shows up in the menu bar menu.", art: "modes")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(file.transforms.enumerated()), id: \.element.id) { i, t in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold)).foregroundColor(RT.mauve)
                                .frame(width: 30, height: 30).background(Circle().fill(RT.lilac2))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.name).font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.plum)
                                Text(t.prompt).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2)
                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Edit") { editing = t.id; name = t.name; prompt = t.prompt }.buttonStyle(GhostButton())
                            TrashButton { update { $0.transforms.removeAll { $0.id == t.id } } }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        if i < file.transforms.count - 1 { SoftDivider().padding(.horizontal, 16) }
                    }
                }
                .rtCard(padding: 6, radius: 18)
            }
            Text("They run on this Mac with the local AI, so the text you select never leaves it.")
                .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
        }
    }

    private func reset() { editing = nil; name = ""; prompt = "" }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !p.isEmpty else { return }
        let id = editing
        update { f in
            if let id = id, let i = f.transforms.firstIndex(where: { $0.id == id }) {
                f.transforms[i].name = n; f.transforms[i].prompt = p
            } else {
                f.transforms.append(Transform(id: ModeStore.newId(), name: n, prompt: p))
            }
        }
        reset()
    }
}

// MARK: - Insights

/// What the numbers say about how you use Purrscribe. Time saved is an estimate: typing at 40 words a minute against talking at 150.
enum InsightMath {
    static func timeSavedMinutes(words: Int) -> Int {
        let typing = Double(words) / 40.0
        let talking = Double(words) / 150.0
        return max(0, Int((typing - talking).rounded()))
    }

    static func hoursAndMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

struct InsightsPage: View {
    @ObservedObject var model: StudioModel

    private func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var body: some View {
        let s = model.settings
        let week = model.daily.suffix(7).reduce(0) { $0 + $1.words }
        let active = model.daily.filter { $0.words > 0 }
        let average = active.isEmpty ? 0 : active.reduce(0) { $0 + $1.words } / active.count
        let apps = s.topApps(6)
        let appTotal = max(1, apps.reduce(0) { $0 + $1.1 })
        PageScroll {
            HStack(alignment: .center, spacing: 14) {
                PageTitle(title: "Stats", subtitle: "How you use Purrscribe, worked out from the words on this Mac.")
                Spacer(minLength: 0)
                if Art.image("words") != nil { ArtView(name: "words", size: 84) }
            }

            HStack(spacing: 14) {
                StatCard(icon: "text.alignleft", value: number(week), label: "words this week")
                StatCard(icon: "chart.bar", value: number(average), label: "a day, on the days you talk")
            }
            HStack(spacing: 14) {
                StatCard(icon: "flame", value: "\(model.streak)", label: model.streak == 1 ? "day in a row" : "days in a row")
                StatCard(icon: "clock", value: InsightMath.hoursAndMinutes(InsightMath.timeSavedMinutes(words: s.wordsTotal)), label: "saved, about")
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Last 14 days").font(Fonts.serif(20)).foregroundColor(RT.plum)
                DayBars(days: model.daily)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 22)

            VStack(alignment: .leading, spacing: 14) {
                Text("Where you talk most").font(Fonts.serif(20)).foregroundColor(RT.plum)
                if apps.isEmpty {
                    Text("Dictate in a few apps and they show up here.").font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink2)
                } else {
                    ForEach(apps, id: \.0) { app, words in
                        HStack(spacing: 12) {
                            if let icon = AppInfo.icon(app) {
                                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                            } else {
                                Image(systemName: "app").frame(width: 24, height: 24).foregroundColor(RT.ink3)
                            }
                            Text(AppInfo.name(app)).font(Fonts.sans(14, .bold)).foregroundColor(RT.ink).frame(width: 130, alignment: .leading).lineLimit(1)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(RT.lilac2)
                                    Capsule().fill(RT.soft).frame(width: max(8, g.size.width * CGFloat(words) / CGFloat(appTotal)))
                                }
                            }
                            .frame(height: 8)
                            Text(number(words)).font(Fonts.sans(12.5, .bold)).foregroundColor(RT.ink2).frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 22)

            Text("Time saved assumes typing at 40 words a minute and talking at 150. It is an estimate, not a measurement.")
                .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
        }
    }
}

/// A row of bars, one per day, tallest day full height. The words show when you point at a bar.
struct DayBars: View {
    let days: [(day: Date, words: Int)]

    private var top: Int { max(1, days.map { $0.words }.max() ?? 1) }

    var body: some View {
        let f = DateFormatter()
        f.dateFormat = "d"
        return HStack(alignment: .bottom, spacing: 7) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(RT.paper2).frame(height: 110)
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(RT.soft)
                            .frame(height: d.words == 0 ? 0 : max(6, 110 * CGFloat(d.words) / CGFloat(top)))
                    }
                    Text(f.string(from: d.day)).font(Fonts.sans(10.5, .bold))
                        .foregroundColor(Calendar.current.isDateInToday(d.day) ? RT.plum : RT.ink3)
                }
                .frame(maxWidth: .infinity)
                .help("\(d.words) words")
            }
        }
    }
}

// MARK: - Help

struct HelpPage: View {
    @ObservedObject var model: StudioModel
    @State private var copiedFix = false

    private var s: Settings { model.settings }

    var body: some View {
        PageScroll {
            HStack(alignment: .center, spacing: 14) {
                PageTitle(title: "Help", subtitle: "The short version, and what to try when something does not work.")
                Spacer(minLength: 0)
                if Art.image("hello") != nil { ArtView(name: "hello", size: 84) }
            }

            SettingsCard(title: "Quick start") {
                tip(KeyCap(text: s.talkKey.short), (s.doubleTapToStart ? "Double-tap, say anything, double-tap to finish. Or hold it while you talk." : "Tap, say anything, tap again. Or hold it while you talk."))
                tip(KeyCap(text: s.commandKey.short), "Hold it with text selected and say what to change: \u{201C}make this shorter\u{201D}.")
                tip(Image(systemName: "note.text").foregroundColor(RT.mauve), "Say \u{201C}note to self\u{201D} first and it goes to your Jots.")
                tip(Image(systemName: "record.circle").foregroundColor(RT.mauve), "Start a call and Purrscribe offers to write it down. Notes are in Meetings.")
            }

            SettingsCard(title: "The local AI (free, on your Mac)") {
                let st = model.aiStatus
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: st == .checking ? "circle.dotted" : (st.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                        .font(.system(size: 17)).foregroundColor(st == .checking ? RT.ink3 : (st.isReady ? RT.ok : RT.warn))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(st == .checking ? "Looking…" : (st.isReady ? "Ready" : "Not set up yet")).font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.ink)
                        Text(st.isReady
                             ? "Tidy-ups, Edit by voice, Rewrites and meeting summaries run on this Mac. Nothing is uploaded."
                             : "Dictation works without it. Tone by app, Edit by voice, Rewrites and meeting summaries need it. It is free and runs on your Mac.")
                            .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if st.isReady {
                    Button("Open the local AI page") { model.page = .localModel }.buttonStyle(GhostButton())
                } else {
                    Button("Set up the local AI") { model.page = .localModel }.buttonStyle(PrimaryButton(small: true))
                }
            }

            SettingsCard(title: "If something is off") {
                trouble("Nothing is typed into the app",
                        "Allow Purrscribe under Privacy & Security › Accessibility. Until then your words are copied, so ⌘V pastes them.")
                trouble("It stops hearing me",
                        "The Mac's audio service can get stuck. Quit Purrscribe, run the command below in Terminal, and open Purrscribe again.")
                HStack(spacing: 10) {
                    Text("sudo killall coreaudiod").font(.system(size: 12.5, weight: .semibold, design: .monospaced)).foregroundColor(RT.plum)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(RT.paper2))
                    Button(copiedFix ? "Copied" : "Copy") {
                        Inserter.copy("sudo killall coreaudiod")
                        copiedFix = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedFix = false }
                    }.buttonStyle(GhostButton())
                }
                trouble("The other people on a call are missing",
                        "Allow Purrscribe under Privacy & Security › Screen & System Audio Recording, then start the notes again.")
                HStack(spacing: 10) {
                    Button("Allow screen audio…") { model.bridge.allowScreenAudio() }.buttonStyle(GhostButton())
                    Button("Allow microphone…") { model.bridge.allowMic() }.buttonStyle(GhostButton())
                }
            }

            SettingsCard(title: "Look under the hood") {
                HStack(spacing: 10) {
                    Button("Open the log folder") { NSWorkspace.shared.open(Paths.logs) }.buttonStyle(GhostButton())
                    Button("Open the data folder") { NSWorkspace.shared.open(Paths.support) }.buttonStyle(GhostButton())
                }
                Text("Everything Purrscribe keeps is in that data folder: history, dictionary, snippets, notes. Nothing is sent online.")
                    .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
            }

            Text("Purrscribe \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
        }
        .onAppear { model.lookForLocalAI() }
    }

    private func tip<L: View>(_ lead: L, _ text: String) -> some View {
        HStack(spacing: 12) {
            lead.frame(minWidth: 34)
            Text(text).font(Fonts.sans(14, .medium)).foregroundColor(RT.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func trouble(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Fonts.sans(14.5, .heavy)).foregroundColor(RT.ink)
            Text(text).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
