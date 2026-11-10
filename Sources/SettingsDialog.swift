import SwiftUI
import AppKit

/// The tabs of the Settings dialog, in Wispr's order: app settings first, then the account side.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, system, notetaker, mcp, account, team, privacy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .system: return "System"
        case .notetaker: return "Calls"
        case .mcp: return "MCP"
        case .account: return "Account"
        case .team: return "Team"
        case .privacy: return "Data and Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .system: return "laptopcomputer"
        case .notetaker: return "record.circle"
        case .mcp: return "link"
        case .account: return "person.crop.circle"
        case .team: return "person.2"
        case .privacy: return "checkmark.shield"
        }
    }

    static let appTabs: [SettingsTab] = [.general, .system, .notetaker, .mcp]
    static let accountTabs: [SettingsTab] = [.account, .team, .privacy]
}

/// The dialog: a dimmed window behind, a card with its own sidebar, one tab of settings at a time.
struct SettingsDialog: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        let tab = model.settingsTab ?? .general
        ZStack {
            RT.scrim
                .contentShape(Rectangle())
                .onTapGesture { model.settingsTab = nil }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    group("SETTINGS", SettingsTab.appTabs, tab)
                    SoftDivider().padding(.horizontal, 6).padding(.vertical, 12)
                    group("ACCOUNT", SettingsTab.accountTabs, tab)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Text("FreeFlow v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(Fonts.sans(11.5, .semibold)).foregroundColor(RT.ink3)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 4)
                }
                .padding(14)
                .frame(width: 214)
                .background(RT.paper2)

                ZStack(alignment: .topTrailing) {
                    RT.paper
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(tab.title).font(Fonts.serif(30)).foregroundColor(RT.plum)
                            content(for: tab)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 30)
                    }
                    Button { model.settingsTab = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundColor(RT.ink3)
                            .frame(width: 30, height: 30).background(Circle().fill(RT.lilac2.opacity(0.7)))
                    }
                    .buttonStyle(.plain).padding(14).help("Close")
                }
            }
            .frame(maxWidth: 820, maxHeight: 600)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 30, y: 12)
            .padding(28)
        }
        .onExitCommand { model.settingsTab = nil }
    }

    private func group(_ title: String, _ tabs: [SettingsTab], _ current: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Fonts.sans(11, .heavy)).foregroundColor(RT.ink3).tracking(1.2)
                .padding(.horizontal, 12).padding(.bottom, 6)
            ForEach(tabs) { t in
                let on = t == current
                Button { model.settingsTab = t } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                        Text(t.title).font(Fonts.sans(13.5, on ? .heavy : .bold))
                        Spacer()
                    }
                    .foregroundColor(on ? RT.plum : RT.ink2)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(on ? RT.card : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralTab(model: model)
        case .system: SystemTab(model: model)
        case .notetaker: NotetakerTab(model: model)
        case .mcp: MCPTab(model: model)
        case .account: AccountTab(model: model)
        case .team: TeamTab(model: model)
        case .privacy: PrivacyTab(model: model)
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: StudioModel
    private var s: Settings { model.settings }

    var body: some View {
        let talk = model.bind({ s.talkKey }, {
            (k: TalkKey) in
            s.talkKey = k
            if s.commandKey == k { s.commandKey = TalkKey.allCases.first { other in other != k } ?? .rightControl }
        }, then: model.bridge.hotkeysChanged)
        let tap = model.bind({ s.tapToToggle }, { s.tapToToggle = $0 })
        let dbl = model.bind({ s.doubleTapToStart }, { s.doubleTapToStart = $0 })
        let unsentPop = model.bind({ s.unsentPopup }, { s.unsentPopup = $0 })
        let lang = model.bind({ s.language }, { s.language = $0 })
        let clean = model.bind({ s.cleanupLevel }, { s.cleanupLevel = $0 }, then: model.bridge.cleanupChanged)
        let fillers = model.bind({ s.removeFillers }, { s.removeFillers = $0 })
        let variety = model.bind({ s.spellingVariety }, { s.spellingVariety = $0; HarperEngine.dialect = $0 })
        let slips = model.bind({ s.fixGrammarInDictation }, { s.fixGrammarInDictation = $0 })
        let cmdOn = model.bind({ s.commandMode }, { s.commandMode = $0 }, then: model.bridge.commandModeChanged)
        let cmdKey = model.bind({ s.commandKey }, { s.commandKey = $0 }, then: model.bridge.hotkeysChanged)
        let look = model.bind({ s.appearance }, { s.appearance = $0 }, then: { AppearanceChoice.applySaved() })
        let cats = model.bind({ s.catTheme }, { s.catTheme = $0 }, then: { NotificationCenter.default.post(name: .freeflowLookChanged, object: nil) })

        SettingsCard(title: "Shortcuts") {
            SettingRow(title: "Talk key", note: s.talkKey == .fn ? "Tip: if Fn switches your language or opens emoji, set Keyboard settings › Press 🌐 key to › Do Nothing." : s.talkKey == .leftControl ? "Any other key pressed while Control is down cancels, so shortcuts like Ctrl+C are safe. Holding it while you click or drag starts a dictation." : nil) {
                ChipPicker(options: TalkKey.allCases.map { ($0, $0.chipTitle) }, selection: talk)
            }
            Toggle(isOn: tap) { RowLabel(title: "Tap to start, tap again to finish", note: "Holding the key still works like push-to-talk.") }
                .toggleStyle(RhythmeToggleStyle())
            if s.tapToToggle {
                SettingRow(title: "Start and finish hands-free with", note: s.doubleTapToStart ? "Two quick taps start it and two finish it, so one accidental press does nothing. Holding the key for a moment also finishes." : "One quick tap starts it. Another tap finishes.") {
                    ChipPicker(options: [(false, "One tap"), (true, "Double tap")], selection: dbl)
                }
            }
            Toggle(isOn: unsentPop) { RowLabel(title: "Pop-up when words can't be typed", note: "If a dictation does not reach a text box, a card shows the words with a Copy button. They are always in your history too.") }
                .toggleStyle(RhythmeToggleStyle())
            Toggle(isOn: cmdOn) { RowLabel(title: "Edit by voice", note: model.aiOK ? "Select text, hold the command key and say \u{201C}make this shorter\u{201D}." : "Needs Ollama running. Start it and this turns on.") }
                .toggleStyle(RhythmeToggleStyle())
            if s.commandMode {
                SettingRow(title: "Command key", note: nil) {
                    ChipPicker(options: TalkKey.allCases.filter { $0 != s.talkKey }.map { ($0, $0.chipTitle) }, selection: cmdKey)
                }
            }
        }

        SettingsCard(title: "Microphone") {
            PermissionRow(title: "Microphone", ok: model.micOK, action: model.bridge.allowMic)
            Text("FreeFlow listens to the input your Mac is using. Change it in System Settings › Sound › Input.")
                .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
        }

        SettingsCard(title: "Appearance") {
            SettingRow(title: "Look", note: "Cute cats puts Rhea and her cats in the pictures and gives the little face cat ears.") {
                ChipPicker(options: [(true, "Cute cats"), (false, "Pearly bubble")], selection: cats)
            }
            SettingRow(title: "Colours", note: "Dark purple is the Rhythme night room. Match my Mac follows light and dark by itself.") {
                ChipPicker(options: AppearanceChoice.allCases.map { ($0, $0.chipTitle) }, selection: look)
            }
        }

        SettingsCard(title: "My languages") {
            WrapChipPicker(options: Language.allCases.map { ($0, $0.chipTitle) }, selection: lang)
        }

        SettingsCard(title: "Writing") {
            SettingRow(title: "Tidy-up", note: s.cleanupLevel.explain) {
                ChipPicker(options: CleanupLevel.allCases.map { ($0, $0.chipTitle) }, selection: clean)
            }
            Toggle(isOn: fillers) { RowLabel(title: "Remove filler words", note: "Um, uh and friends.") }
                .toggleStyle(RhythmeToggleStyle())
            SettingRow(title: "Spelling", note: "Which spelling the Polish checker expects. British suits Singapore.") {
                ChipPicker(options: [(1, "British"), (0, "American"), (3, "Australian")], selection: variety)
            }
            Toggle(isOn: slips) { RowLabel(title: "Fix clear slips in what I say", note: "A wrong a/an, a lowercase \"I\", a doubled word. Only slips with one clear answer; spelling is left alone.") }
                .toggleStyle(RhythmeToggleStyle())
            SettingRow(title: "Tone by app", note: "Formal in Mail, casual in Slack, exact in code editors. Edit the list in a text file.") {
                Button("Edit styles…") { model.bridge.editStyles() }.buttonStyle(GhostButton())
            }
        }

        SettingsCard(title: "Speech engine") {
            SettingRow(title: "Engine", note: engineNote) {
                ChipPicker(options: SpeechEngine.allCases.map { ($0, $0.short) },
                           selection: Binding(get: { s.engine }, set: { model.bridge.engineChosen($0); model.objectWillChange.send() }))
            }
        }
    }

    private var engineNote: String {
        if model.installing { return "Installing the Qwen engine… about 5 GB, a few minutes." }
        if s.engine == .qwen { return "Qwen3-ASR: more accurate on Chinese and mixed speech. Still being tested." }
        if !WhisperServer.qwenInstalled { return "Picking Qwen downloads it once (about 5 GB). Nothing is uploaded." }
        return "Whisper large-v3-turbo: fast and steady."
    }
}

