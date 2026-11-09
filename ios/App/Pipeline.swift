import Foundation

/// What the speech model heard, turned into the text you get. This is the Mac app's own clean-up (Sources/Text.swift):
/// the dictionary, fillers, bracket noise, the hallucinated "thank you" a silent take produces, and "new paragraph".
enum PhonePipeline {
    static func finish(_ raw: String, dictionary: String, removeFillers: Bool, quiet: Bool) -> String {
        let vocab = Vocabulary.parse(dictionary)
        let cleaned = TextCleaner.clean(raw, removeFillers: removeFillers, vocab: vocab, quiet: quiet)
        return SpokenCommands.parse(cleaned).text
    }

    /// The words handed to the speech model as a spelling hint.
    static func hints(dictionary: String) -> [String] {
        Vocabulary.parse(dictionary).terms
    }

    /// A take whose loudest moment was this quiet is probably silence.
    static let quietBelowDb: Float = -30
}

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var text: String
    var raw: String
    var seconds: Double
    var model: String
}

enum HistoryStore {
    static let keep = 200

    static func load(from url: URL = Paths.history) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    static func save(_ entries: [Entry], to url: URL = Paths.history) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(entries.prefix(keep))) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
