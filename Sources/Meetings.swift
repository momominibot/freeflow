import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit
import Darwin

// Meeting notes: FreeFlow notices a call, offers to take notes (or starts by itself after a short countdown),
// writes down what you and the other people say, and stops when the call ends.
// Same shape as Wispr Flow's Notetaker, but everything stays on this Mac and the audio is deleted as soon as it is written down.

enum MeetingMode: String, CaseIterable {
    case off, ask, auto

    var chipTitle: String {
        switch self {
        case .off: return "Off"
        case .ask: return "Ask me"
        case .auto: return "Start by itself"
        }
    }
}

// MARK: - Which calls count

/// Pure rules for deciding that an app using the microphone is a call.
enum MeetingRules {
    /// Desktop apps that are calls whenever they hold the microphone.
    static let native: [(prefixes: [String], name: String)] = [
        (["us.zoom.xos"], "Zoom"),
        (["com.microsoft.teams2", "com.microsoft.teams"], "Microsoft Teams"),
        (["com.tinyspeck.slackmacgap"], "Slack huddle"),
        (["com.apple.FaceTime"], "FaceTime"),
        (["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark", "com.webex.meetingmanager"], "Webex"),
    ]

    /// Browsers hold the microphone for many things, so the window title has to look like a call too.
    static let browsers = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.vivaldi.Vivaldi", "org.mozilla.firefox", "com.operasoftware.Opera",
    ]

    static let tabHints: [(pattern: String, name: String)] = [
        ("(?i)(^|\\W)meet\\s[-–—]|google meet|meet\\.google\\.com|\\b[a-z]{3}-[a-z]{4}-[a-z]{3}\\b", "Google Meet"),
        ("(?i)microsoft teams|\\|\\s*teams\\b", "Microsoft Teams"),
        ("(?i)\\bzoom\\b", "Zoom"),
        ("(?i)\\bwebex\\b", "Webex"),
        ("(?i)\\bwhereby\\b", "Whereby"),
        ("(?i)\\bjitsi\\b", "Jitsi"),
        ("(?i)slack.*huddle|huddle.*slack", "Slack huddle"),
    ]

    static func isBrowser(_ bundleId: String) -> Bool {
        browsers.contains { bundleId.hasPrefix($0) }
    }

    /// The name of the call if this app, with these window titles, is in one.
    static func classify(bundleId: String, titles: [String]) -> String? {
        for entry in native where entry.prefixes.contains(where: { bundleId.hasPrefix($0) }) { return entry.name }
        guard isBrowser(bundleId) else { return nil }
        for t in titles {
            for h in tabHints where t.range(of: h.pattern, options: .regularExpression) != nil { return h.name }
        }
        return nil
    }
}

// MARK: - Who is using the microphone

enum MicWatch {
    struct Client {
        let pid: pid_t
        let bundleId: String
    }