// MARK: - System

struct SystemTab: View {
    @ObservedObject var model: StudioModel
    private var s: Settings { model.settings }

    var body: some View {
        let sounds = model.bind({ s.sounds }, { s.sounds = $0 })
        let idle = model.bind({ s.showIdleBar }, { s.showIdleBar = $0 }, then: model.bridge.idleBarChanged)
        let dock = model.bind({ s.showInDock }, { s.showInDock = $0 }, then: model.bridge.dockChanged)
        let login = Binding(get: { model.loginOK }, set: { _ in model.bridge.toggleLogin(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.reload() } })

        SettingsCard(title: "App settings") {
            Toggle(isOn: login) { RowLabel(title: "Launch app at login", note: nil) }.toggleStyle(RhythmeToggleStyle())
            Toggle(isOn: dock) { RowLabel(title: "Show FreeFlow in the Dock", note: "FreeFlow lives in the menu bar at the top of the screen (the little face). Turn this on to also keep a Dock icon that opens its window.") }
                .toggleStyle(RhythmeToggleStyle())
            Toggle(isOn: idle) { RowLabel(title: "Show the bar at all times", note: "A tiny sleepy face at the bottom of the screen when FreeFlow is idle.") }
                .toggleStyle(RhythmeToggleStyle())
        }
        SettingsCard(title: "Sound") {
            Toggle(isOn: sounds) { RowLabel(title: "Dictation sounds", note: "A soft sound when you start and stop.") }.toggleStyle(RhythmeToggleStyle())
        }
        SettingsCard(title: "Permissions") {
            PermissionRow(title: "Microphone", ok: model.micOK, action: model.bridge.allowMic)
            PermissionRow(title: "Typing into other apps (Accessibility)", ok: model.axOK, action: model.bridge.allowAccessibility)
            PermissionRow(title: "Hearing the other people on calls (Screen & System Audio)", ok: model.screenOK, action: model.bridge.allowScreenAudio)
        }
    }
}

