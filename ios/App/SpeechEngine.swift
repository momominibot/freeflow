import Foundation
import WhisperKit

/// The speech model, running on this iPhone. Nothing is sent anywhere once the model has been downloaded.
enum SpeechModel: String, CaseIterable, Identifiable {
    case fast = "base"
    case balanced = "small"
    case best = "large-v3-v20240930_626MB"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .best: return "Best"
        }
    }
    var note: String {
        switch self {
        case .fast: return "Smallest download, quickest. Fine for short notes in a quiet room."
        case .balanced: return "A good middle: noticeably better with names and accents."
        case .best: return "Whisper large v3 turbo, about 626 MB. The most accurate, and the one to use for mixed English and Chinese."
        }
    }
}

enum SpeechLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"
    case auto = "auto"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Chinese (keeps English words)"
        case .auto: return "Detect it"
        }
    }
    /// What the model is told; nil lets it decide.
    var code: String? { self == .auto ? nil : rawValue }
}

actor SpeechEngine {
    private var pipe: WhisperKit?
    private var loaded: String?

    var isLoaded: Bool { pipe != nil }

    /// Downloads the model the first time (the only time this app uses the network), then loads it.
    func load(_ model: SpeechModel, progress: @escaping @Sendable (String) -> Void) async throws {
        if loaded == model.rawValue, pipe != nil { return }
        pipe = nil
        loaded = nil
        // The first load after a download can fail once while the system compiles the model for this device (seen once in the
        // simulator, not repeatable), so it is tried twice before an error is shown. The second try reuses the download.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                progress(attempt == 1 ? "Downloading the speech model. This happens once." : "Trying the speech model again…")
                let folder = try await WhisperKit.download(variant: model.rawValue, progressCallback: { p in
                    progress("Downloading the speech model: \(Int(p.fractionCompleted * 100))%")
                })
                progress("Getting the speech model ready…")
                let config = WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: true, load: true, download: false)
                pipe = try await WhisperKit(config)
                loaded = model.rawValue
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw lastError ?? NSError(domain: "FreeFlow", code: 3, userInfo: [NSLocalizedDescriptionKey: "The speech model could not be loaded."])
    }

    private func options(language: SpeechLanguage, hints: [String]) -> DecodingOptions {
        var tokens: [Int]?
        if !hints.isEmpty, let tokenizer = pipe?.tokenizer {
            let text = " " + hints.prefix(40).joined(separator: ", ")
            tokens = tokenizer.encode(text: text).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        return DecodingOptions(verbose: false, task: .transcribe, language: language.code, temperature: 0.0,
                               usePrefillPrompt: true, detectLanguage: language == .auto, skipSpecialTokens: true,
                               withoutTimestamps: true, promptTokens: tokens)
    }

    func transcribe(samples: [Float], language: SpeechLanguage, hints: [String]) async throws -> String {
        guard let pipe else { throw NSError(domain: "FreeFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model is not ready yet."]) }
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options(language: language, hints: hints))
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(file: String, language: SpeechLanguage, hints: [String]) async throws -> String {
        guard let pipe else { throw NSError(domain: "FreeFlow", code: 2, userInfo: [NSLocalizedDescriptionKey: "The speech model is not ready yet."]) }
        let results = try await pipe.transcribe(audioPath: file, decodeOptions: options(language: language, hints: hints))
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