    /// macOS 14.2 and later can say which apps are capturing audio. Before that, meeting detection is off.
    static var supported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Every process that is recording from a microphone right now.
    static func clients() -> [Client] {
        guard #available(macOS 14.2, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddr, 0, nil, &size, &ids) == noErr else { return [] }
        var out: [Client] = []
        for id in ids {
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &runAddr, 0, nil, &runSize, &running) == noErr, running != 0 else { continue }
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }
            var bidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bid: Unmanaged<CFString>?
            var bidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundle = ""
            if AudioObjectGetPropertyData(id, &bidAddr, 0, nil, &bidSize, &bid) == noErr, let s = bid?.takeRetainedValue() {
                bundle = s as String
            }
            out.append(Client(pid: pid, bundleId: bundle))
        }
        return out
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let p = pid_t(info.pbi_ppid)
        return p > 1 ? p : nil
    }

    /// The app a helper process belongs to: Chrome records through a helper, Zoom through itself.
    static func owner(of c: Client) -> (bundleId: String, pid: pid_t) {
        var pid = c.pid
        for _ in 0..<5 {
            if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier { return (id, pid) }
            guard let p = parent(of: pid) else { break }
            pid = p
        }
        return (c.bundleId, c.pid)
    }

    /// Window titles of an app, through Accessibility. A browser shows only the tab in front in each window.
    static func windowTitles(of pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        var titles: [String] = []
        for w in windows {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, let s = t as? String {
                titles.append(s)
            }
        }
        return titles
    }

    /// The call that is going on right now, if any, other than FreeFlow's own microphone use.
    static func currentCall() -> (name: String, bundleId: String)? {
        let me = Bundle.main.bundleIdentifier
        for c in clients() where c.pid != getpid() {
            let o = owner(of: c)
            if o.bundleId == me { continue }
            let titles = MeetingRules.isBrowser(o.bundleId) ? windowTitles(of: o.pid) : []
            if let name = MeetingRules.classify(bundleId: o.bundleId, titles: titles) { return (name, o.bundleId) }
        }
        return nil
    }

    static func micInUse(by bundleId: String) -> Bool {
        clients().contains { owner(of: $0).bundleId == bundleId }
    }
}

// MARK: - When to offer, when to stop (pure, so it can be tested)

struct MeetingBrain {
    enum Phase { case idle, offering, recording }
    enum Action { case offer, cancelOffer, stop }

    var phase = Phase.idle
    var hitTicks = 0
    var missTicks = 0
    /// You said no to this call. Nothing more is offered until the call is over.
    var declined = false
    var recordingAuto = false

    /// Two quiet seconds-of-three in a row before offering; about a minute without the microphone before stopping.
    static let ticksToOffer = 2
    static let ticksToCancelOffer = 3
    static let ticksToStop = 20

    mutating func tick(inCall: Bool, mode: MeetingMode) -> Action? {
        switch phase {
        case .idle:
            guard inCall else {
                hitTicks = 0
                declined = false
                return nil
            }
            guard mode != .off, !declined else { return nil }
            hitTicks += 1
            if hitTicks >= Self.ticksToOffer {
                phase = .offering
                missTicks = 0
                return .offer
            }
            return nil
        case .offering:
            if inCall { missTicks = 0; return nil }
            missTicks += 1
            if missTicks >= Self.ticksToCancelOffer {
                phase = .idle
                hitTicks = 0
                return .cancelOffer
            }
            return nil
        case .recording:
            // A note you started yourself, outside any call, only ends when you end it.
            if inCall || !recordingAuto { missTicks = 0; return nil }
            missTicks += 1
            return missTicks >= Self.ticksToStop ? .stop : nil
        }
    }

    mutating func declinedByUser() {
        phase = .idle
        declined = true
        hitTicks = 0
    }

    mutating func started(auto: Bool) {
        phase = .recording
        recordingAuto = auto
        missTicks = 0
        hitTicks = 0
    }

    mutating func stopped(stillInCall: Bool) {
        phase = .idle
        hitTicks = 0
        missTicks = 0
        declined = stillInCall
    }
}

// MARK: - Cutting audio into pieces

/// Writes 16 kHz mono WAV pieces of a fixed length from whatever audio is pushed in, without dropping any between pieces.
final class ChunkWriter {
    struct Chunk {
        let url: URL
        let index: Int
        let seconds: Double
        let peakDb: Float
        let rmsDb: Float
        let side: String
        /// Seconds from the start of the meeting to the start of this piece.
        let start: Double
    }