// MARK: - Notetaker

struct NotetakerTab: View {
    @ObservedObject var model: StudioModel
    private var s: Settings { model.settings }

    var body: some View {
        let mode = model.bind({ s.meetingMode }, { s.meetingMode = $0 })
        let others = model.bind({ s.meetingOthers }, { s.meetingOthers = $0 })
        let secs = model.bind({ s.meetingCountdown }, { s.meetingCountdown = $0 })

        SettingsCard(title: "Meeting detection") {
            SettingRow(title: "When a call starts", note: modeNote) {
                ChipPicker(options: MeetingMode.allCases.map { ($0, $0.chipTitle) }, selection: mode)
            }
            if s.meetingMode == .auto {
                SettingRow(title: "Start meeting notes after", note: "The card stays this long so you can say Not now.") {
                    ChipPicker(options: [(5, "5 sec"), (10, "10 sec"), (20, "20 sec"), (30, "30 sec")], selection: secs)
                }
            }
            if !MicWatch.supported {
                Text("Detecting calls needs macOS 14.2 or later. You can still start notes by hand.")
                    .font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.warn)
            }
            Text("Works with Zoom, Teams, Google Meet in Chrome, Edge or Arc, Slack huddles, FaceTime and Webex.")
                .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3)
        }
        SettingsCard(title: "Who is heard") {
            Toggle(isOn: others) {
                RowLabel(title: "Also write down the other people",
                         note: "Listens to what your Mac plays. Without it, only your side is written, and the others only if your speakers are loud enough.")
            }
            .toggleStyle(RhythmeToggleStyle())
            if s.meetingOthers {
                PermissionRow(title: "Screen & System Audio Recording", ok: model.screenOK, action: model.bridge.allowScreenAudio)
            }
        }
        SettingsCard(title: "Your notes") {
            SettingRow(title: "Folder", note: "Plain Markdown files. Point your notes at an Obsidian vault or any synced folder if you like.") {
                HStack(spacing: 10) {
                    Text(Paths.meetings.path.replacingOccurrences(of: Paths.home.path, with: "~"))
                        .font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2).lineLimit(1).truncationMode(.middle)
                    Button("Open") { model.bridge.openMeetings() }.buttonStyle(GhostButton())
                }
            }
        }
    }

    private var modeNote: String {
        switch s.meetingMode {
        case .off: return "FreeFlow will not look for calls. You can still start notes by hand."
        case .ask: return "A small card appears in the corner when a call starts. Tap Take notes, or ignore it."
        case .auto: return "A card appears for \(s.meetingCountdown) seconds, then notes start by themselves. Tap Not now to skip that call."
        }
    }
}

