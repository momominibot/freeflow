import AppKit
import AVFoundation

// Two jobs that turn audio into notes without the microphone:
// writing down an audio or video file, and writing a summary of any saved note with the local AI.

/// Pure helpers for summaries.
enum Summarizer {
    /// Splits a transcript on line breaks into parts of about `maxWords` words, for a model with a short memory.
    static func parts(_ text: String, maxWords: Int = 2200) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var n = 0
        for line in text.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let w = TextCleaner.wordCount(line)
            if n + w > maxWords, !current.isEmpty {
                out.append(current.joined(separator: "\n"))
                current = []
                n = 0
            }
            current.append(line)
            n += w
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// The notes as they are put in the file: no long dashes, no stray preamble.
    static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ",").replacingOccurrences(of: "–", with: "-")
        // Keep from the first section heading on, if the model added a sentence before it.
        if let r = t.range(of: "## ") , r.lowerBound != t.startIndex, !t.hasPrefix("## ") { t = String(t[r.lowerBound...]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Writes a summary into a saved note, in the background.
final class NoteSummarizer {
    private(set) var running = Set<String>()
    var changed: () -> Void = {}
    var log: (String) -> Void = { _ in }
    /// Too little was said to be worth summarising.
    static let minWords = 40

    /// Calls `completion(nil)` when the summary was written, otherwise a short reason.
    func summarize(_ url: URL, completion: @escaping (String?) -> Void = { _ in }) {
        let id = url.lastPathComponent
        guard !running.contains(id) else { return completion("Already working on it") }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return completion("Couldn't open the note") }
        let transcript = MeetingFile.transcriptLines(text)
        guard TextCleaner.wordCount(transcript) >= Self.minWords else { return completion("Too short to summarise") }
        guard Rewriter.shared.isAvailable() else { return completion("The local AI isn't set up (Help › Set up the local AI)") }
        running.insert(id)
        changed()
        log("summary: writing notes for \(id), \(TextCleaner.wordCount(transcript)) words")
        Rewriter.shared.summarize(transcript) { [weak self] result in
            DispatchQueue.main.async {
                self?.running.remove(id)
                defer { self?.changed() }
                switch result {
                case .success(let s) where !s.isEmpty:
                    let now = (try? String(contentsOf: url, encoding: .utf8)) ?? text
                    let note = "Written by the local AI from the transcript below. Check it before you share it.\n\n" + s
                    try? MeetingFile.withSummary(note, in: now).write(to: url, atomically: true, encoding: .utf8)
                    self?.log("summary: done for \(id)")
                    completion(nil)
                case .success:
                    completion("The AI returned nothing")
                case .failure(let e):
                    self?.log("summary: failed for \(id): \(e.localizedDescription)")
                    completion(e.localizedDescription)
                }
            }
        }
    }
}

/// Writes down an audio or video file: ffmpeg turns it into one-minute 16 kHz pieces, each piece goes through the speech engine.
final class FileTranscriber {
    private let transcribe: (URL, @escaping (Result<String, Error>) -> Void) -> Void
    private let cleanup: (String) -> String
    private(set) var job: (name: String, progress: Double)?
    var changed: () -> Void = {}
    var log: (String) -> Void = { _ in }
    static let pieceSeconds = 60

    init(transcribe: @escaping (URL, @escaping (Result<String, Error>) -> Void) -> Void, cleanup: @escaping (String) -> String) {
        self.transcribe = transcribe
        self.cleanup = cleanup
    }

    static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The loudest sample of a 16-bit WAV, in dB below full scale. Quiet pieces are skipped: the engine invents words from silence.
    static func peakDb(of url: URL) -> Float {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return -160 }
        var peak: Int32 = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 22..<samples.count { peak = max(peak, abs(Int32(samples[i]))) }
        }
        return peak > 0 ? 20 * log10(Float(peak) / 32768) : -160
    }

    /// Starts writing the file down. `completion` gets the note's URL, or the reason it failed.
    func start(_ file: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard job == nil else { return completion(.failure(FFError(message: "Already writing down another file"))) }
        guard let ffmpeg = Self.ffmpegPath else {
            return completion(.failure(FFError(message: "Writing down files needs ffmpeg. In a terminal: brew install ffmpeg")))
        }
        let name = file.deletingPathExtension().lastPathComponent
        job = (file.lastPathComponent, 0)
        changed()
        let started = Date()
        try? FileManager.default.createDirectory(at: Paths.meetings, withIntermediateDirectories: true)
        let note = Paths.meetings.appendingPathComponent(MeetingFile.fileName(app: name, start: started))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("FreeFlow/file-\(UUID().uuidString)", isDirectory: true)
        let finish: (Result<URL, Error>) -> Void = { [weak self] r in
            DispatchQueue.main.async {
                self?.job = nil
                try? FileManager.default.removeItem(at: work)
                self?.changed()
                completion(r)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-nostdin", "-loglevel", "error", "-y", "-i", file.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                           "-f", "segment", "-segment_time", String(Self.pieceSeconds), "-reset_timestamps", "1",
                           work.appendingPathComponent("part-%05d.wav").path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return finish(.failure(FFError(message: "Couldn't start ffmpeg"))) }
            p.waitUntilExit()
            let parts = ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasSuffix(".wav") }.sorted()
            guard p.terminationStatus == 0, !parts.isEmpty else {
                return finish(.failure(FFError(message: "That file has no sound Purrscribe can read")))
            }
            var entries: [MeetingFile.Entry] = []
            let total = parts.count
            let write: (Bool) -> Void = { recording in
                let text = MeetingFile.render(app: name, start: started, seconds: total * Self.pieceSeconds, entries: entries,
                                              chunkSeconds: Double(Self.pieceSeconds), bothSides: false, recording: recording, kind: "file")
                try? text.write(to: note, atomically: true, encoding: .utf8)
            }
            write(true)
            for (i, part) in parts.enumerated() {
                let url = work.appendingPathComponent(part)
                if Self.peakDb(of: url) > -52 {
                    let sem = DispatchSemaphore(value: 0)
                    var heard = ""
                    var failed: Error?
                    self.transcribe(url) { r in
                        switch r { case .success(let t): heard = t; case .failure(let e): failed = e }
                        sem.signal()
                    }
                    sem.wait()
                    if let e = failed { return finish(.failure(e)) }
                    let text = self.cleanup(heard)
                    if !text.isEmpty { entries.append(MeetingFile.Entry(index: i, isYou: false, text: text)) }
                }
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { self.job = (file.lastPathComponent, Double(i + 1) / Double(total)); self.changed() }
                write(true)
            }
            write(false)
            finish(.success(note))
        }
    }
}
