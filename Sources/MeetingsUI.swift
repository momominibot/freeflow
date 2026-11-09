import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The card that appears when a call starts

final class PromptModel: ObservableObject {
    @Published var app = ""
    @Published var remaining = 0.0
    @Published var total = 0.0
    @Published var paused = false
}

struct MeetingPromptView: View {
    @ObservedObject var m: PromptModel
    let start: () -> Void
    let decline: () -> Void

    private var detail: String {
        if m.total > 0 {
            return m.paused ? "Paused while you point at this card." : "Taking notes in \(max(1, Int(ceil(m.remaining)))) seconds."
        }
        return "Take notes of this call?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Emblem(size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(m.app) call detected").font(Fonts.serif(18)).foregroundColor(RT.plum)
                    Text(detail).font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2)
                }
                Spacer(minLength: 0)
            }
            if m.total > 0 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(RT.lilac2)
                        Capsule().fill(RT.primary).frame(width: g.size.width * CGFloat(max(0, min(1, 1 - m.remaining / m.total))))
                    }
                }
                .frame(height: 5)
            }
            HStack(spacing: 10) {
                Button(m.total > 0 ? "Start now" : "Take notes", action: start).buttonStyle(PrimaryButton(small: true))
                Button("Not now", action: decline).buttonStyle(GhostButton())
                Spacer(minLength: 0)
            }
            Text("Audio stays on this Mac and is deleted once it is written down. Tell the others you are taking notes.")
                .font(Fonts.sans(11.5, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: RT.radius, style: .continuous).fill(RT.card))
        .shadow(color: RT.lift2, radius: 18, y: 8)
        .padding(26)
        .onHover { m.paused = $0 }
    }
}

final class PromptPanel: NSPanel {
    // Clickable, yet it never makes FreeFlow the active app, so the call keeps your keyboard.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class MeetingPrompt {
    private let panel: PromptPanel
    private let model = PromptModel()
    private var timer: Timer?
    private var onStart: () -> Void = {}
    private var onDecline: () -> Void = {}
    private var shownFor = 0.0

    init() {
        panel = PromptPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: MeetingPromptView(m: model,
                                                             start: { [weak self] in self?.tappedStart() },
                                                             decline: { [weak self] in self?.tappedDecline() }))
        panel.contentView = host
    }

    func show(app: String, countdown: Int, onStart: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.onStart = onStart
        self.onDecline = onDecline
        model.app = app
        model.total = Double(countdown)
        model.remaining = Double(countdown)
        model.paused = false
        shownFor = 0
        if let host = panel.contentView as? NSHostingView<MeetingPromptView> {
            let size = host.fittingSize
            panel.setContentSize(size)
        }
        place()
        panel.orderFrontRegardless()
        timer?.invalidate()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func step() {
        shownFor += 0.25
        if model.total > 0 {
            if !model.paused { model.remaining -= 0.25 }
            if model.remaining <= 0 { tappedStart() }
        } else if shownFor > 90 {
            hide()   // left alone: the card goes away, and the call is not turned down
        }
    }

    private func tappedStart() {
        let f = onStart
        timer?.invalidate()
        f()
    }

    private func tappedDecline() {
        let f = onDecline
        timer?.invalidate()
        f()
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width + 8, y: vf.maxY - size.height + 8))
    }
}

// MARK: - The Meetings page

struct MeetingsPage: View {
    @ObservedObject var model: StudioModel

    private func duration(_ s: Int) -> String {
        s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60) min" : "\(max(1, s / 60)) min"
    }

    var body: some View {
        PageScroll {
            PageTitle(title: "Meetings",
                      subtitle: "FreeFlow writes down your calls and your audio files. It listens on this Mac, keeps the words, and deletes the audio as soon as it is written. Tell the others you are taking notes.")
            nowCard
            FileCard(model: model)
            // The call settings live in Settings > Notetaker. Here is only what they are now, and a way to them.
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("When a call starts").font(Fonts.serif(20)).foregroundColor(RT.plum)
                        Text(modeNote).font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2).fixedSize(horizontal: false, vertical: true)
                        Text(model.settings.meetingOthers ? "The other people are written down too." : "Only your side is written down.")
                            .font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2)
                    }
                    Spacer(minLength: 8)
                    Button("Call settings") { model.openSettings(.notetaker) }.buttonStyle(GhostButton())
                }
                if model.settings.meetingOthers && !model.screenOK {
                    PermissionRow(title: "Screen & System Audio Recording", ok: false, action: model.bridge.allowScreenAudio)
                }
                if !MicWatch.supported {
                    Text("Detecting calls needs macOS 14.2 or later. You can still start notes by hand.")
                        .font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.warn)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rtCard(padding: 22)

            HStack {
                SectionTitle(text: "Your notes")
                Spacer()
                Button("Open folder") { model.bridge.openMeetings() }.buttonStyle(GhostButton())
            }
            if model.notes.isEmpty {
                EmptyNote(text: "No notes yet. They appear here after your first call or file.", art: "meetings")
            } else {
                VStack(spacing: 14) {
                    ForEach(model.notes) { n in NoteCard(note: n, model: model) }
                }
            }
        }
    }

    private var modeNote: String {
        switch model.settings.meetingMode {
        case .off: return "FreeFlow will not look for calls. You can still start notes by hand."
        case .ask: return "A small card appears in the corner when a call starts. Tap Take notes, or ignore it."
        case .auto: return "A card appears for \(model.settings.meetingCountdown) seconds, then notes start by themselves. Tap Not now to skip that call, or point at the card to pause the countdown."
        }
    }

    @ViewBuilder
    private var nowCard: some View {
        HStack(spacing: 14) {
            if let now = model.meetingNow {
                PulseDot()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Taking notes · \(now.app)").font(Fonts.sans(15, .heavy)).foregroundColor(RT.ink)
                    Text(MeetingFile.stamp(now.seconds)).font(Fonts.sans(13, .semibold)).foregroundColor(RT.ink2)
                }
                Spacer()
                Button("Stop and save") { model.bridge.stopMeeting(); model.reload() }.buttonStyle(PrimaryButton(small: true))
            } else {
                ArtView(name: "sleepy", size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Not taking notes").font(Fonts.sans(15, .heavy)).foregroundColor(RT.ink)
                    Text("Start one yourself for a call, or a talk in the room.").font(Fonts.sans(12.5, .medium)).foregroundColor(RT.ink2)
                }
                Spacer()
                Button("Take notes now") { model.bridge.startMeeting(); model.reload() }.buttonStyle(PrimaryButton(small: true))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 20)
    }
}