// MARK: - MCP

struct MCPTab: View {
    @ObservedObject var model: StudioModel
    @State private var picked: String?
    @State private var copiedID: String?

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 170), spacing: 12)]

    var body: some View {
        Text("Let your favourite AI app search what you have said. The FreeFlow MCP runs on this Mac and only reads your dictation history. Pick your app and the right thing is copied for it.")
            .font(Fonts.sans(14, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
        SettingsCard(title: "Works with") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(MCPApps.all) { app in
                    MCPAppTile(app: app, copied: copiedID == app.id, picked: picked == app.id) { copy(app) }
                }
            }
            if let app = picked.flatMap(MCPApps.app) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(app.name): copied. Next:").font(Fonts.sans(13, .bold)).foregroundColor(RT.ink)
                    Text(app.steps).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.lilac2.opacity(0.6)))
            }
        }
        Text("Names and logos belong to their makers and are shown only to say FreeFlow works with them. Apps that are installed here show their own icon.")
            .font(Fonts.sans(11.5, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ app: MCPApp) {
        Inserter.copy(app.text(MCPApps.scriptPath))
        model.settings.mcpCopied = true
        picked = app.id
        copiedID = app.id
        model.objectWillChange.send()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copiedID == app.id { copiedID = nil } }
    }
}

/// One app on the MCP page: its logo, its name, and what a click copies.
struct MCPAppTile: View {
    let app: MCPApp
    let copied: Bool
    let picked: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                MCPLogo(app: app).frame(width: 46, height: 46)
                Text(app.name).font(Fonts.sans(13, .bold)).foregroundColor(RT.ink).lineLimit(1)
                Text(copied ? "Copied" : app.kind.button)
                    .font(Fonts.sans(11, .semibold)).foregroundColor(copied ? RT.ok : RT.ink3)
            }
            .padding(.vertical, 12).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(hover || picked ? RT.lilac2.opacity(0.7) : RT.paper2.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).stroke(picked ? RT.mauve.opacity(0.6) : RT.line2, lineWidth: picked ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(app.kind == .command ? "Copies a command to paste in a terminal" : app.kind == .config ? "Copies a config entry to paste into \(app.name)'s settings" : "Copies the fields to fill in \(app.name)")
    }
}

/// The picture for an app: its bundled brand picture on a white tile, else the installed app's own icon, else letters on a colour.
struct MCPLogo: View {
    let app: MCPApp

    var body: some View {
        if let name = app.glyph, let img = Art.appLogo(name) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white)
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(10)
            }
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 1))
        } else if let url = MCPApps.installedURL(app.appNames) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(hex: app.tint))
                Text(app.letters).font(Fonts.sans(app.letters.count > 2 ? 12 : 17, .heavy)).foregroundColor(.white)
            }
        }
    }
}

// MARK: - Account

struct AccountTab: View {
    @ObservedObject var model: StudioModel
    private var s: Settings { model.settings }