    let side: String
    var chunkSeconds: Double
    /// A piece is closed at the first pause after `chunkSeconds`, so a sentence is not cut in half; this is the longest it may run on.
    static let maxExtraSeconds = 6.0
    /// A pause: this long without anything above the quiet level.
    static let pauseFrames = 6400
    static let quietRmsDb: Float = -45
    var onChunk: ((Chunk) -> Void)?
    private let dir: URL
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var frames = 0
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var index = 0
    private var framesBefore = 0
    private var quietRun = 0
    /// The last two seconds heard, kept to start the next piece with when a piece had to be cut in the middle of speech.
    private var tail: [Float] = []
    private var carry: [Float] = []
    private var carryFrames = 0
    static let overlapFrames = 32000
    private var converter: AVAudioConverter?
    private var converterKey = ""
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    init(side: String, dir: URL, chunkSeconds: Double) {
        self.side = side
        self.dir = dir
        self.chunkSeconds = chunkSeconds
        queue = DispatchQueue(label: "freeflow.chunks.\(side)")
    }

    /// Safe to call from an audio thread: the buffer is copied before this returns.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else { return }
        queue.async { self.write(copy) }
    }

    /// Closes the piece in progress (if it holds at least a second) and waits until it is written.
    func finish() {
        queue.sync {
            if frames - carryFrames >= 16000 { rotate() } else { discard() }
        }
    }

    private static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            memcpy(d, s, Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return c
    }

    private func write(_ input: AVAudioPCMBuffer) {
        let key = "\(input.format.sampleRate)-\(input.format.channelCount)-\(input.format.commonFormat.rawValue)-\(input.format.isInterleaved)"
        if converter == nil || converterKey != key {
            converter = AVAudioConverter(from: input.format, to: target)
            converterKey = key
        }
        guard let conv = converter else { return }
        let ratio = 16000 / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        var sum: Float = 0
        for i in 0..<Int(out.frameLength) {
            peak = max(peak, abs(ch[i]))
            sum += ch[i] * ch[i]
            sumSquares += Double(ch[i] * ch[i])
        }
        let rms = sum > 0 ? 10 * log10(sum / Float(out.frameLength)) : -160
        quietRun = rms < Self.quietRmsDb ? quietRun + Int(out.frameLength) : 0
        if file == nil { openNext() }
        try? file?.write(from: out)
        frames += Int(out.frameLength)
        tail.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        if tail.count > Self.overlapFrames { tail.removeFirst(tail.count - Self.overlapFrames) }
        let fresh = frames - carryFrames
        let due = Double(fresh) >= chunkSeconds * 16000
        if due {
            let forced = quietRun < Self.pauseFrames
            if !forced || Double(fresh) >= (chunkSeconds + Self.maxExtraSeconds) * 16000 { rotate(overlap: forced) }
        }
    }

    private func openNext() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(format: "%@-%05d.wav", side, index))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        file = try? AVAudioFile(forWriting: url, settings: settings)
        fileURL = url
        carryFrames = 0
        if !carry.isEmpty, let f = file,
           let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(carry.count)), let dst = buf.floatChannelData?[0] {
            for (i, v) in carry.enumerated() { dst[i] = v }
            buf.frameLength = AVAudioFrameCount(carry.count)
            try? f.write(from: buf)
            carryFrames = carry.count
            frames = carry.count
        }
        carry = []
    }

    private func rotate(overlap: Bool = false) {
        let url = fileURL
        file = nil   // closing the file is what writes its header
        guard let url = url else { return }
        let fresh = frames - carryFrames
        let db: Float = peak > 0 ? 20 * log10(peak) : -160
        let meanRms: Float = frames > 0 && sumSquares > 0 ? Float(10 * log10(sumSquares / Double(frames))) : -160
        let chunk = Chunk(url: url, index: index, seconds: Double(frames) / 16000, peakDb: db, rmsDb: meanRms, side: side,
                          start: Double(framesBefore - carryFrames) / 16000)
        index += 1
        framesBefore += fresh
        carry = overlap ? tail : []
        quietRun = 0
        sumSquares = 0
        frames = 0
        peak = 0
        fileURL = nil
        DispatchQueue.main.async { self.onChunk?(chunk) }
    }

    private func discard() {
        framesBefore += frames - carryFrames
        file = nil
        if let u = fileURL { try? FileManager.default.removeItem(at: u) }
        fileURL = nil
        frames = 0
        peak = 0
        sumSquares = 0
    }
}

