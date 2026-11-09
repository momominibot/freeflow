import Foundation
import SwiftUI
import UIKit

@MainActor
final class Dictation: ObservableObject {
    enum Phase: Equatable {
        case preparing(String)
        case ready
        case listening
        case transcribing
        case failed(String)
    }

    @Published var phase: Phase = .preparing("Starting…")
    @Published var level: Float = -80
    @Published var result: Entry?
    @Published var history: [Entry] = []
    @Published var copiedFlash = false
    @Published var seconds: Int = 0

    @Published var model: SpeechModel { didSet { defaults.set(model.rawValue, forKey: "model"); if oldValue != model { Task { await prepare() } } } }
    @Published var language: SpeechLanguage { didSet { defaults.set(language.rawValue, forKey: "language") } }
    @Published var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    @Published var autoCopy: Bool { didSet { defaults.set(autoCopy, forKey: "autoCopy") } }
    @Published var dictionaryText: String { didSet { try? dictionaryText.write(to: Paths.dictionary, atomically: true, encoding: .utf8) } }

    private let defaults = UserDefaults.standard
    private let engine = SpeechEngine()
    private let recorder = Recorder()
    private var startedAt: Date?
    private var timer: Timer?
    private var startedByThisPress = false

    init() {
        model = SpeechModel(rawValue: defaults.string(forKey: "model") ?? "") ?? .balanced
        language = SpeechLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .english
        removeFillers = defaults.object(forKey: "removeFillers") as? Bool ?? true
        autoCopy = defaults.object(forKey: "autoCopy") as? Bool ?? true
        if !FileManager.default.fileExists(atPath: Paths.dictionary.path) {
            try? Vocabulary.template.write(to: Paths.dictionary, atomically: true, encoding: .utf8)
        }
        dictionaryText = (try? String(contentsOf: Paths.dictionary, encoding: .utf8)) ?? Vocabulary.template
        history = HistoryStore.load()
        recorder.onLevel = { [weak self] db in Task { @MainActor in self?.level = db } }
        recorder.onLimit = { [weak self] in Task { @MainActor in self?.end() } }
    }

    // MARK: - Start up

    func start() async {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
            await selfTest(file: args[i + 1], args: args)
            return
        }
        await prepare()
    }

    func prepare() async {
        phase = .preparing("Starting…")
        do {
            try await engine.load(model) { [weak self] text in Task { @MainActor in self?.phase = .preparing(text) } }
            phase = .ready
        } catch {
            phase = .failed("The speech model could not be loaded: \(error.localizedDescription)")
        }
    }

    // MARK: - Talking

    /// A finger goes down on the button.
    func press() {
        if phase == .ready {
            startedByThisPress = true
            Task { await begin() }
        } else if phase == .listening {
            startedByThisPress = false
        }
    }

    /// The finger comes up. A quick tap leaves it listening (tap again to finish); holding is push to talk.
    func release(heldFor t: TimeInterval) {
        guard phase == .listening else { return }
        if startedByThisPress && t < 0.35 { return }
        end()
    }

    private func begin() async {
        guard phase == .ready else { return }
        guard await Recorder.permission() else {
            phase = .failed("FreeFlow needs the microphone. Turn it on in Settings › FreeFlow › Microphone.")
            return
        }
        do {
            try recorder.start()
            startedAt = Date()
            seconds = 0
            phase = .listening
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startedAt else { return }
                    self.seconds = Int(Date().timeIntervalSince(s))
                }
            }
        } catch {
            phase = .failed("The microphone could not start: \(error.localizedDescription)")
        }
    }

    func cancel() {
        guard phase == .listening else { return }
        timer?.invalidate()
        _ = recorder.stop()
        phase = .ready
    }

    func end() {
        guard phase == .listening else { return }
        timer?.invalidate()
        let took = Date().timeIntervalSince(startedAt ?? Date())
        let heard = recorder.stop()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard heard.samples.count > Int(Recorder.rate * 0.4) else { phase = .ready; return }
        phase = .transcribing
        Task {
            do {
                let raw = try await engine.transcribe(samples: heard.samples, language: language,
                                                      hints: PhonePipeline.hints(dictionary: dictionaryText))
                finish(raw: raw, seconds: took, quiet: heard.peakDb < PhonePipeline.quietBelowDb)
                phase = .ready
            } catch {
                phase = .failed("Could not write that down: \(error.localizedDescription)")
            }
        }
    }

    private func finish(raw: String, seconds: Double, quiet: Bool) {
        let text = PhonePipeline.finish(raw, dictionary: dictionaryText, removeFillers: removeFillers, quiet: quiet)
        guard !text.isEmpty else { result = nil; return }
        let entry = Entry(text: text, raw: raw, seconds: seconds, model: model.rawValue)
        result = entry
        history.insert(entry, at: 0)
        HistoryStore.save(history)
        if autoCopy { copy(text) }
    }

    // MARK: - Using the words

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        copiedFlash = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copiedFlash = false
        }
    }

    func delete(_ entry: Entry) {
        history.removeAll { $0.id == entry.id }
        if result?.id == entry.id { result = nil }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history = []
        result = nil
        HistoryStore.save(history)
    }

    func transcribeFile(_ url: URL) {
        guard phase == .ready else { return }
        phase = .transcribing
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let raw = try await engine.transcribe(file: url.path, language: language,
                                                      hints: PhonePipeline.hints(dictionary: dictionaryText))
                finish(raw: raw, seconds: 0, quiet: false)
                phase = .ready
            } catch {
                phase = .failed("Could not write that file down: \(error.localizedDescription)")
            }
        }
    }

    func importDictionary(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { dictionaryText = text }
    }

    func resetDictionary() { dictionaryText = Vocabulary.template }

    // MARK: - Self test (launch with --transcribe <audio file> [--model base] [--language en]), used to check the whole route

    private func selfTest(file: String, args: [String]) async {
        func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let m = arg("--model").flatMap({ SpeechModel(rawValue: $0) }) { model = m }
        if let l = arg("--language").flatMap({ SpeechLanguage(rawValue: $0) }) { language = l }
        print("FFTEST: start model=\(model.rawValue) language=\(language.rawValue)")
        do {
            try await engine.load(model) { text in print("FFTEST: \(text)") }
            let started = Date()
            let raw = try await engine.transcribe(file: file, language: language, hints: PhonePipeline.hints(dictionary: dictionaryText))
            let text = PhonePipeline.finish(raw, dictionary: dictionaryText, removeFillers: removeFillers, quiet: false)
            print("FFTEST: seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
            print("FFTEST: raw=\(raw)")
            print("FFTEST: result=\(text)")
            print("FFTEST: done")
        } catch {
            print("FFTEST: failed \(error.localizedDescription)")
        }
        fflush(stdout)
        exit(0)
    }
}