    var body: some View {
        let first = model.bind({ s.firstName }, { s.firstName = $0 })
        let last = model.bind({ s.lastName }, { s.lastName = $0 })
        SettingsCard(title: "About you") {
            SettingRow(title: "First name", note: "Used for the greeting and in the team list.") { SoftField(placeholder: "First name", text: first) }
            SettingRow(title: "Last name", note: nil) { SoftField(placeholder: "Last name", text: last) }
        }
        Text("FreeFlow has no sign-in and no account. Everything you say and write stays on this Mac.")
            .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Team

struct TeamTab: View {
    @ObservedObject var model: StudioModel
    @State private var invited = false
    private var s: Settings { model.settings }

    var body: some View {
        let share = model.bind({ s.shareUsage }, { s.shareUsage = $0 }, then: { TeamFolder.shareUsage() })
        let people = TeamFolder.teamUsage()

        Text("Share one dictionary, one set of snippets and one set of styles with the people you work with. No account and no server: just a folder you all can see.")
            .font(Fonts.sans(14, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)

        SettingsCard(title: "Shared folder") {
            SettingRow(title: "Folder", note: "iCloud Drive, Dropbox, the NAS or a git checkout all work. Everyone picks the same one.") {
                HStack(spacing: 10) {
                    Text(s.teamFolderURL.map { $0.path.replacingOccurrences(of: Paths.home.path, with: "~") } ?? "Not set")
                        .font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2).lineLimit(1).truncationMode(.middle)
                    Button(s.teamFolderURL == nil ? "Choose…" : "Change…") {
                        model.bridge.chooseTeamFolder()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.reload(); model.objectWillChange.send() }
                    }.buttonStyle(GhostButton())
                    if let url = s.teamFolderURL {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(GhostButton())
                        Button("Stop") { model.bridge.clearTeamFolder(); model.objectWillChange.send() }.buttonStyle(GhostButton(danger: true))
                    }
                }
            }
            if s.teamFolderURL != nil {
                Toggle(isOn: share) { RowLabel(title: "Show my word counts to the team", note: "Only today's and total words, and your top apps. Never what you said.") }
                    .toggleStyle(RhythmeToggleStyle())
            }
        }

        if s.teamFolderURL != nil {
            SettingsCard(title: "Share with your team") {
                Text("Copy a short note with the steps, then paste it into a message to your team. Nothing is sent from here.")
                    .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                Button(invited ? "Copied" : "Copy invite") {
                    Inserter.copy(inviteText)
                    invited = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { invited = false }
                }.buttonStyle(PrimaryButton(small: true))
            }
            SettingsCard(title: "Who is using it") {
                if people.isEmpty {
                    Text("Nobody has shared their counts yet. Turn the switch above on, and ask a teammate to do the same.")
                        .font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink2)
                } else {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, p in
                        HStack {
                            Text(p.0).font(Fonts.sans(14.5, .bold)).foregroundColor(RT.ink)
                            Spacer()
                            Text("\(p.1) today").font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2)
                            Text("\(p.2) in all").font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink3).frame(width: 90, alignment: .trailing)
                        }
                    }
                }
            }
        } else {
            EmptyNote(text: "Pick a shared folder to start. FreeFlow adds three small text files there that everyone can edit.", art: "snippets")
        }
    }

    private var inviteText: String {
        let folder = s.teamFolderURL.map { $0.path.replacingOccurrences(of: Paths.home.path, with: "~") } ?? "our shared folder"
        return """
        Join our FreeFlow team dictionary:
        1. Install FreeFlow on your Mac.
        2. Open FreeFlow, go to Settings › Team, and choose this folder: \(folder)
        3. Our shared words, snippets and styles now apply to your dictation too.
        Everything stays in the folder. There is no account and no server.
        """
    }
}

// MARK: - Data and Privacy

struct PrivacyTab: View {
    @ObservedObject var model: StudioModel
    private var s: Settings { model.settings }