/// The other side of the call: whatever the Mac is playing, captured with ScreenCaptureKit. Needs Screen & System Audio Recording.
final class ScreenAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "freeflow.screenaudio")
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw FFError(message: "No display to listen through") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        // Audio only is not offered, so ask for the smallest picture, rarely.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcm(from: sampleBuffer) else { return }
        onBuffer?(pcm)
    }

    private static func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = sb.formatDescription, var asbd = fd.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let n = AVAudioFrameCount(sb.numSamples)
        guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return nil }
        pcm.frameLength = n
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

// MARK: - One call's notes

struct MeetingNote: Identifiable {
    let id: String
    let url: URL
    let app: String
    let start: Date
    let seconds: Int
    let bothSides: Bool
    let recording: Bool
    let words: Int
    let preview: String
    /// "meeting" for a call or a talk, "file" for an audio or video file that was dropped in.
    var kind = "meeting"
    var summary: String?
}

enum MeetingFile {
    static let marker = "<!-- freeflow-meeting "
    private static let iso = ISO8601DateFormatter()

    struct Entry {
        let index: Int
        let isYou: Bool
        let text: String
        /// Seconds into the meeting, when known. Otherwise the piece number times the piece length is used.
        var start: Double? = nil
    }

    static func stamp(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 2 })
    }

    private static func normal(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    /// When a piece was cut in the middle of speech, the next one starts two seconds earlier, so the same words can come
    /// out twice. This drops the words at the start of `next` that already end `previous`.
    static func trimOverlap(previous: String, next: String) -> String {
        let a = previous.split(separator: " ").map(String.init)
        let b = next.split(separator: " ").map(String.init)
        guard a.count >= 2, b.count >= 2 else { return next }
        for k in stride(from: min(14, a.count, b.count), through: 2, by: -1) {
            let tailWords = a.suffix(k).map(normal)
            let headWords = b.prefix(k).map(normal)
            if tailWords == headWords, !tailWords.contains("") { return b.dropFirst(k).joined(separator: " ") }
        }
        return next
    }

    /// Your microphone also hears the call from the speakers. When what "you" said in a piece is mostly
    /// what the others said in the same piece, it is an echo and is left out.
    static func isEcho(you: String, others: String) -> Bool {
        let a = tokens(you), b = tokens(others)
        guard a.count >= 3, !b.isEmpty else { return false }
        return Double(a.intersection(b).count) / Double(a.count) >= 0.6
    }

    static func render(app: String, start: Date, seconds: Int, entries: [Entry], chunkSeconds: Double, bothSides: Bool, recording: Bool, kind: String = "meeting") -> String {
        let meta: [String: Any] = ["app": app, "start": iso.string(from: start), "seconds": seconds,
                                   "sides": bothSides ? "both" : "you", "status": recording ? "recording" : "done", "kind": kind]
        let metaJSON = (try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let day = DateFormatter()
        day.dateFormat = "EEE d MMM yyyy, h:mm a"
        var out = marker + metaJSON + " -->\n"
        if kind == "file" {
            out += "# Recording: \(app)\n"
            out += "\(day.string(from: start)) · \(max(1, seconds / 60)) min · Audio file\n\n"
            for e in entries.sorted(by: { $0.index < $1.index }) {
                out += "[\(stamp(Int(e.start ?? Double(e.index) * chunkSeconds)))] \(e.text)\n"
            }
            return out
        }
        out += "# \(app == "Meeting" ? "Meeting" : "\(app) call")\n"
        out += "\(day.string(from: start)) · \(max(1, seconds / 60)) min · \(bothSides ? "You and the others" : "Your side only")\n\n"
        let byIndex = Dictionary(grouping: entries, by: { $0.index })
        for idx in byIndex.keys.sorted() {
            let group = byIndex[idx] ?? []
            let others = group.first { !$0.isYou }
            var you = group.first { $0.isYou }
            if let y = you, let o = others, isEcho(you: y.text, others: o.text) { you = nil }
            let t = stamp(Int(others?.start ?? you?.start ?? Double(idx) * chunkSeconds))
            if let o = others { out += "[\(t)] Others: \(o.text)\n" }
            if let y = you { out += "[\(t)] You: \(y.text)\n" }
        }
        return out
    }

    static func parse(_ text: String, url: URL) -> MeetingNote? {
        guard let first = text.components(separatedBy: "\n").first, first.hasPrefix(marker),
              let end = first.range(of: " -->") else { return nil }
        let json = String(first[first.index(first.startIndex, offsetBy: marker.count)..<end.lowerBound])
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let app = o["app"] as? String, let s = o["start"] as? String, let start = iso.date(from: s) else { return nil }
        let spoken = transcriptLines(text).components(separatedBy: "\n").filter { !$0.isEmpty }.map { line -> String in
            var t = line
            if let r = t.range(of: "] ") { t = String(t[r.upperBound...]) }
            for label in ["You: ", "Others: "] where t.hasPrefix(label) { t = String(t.dropFirst(label.count)) }
            return t
        }
        let words = spoken.reduce(0) { $0 + TextCleaner.wordCount($1) }
        let preview = String(spoken.joined(separator: " ").prefix(240))
        return MeetingNote(id: url.lastPathComponent, url: url, app: app, start: start, seconds: o["seconds"] as? Int ?? 0,
                           bothSides: (o["sides"] as? String) == "both", recording: (o["status"] as? String) == "recording",
                           words: words, preview: preview, kind: o["kind"] as? String ?? "meeting", summary: summary(in: text))
    }

    // MARK: Summary block

    static let summaryStart = "<!-- freeflow-summary -->"
    static let summaryEnd = "<!-- /freeflow-summary -->"

    /// The spoken lines only: the ones that start with a time stamp in square brackets.
    static func transcriptLines(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { $0.hasPrefix("[") && $0.contains("] ") }.joined(separator: "\n")
    }

    static func summary(in text: String) -> String? {
        guard let a = text.range(of: summaryStart), let b = text.range(of: summaryEnd), a.upperBound <= b.lowerBound else { return nil }
        let inner = String(text[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// The file with its summary block replaced (or added under the header; removed when `summary` is nil).
    static func withSummary(_ summary: String?, in text: String) -> String {
        var t = text
        if let a = t.range(of: summaryStart), let b = t.range(of: summaryEnd), a.lowerBound <= b.lowerBound {
            var end = b.upperBound
            while end < t.endIndex, t[end] == "\n" { end = t.index(after: end) }
            t.removeSubrange(a.lowerBound..<end)
        }
        guard let s = summary, !s.isEmpty else { return t }
        var lines = t.components(separatedBy: "\n")
        // Header: marker line, title, facts line, blank line. The summary goes right after it.
        let at = min(4, lines.count)
        let block = "\(summaryStart)\n\(s)\n\(summaryEnd)\n"
        lines.insert(block, at: at)
        return lines.joined(separator: "\n")
    }

    static func list(in dir: URL = Paths.meetings) -> [MeetingNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let notes = files.filter { $0.pathExtension == "md" }.compactMap { u -> MeetingNote? in
            guard let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            return parse(t, url: u)
        }
        return notes.sorted { $0.start > $1.start }
    }

    static func fileName(app: String, start: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = app.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(f.string(from: start))-\(slug).md"
    }
}

/// Takes notes for one call: listens, cuts the audio into pieces, writes each piece down, keeps the file up to date.
final class MeetingSession {
    struct Summary {
        let url: URL
        let seconds: Int
        let words: Int
    }

    let app: String
    let bundle: String?
    let started = Date()
    let url: URL
    private(set) var bothSides: Bool
    private let chunkSeconds: Double
    private let transcribe: (URL, @escaping (Result<String, Error>) -> Void) -> Void
    private let cleanup: (String, Bool) -> String
    private let engine = AVAudioEngine()
    private let you: ChunkWriter
    private let others: ChunkWriter
    private var screen: ScreenAudio?
    private var entries: [MeetingFile.Entry] = []
    private var queue: [ChunkWriter.Chunk] = []
    private var busy = false
    private var stopping = false
    private var completion: ((Summary) -> Void)?
    private var failures = 0
    private var abandoned = false
    /// While the last pieces are being written down nobody else holds the session, so it holds itself until the file is final.
    private var keepAlive: MeetingSession?
    var log: (String) -> Void = { _ in }
    private let workDir: URL

    var elapsed: Int { Int(Date().timeIntervalSince(started)) }

    init(app: String, bundle: String?, bothSides: Bool, chunkSeconds: Double,
         transcribe: @escaping (URL, @escaping (Result<String, Error>) -> Void) -> Void,
         cleanup: @escaping (String, Bool) -> String) {
        self.app = app
        self.bundle = bundle
        self.bothSides = bothSides
        self.chunkSeconds = chunkSeconds
        self.transcribe = transcribe
        self.cleanup = cleanup
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("FreeFlow/meeting-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: Paths.meetings, withIntermediateDirectories: true)
        var u = Paths.meetings.appendingPathComponent(MeetingFile.fileName(app: app, start: started))
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = Paths.meetings.appendingPathComponent(MeetingFile.fileName(app: app, start: started).replacingOccurrences(of: ".md", with: "-\(n).md"))
            n += 1
        }
        url = u
        you = ChunkWriter(side: "you", dir: workDir, chunkSeconds: chunkSeconds)
        others = ChunkWriter(side: "others", dir: workDir, chunkSeconds: chunkSeconds)
        you.onChunk = { [weak self] c in self?.enqueue(c) }
        others.onChunk = { [weak self] c in self?.enqueue(c) }
    }

    /// Starts listening. Opening the microphone can stall inside the system, so it happens off the main thread
    /// and is given ten seconds; the app never freezes waiting for it.
    func start(completion: @escaping (Error?) -> Void) {
        var answered = false
        let answer: (Error?) -> Void = { error in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                if error == nil { self.startScreenAudio() }
                completion(error)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let input = self.engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else { throw FFError(message: "No microphone available (input format has no sample rate)") }
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                    self?.you.append(buffer)
                }
                try self.engine.start()
                answer(nil)
            } catch {
                answer(error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !answered else { return }
            answered = true
            self.abandoned = true
            completion(FFError(message: "The microphone did not answer in time"))
        }
    }

    private func startScreenAudio() {
        if bothSides {
            let s = ScreenAudio()
            s.onBuffer = { [weak self] b in self?.others.append(b) }
            screen = s
            Task {
                do { try await s.start() } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.log("meeting: could not listen to the other side: \(error.localizedDescription)")
                        self?.bothSides = false
                        self?.screen = nil
                        self?.writeFile(recording: true)
                    }
                }
            }
        }
        writeFile(recording: true)
    }

    /// Stops listening, writes down what is left, and calls back when the file is final.
    func stop(completion: @escaping (Summary) -> Void) {
        guard !stopping else { return }
        stopping = true
        keepAlive = self
        log("meeting: stopping (queued \(queue.count), busy \(busy))")
        self.completion = completion
        engine.inputNode.removeTap(onBus: 0)
        log("meeting: tap removed")
        engine.stop()
        log("meeting: engine stopped")
        let finishSides = { [weak self] in
            self?.log("meeting: closing the last pieces")
            self?.you.finish()
            self?.others.finish()
            self?.log("meeting: last pieces closed")
            DispatchQueue.main.async { self?.checkDone() }
        }
        if let s = screen {
            Task {
                await s.stop()
                finishSides()
            }
        } else {
            finishSides()
        }
    }

    private func enqueue(_ c: ChunkWriter.Chunk) {
        // Quiet pieces are not sent to the speech engine: it invents words ("Thank you.") from silence and room noise.
        if c.peakDb < -52 || c.rmsDb < -52 {
            try? FileManager.default.removeItem(at: c.url)
            return checkDone()
        }
        queue.append(c)
        pump()
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let c = queue.removeFirst()
        transcribe(c.url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                try? FileManager.default.removeItem(at: c.url)
                switch result {
                case .success(let raw):
                    var text = self.cleanup(raw, c.peakDb < -35)
                    if let prev = self.entries.last(where: { $0.isYou == (c.side == "you") && $0.index < c.index }) {
                        text = MeetingFile.trimOverlap(previous: prev.text, next: text)
                    }
                    if !text.isEmpty { self.entries.append(MeetingFile.Entry(index: c.index, isYou: c.side == "you", text: text, start: c.start)) }
                case .failure(let error):
                    self.log("meeting: a piece could not be transcribed: \(error.localizedDescription)")
                    self.failures += 1
                    self.entries.append(MeetingFile.Entry(index: c.index, isYou: c.side == "you", text: "(this part could not be written down)", start: c.start))
                }
                self.busy = false
                self.writeFile(recording: !self.stopping)
                self.pump()
                self.checkDone()
            }
        }
    }

    private func checkDone() {
        guard stopping else { return }
        guard !busy, queue.isEmpty, let done = completion else {
            log("meeting: waiting to finish (busy \(busy), queued \(queue.count), callback \(completion != nil))")
            return
        }
        completion = nil
        keepAlive = nil
        writeFile(recording: false)
        try? FileManager.default.removeItem(at: workDir)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let words = MeetingFile.parse(text, url: url)?.words ?? 0
        done(Summary(url: url, seconds: elapsed, words: words))
    }

    private func writeFile(recording: Bool) {
        let text = MeetingFile.render(app: app, start: started, seconds: elapsed, entries: entries, chunkSeconds: chunkSeconds,
                                      bothSides: bothSides, recording: recording)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - The part that watches and decides

/// Watches for calls every few seconds, offers to take notes, starts and stops sessions.
final class MeetingController {
    private let settings = Settings.shared
    private let overlay: Overlay
    private let transcribe: (URL, @escaping (Result<String, Error>) -> Void) -> Void
    private let cleanup: (String, Bool) -> String
    private let prompt = MeetingPrompt()
    private var brain = MeetingBrain()
    private var session: MeetingSession?
    private var starting = false
    private var timer: Timer?
    private var clock: Timer?
    private var lastCall: (name: String, bundleId: String)?

    /// Called when something visible changed (a note started or ended), so the menu bar icon can follow.
    var changed: () -> Void = {}
    var log: (String) -> Void = { _ in }
    /// Called with the note's file when a meeting has been written down, so a summary can follow.
    var finishedNote: (URL) -> Void = { _ in }
    /// Who is on a call right now. Swappable so the rules can be tried without a real call.
    var detect: () -> (name: String, bundleId: String)? = { MicWatch.currentCall() }
    var micBusy: (String) -> Bool = { MicWatch.micInUse(by: $0) }

    static let maxSeconds = 2 * 3600

    init(overlay: Overlay,
         transcribe: @escaping (URL, @escaping (Result<String, Error>) -> Void) -> Void,
         cleanup: @escaping (String, Bool) -> String) {
        self.overlay = overlay
        self.transcribe = transcribe
        self.cleanup = cleanup
    }

    var isRecording: Bool { session != nil }
    var now: (app: String, seconds: Int)? { session.map { ($0.app, $0.elapsed) } }

    func start() {
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let mode = settings.meetingMode
        guard mode != .off || session != nil else { return }
        let hit = detect()
        if let h = hit { lastCall = h }
        var inCall = hit != nil
        // A browser tab that is no longer in front still counts while the browser keeps the microphone.
        if let s = session, !inCall, let b = s.bundle { inCall = micBusy(b) }
        guard let action = brain.tick(inCall: inCall, mode: mode) else { return }
        switch action {
        case .offer:
            log("meeting: call detected (\(lastCall?.name ?? "?")), mode \(mode.rawValue)")
            offer(lastCall?.name ?? "Call", bundle: lastCall?.bundleId, mode: mode)
        case .cancelOffer: prompt.hide()
        case .stop: stop()
        }
    }

    private func offer(_ app: String, bundle: String?, mode: MeetingMode) {
        prompt.show(app: app, countdown: mode == .auto ? settings.meetingCountdown : 0,
                    onStart: { [weak self] in
                        self?.prompt.hide()
                        self?.begin(app: app, bundle: bundle, auto: true)
                    },
                    onDecline: { [weak self] in
                        self?.prompt.hide()
                        self?.brain.declinedByUser()
                    })
    }

    /// Starts notes by hand: for the call that is going on, or for a conversation in the room.
    func startNow() {
        let call = detect() ?? lastCallIfStillOn()
        prompt.hide()
        begin(app: call?.name ?? "Meeting", bundle: call?.bundleId, auto: call != nil)
    }

    private func lastCallIfStillOn() -> (name: String, bundleId: String)? { nil }

    private func begin(app: String, bundle: String?, auto: Bool) {
        guard session == nil, !starting else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        guard mic == .authorized else {
            log("meeting: not started, microphone permission is \(mic.rawValue)")
            overlay.flash("Meeting notes need the microphone", seconds: 3)
            brain.stopped(stillInCall: auto)
            return
        }
        let both = settings.meetingOthers && ScreenAudio.allowed
        let s = MeetingSession(app: app, bundle: bundle, bothSides: both, chunkSeconds: settings.meetingChunkSeconds,
                               transcribe: transcribe, cleanup: cleanup)
        s.log = log
        starting = true
        s.start { [weak self] error in
            guard let self = self else { return }
            self.starting = false
            if let error = error {
                self.log("meeting: could not start: \(error.localizedDescription)")
                self.overlay.flash("Couldn't start meeting notes · \(error.localizedDescription)", seconds: 4)
                self.brain.stopped(stillInCall: auto)
                return
            }
            self.session = s
            self.log("meeting: notes started for \(app), both sides \(both), file \(s.url.lastPathComponent)")
            self.brain.started(auto: auto)
            let label = { "Meeting notes · \(MeetingFile.stamp(s.elapsed))" }
            self.overlay.setMeeting(label())
            let c = Timer(timeInterval: 1, repeats: true) { [weak self, weak s] _ in
                guard let self = self, let s = s else { return }
                self.overlay.setMeeting(label())
                if s.elapsed >= Self.maxSeconds { self.stop(reason: "Meeting notes stopped after 2 hours") }
            }
            RunLoop.main.add(c, forMode: .common)
            self.clock = c
            self.changed()
            if self.settings.meetingOthers, !ScreenAudio.allowed {
                self.overlay.flash("Taking notes of your side only · allow Screen & System Audio Recording to hear the others", seconds: 5)
            }
        }
    }

    func stop(reason: String? = nil) {
        guard let s = session else { log("meeting: stop asked but no notes are running"); return }
        log("meeting: stop asked")
        session = nil
        clock?.invalidate()
        clock = nil
        overlay.setMeeting(nil)
        overlay.showTranscribing(label: "Writing up the meeting…")
        brain.stopped(stillInCall: detect() != nil)
        changed()
        s.stop { [weak self] sum in
            DispatchQueue.main.async {
                self?.log("meeting: notes saved, \(sum.seconds)s, \(sum.words) words")
                let min = max(1, sum.seconds / 60)
                self?.overlay.flash(reason ?? "Meeting notes saved · \(min) min · \(sum.words) words", seconds: 5)
                self?.changed()
                self?.finishedNote(sum.url)
            }
        }
    }
}