struct FileCard: View {
    @ObservedObject var model: StudioModel
    @State private var over = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Write down a file").font(Fonts.serif(20)).foregroundColor(RT.plum)
                Spacer()
                Button("Choose file…", action: pick).buttonStyle(GhostButton()).disabled(model.fileJob != nil)
            }
            ZStack {
                RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous)
                    .fill(over ? RT.lilac2 : RT.paper2)
                RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous)
                    .strokeBorder(over ? RT.mauve : RT.lilac, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                if let job = model.fileJob {
                    VStack(spacing: 10) {
                        Text("Writing down \(job.name)").font(Fonts.sans(13.5, .bold)).foregroundColor(RT.ink).lineLimit(1)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(RT.card)
                                Capsule().fill(RT.primary).frame(width: max(8, g.size.width * CGFloat(job.progress)))
                            }
                        }
                        .frame(height: 6)
                        .padding(.horizontal, 40)
                    }
                } else {
                    HStack(spacing: 12) {
                        ArtView(name: "files", size: 64)
                        Text("Drop an audio or video file here").font(Fonts.sans(14, .semibold)).foregroundColor(RT.ink2)
                    }
                }
            }
            .frame(height: 92)
            .onDrop(of: [UTType.fileURL], isTargeted: $over) { providers in
                guard model.fileJob == nil, let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    DispatchQueue.main.async { model.bridge.transcribeFile(url) }
                }
                return true
            }
            if FileTranscriber.ffmpegPath == nil {
                Text("Files need ffmpeg. In a terminal: brew install ffmpeg").font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.warn)
            }
            Text("Voice memos, recordings, interviews, video. One minute at a time, on this Mac. The result is saved below like a meeting.")
                .font(Fonts.sans(12, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 22)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Write down"
        if panel.runModal() == .OK, let url = panel.url { model.bridge.transcribeFile(url) }
    }
}

/// The AI's notes for a meeting: headings, bullets and a small first line saying who wrote them.
struct SummaryView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Color.clear.frame(height: 2)
                } else if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3))).font(Fonts.sans(13.5, .heavy)).foregroundColor(RT.plum).padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(Fonts.sans(13.5, .bold)).foregroundColor(RT.mauve)
                        Text(String(line.dropFirst(2))).font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if line.hasPrefix("Written by the local AI") {
                    Text(line).font(Fonts.sans(11.5, .medium)).foregroundColor(RT.ink3).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(line).font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct NoteCard: View {
    let note: MeetingNote
    @ObservedObject var model: StudioModel
    @State private var copied = false

    private var title: String {
        if note.kind == "file" { return "Recording · \(note.app)" }
        return note.app == "Meeting" ? "Meeting" : "\(note.app) call"
    }

    private var when: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, h:mm a"
        return f.string(from: note.start)
    }

    private var facts: String {
        let mins = note.seconds >= 3600 ? "\(note.seconds / 3600) h \((note.seconds % 3600) / 60) min" : "\(max(1, note.seconds / 60)) min"
        let words = NumberFormatter.localizedString(from: NSNumber(value: note.words), number: .decimal)
        let who = note.kind == "file" ? "Audio file" : (note.bothSides ? "You and the others" : "Your side only")
        return "\(mins) · \(words) words · \(who)"
    }

    var body: some View {
        let busy = model.summarizing.contains(note.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title).font(Fonts.serif(19)).foregroundColor(RT.plum).lineLimit(1)
                if note.recording {
                    Text("Writing").font(Fonts.sans(10.5, .heavy)).foregroundColor(RT.plum)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(RT.blush2))
                }
                Spacer()
            }
            Text("\(when) · \(facts)").font(Fonts.sans(12.5, .semibold)).foregroundColor(RT.ink2)
            if let s = note.summary {
                SummaryView(text: s)
            } else if !note.preview.isEmpty {
                Text(note.preview).font(Fonts.sans(13.5, .medium)).foregroundColor(RT.ink)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if note.summary == nil, !note.recording {
                    Button(busy ? "Writing the summary…" : "Summarise") { model.bridge.summarizeNote(note.url) }
                        .buttonStyle(PrimaryButton(small: true)).disabled(busy)
                }
                Button(copied ? "Copied" : "Copy") { copy() }.buttonStyle(GhostButton())
                Button("Open") { NSWorkspace.shared.open(note.url) }.buttonStyle(GhostButton())
                Spacer()
                TrashButton { remove() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rtCard(padding: 20)
    }

    private func copy() {
        let text = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
        var body = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        body = body.replacingOccurrences(of: MeetingFile.summaryStart + "\n", with: "").replacingOccurrences(of: MeetingFile.summaryEnd + "\n", with: "")
        Inserter.copy(body.trimmingCharacters(in: .whitespacesAndNewlines))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }

    private func remove() {
        let alert = NSAlert()
        alert.messageText = "Delete these notes?"
        alert.informativeText = "The file is moved to the Trash."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        model.reload()
    }
}