    var body: some View {
        let keep = model.bind({ s.keepTakes }, { s.keepTakes = $0 })
        let learn = model.bind({ s.learnFromFixes }, { s.learnFromFixes = $0 })
        let takesLimit = model.bind({ s.takesLimit }, { s.takesLimit = $0 })
        let takesDays = model.bind({ s.takesDays }, { s.takesDays = $0 })
        let typingLearn = model.bind({ s.learnFromTyping }, { s.learnFromTyping = $0 }, then: model.bridge.typingChanged)
        let typingOnce = model.bind({ s.learnTypingAtOnce }, { s.learnTypingAtOnce = $0 }, then: model.bridge.typingChanged)

        Text("Nothing you say is sent online. Speech is turned into words on this Mac, and so is the tidy-up.")
            .font(Fonts.sans(14, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)

        SettingsCard(title: "What FreeFlow keeps") {
            Toggle(isOn: keep) { RowLabel(title: "Keep my recordings on this Mac", note: "Lets you compare speech engines on your own voice. Off by default; the audio is otherwise deleted right after it is written down.") }
                .toggleStyle(RhythmeToggleStyle())
            if s.keepTakes {
                SettingRow(title: "How many to keep", note: "The newest ones. Older ones are deleted as new ones come in.") {
                    ChipPicker(options: Settings.takesLimitChoices.map { ($0, "\($0)") }, selection: takesLimit)
                }
                SettingRow(title: "How long to keep them", note: "Recordings older than this are deleted, whatever the count.") {
                    ChipPicker(options: Settings.takesDaysChoices.map { ($0, $0 == 0 ? "Forever" : "\($0) days") }, selection: takesDays)
                }
                SettingRow(title: "Where they are saved", note: s.takesFolderPath.isEmpty ? "FreeFlow's own folder (Application Support › FreeFlow › takes)." : s.takesFolderPath) {
                    HStack(spacing: 8) {
                        Button("Choose folder…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                            panel.prompt = "Save recordings here"
                            if panel.runModal() == .OK, let url = panel.url { model.objectWillChange.send(); s.takesFolderPath = url.path }
                        }.buttonStyle(GhostButton())
                        if !s.takesFolderPath.isEmpty {
                            Button("Use the default") { model.objectWillChange.send(); s.takesFolderPath = "" }.buttonStyle(GhostButton())
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button("Show recordings") { model.bridge.showTakes() }.buttonStyle(GhostButton())
                    Button("Delete recordings") { model.bridge.deleteTakes() }.buttonStyle(GhostButton(danger: true))
                }
            }
            Toggle(isOn: learn) { RowLabel(title: "Learn from my corrections", note: "After FreeFlow types, it reads that one text box for a few minutes (never password fields) to see which words you fixed. Only the word pairs are kept.") }
                .toggleStyle(RhythmeToggleStyle())
            Toggle(isOn: typingLearn) { RowLabel(title: "Learn from my own typing", note: "When you backspace a wrongly typed name and write it again, it remembers the spelling. No keystrokes are recorded, nothing in password fields, password managers or terminals. Off by default.") }
                .toggleStyle(RhythmeToggleStyle())
            if s.learnFromTyping {
                Toggle(isOn: typingOnce) { RowLabel(title: "Keep a clear fix the first time", note: "Only when it is plainly a spelling fix (a few letters off, not a half-deleted word), and after it has stood for 20 seconds, so a word you change again is not kept. Off, every fix must be seen twice.") }
                    .toggleStyle(RhythmeToggleStyle())
            }
            SettingRow(title: "See what it learned", note: "And whether you need fewer fixes over time.") {
                Button("Open Learning") { model.settingsTab = nil; model.page = .learning }.buttonStyle(GhostButton())
            }
        }

        SettingsCard(title: "Your data") {
            SettingRow(title: "Everything is in one folder", note: "History, dictionary, snippets, notes, learned words. Plain text you can read, move or delete.") {
                Button("Open the data folder") { NSWorkspace.shared.open(Paths.support) }.buttonStyle(GhostButton())
            }
            SettingRow(title: "Dictation history", note: "Removes every saved dictation and resets the word counts. Your dictionary, snippets and notes stay.") {
                Button("Delete history…") { deleteHistory() }.buttonStyle(GhostButton(danger: true))
            }
        }
    }

    private func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete your dictation history?"
        alert.informativeText = "Every saved dictation and the word counts are removed from this Mac. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete history")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: Paths.historyJSON)
        try? FileManager.default.removeItem(at: Paths.history)
        s.resetUsage()
        model.reload()
    }
}
