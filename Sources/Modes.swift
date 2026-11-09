import Foundation

// Modes: your own writing instructions for clean-up, used for chosen apps or everywhere (like Superwhisper's modes).
// Transforms: saved rewrite prompts you run on the text you have selected (like Wispr's Transforms).

struct CustomMode: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
    /// Bundle ids of the apps that use this mode. Empty means it is only used when it is the one switched on everywhere.
    var apps: [String]
}

struct Transform: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var prompt: String
}

struct ModesFile: Codable, Equatable {
    var modes: [CustomMode] = []
    var transforms: [Transform] = []
    /// A mode used in every app that has none of its own.
    var activeMode: String?
}

enum ModeStore {
    static let seedTransforms: [Transform] = [
        Transform(id: "shorter", name: "Make it shorter", prompt: "Make this shorter. Keep the meaning, the names and the numbers. Cut anything that repeats."),
        Transform(id: "grammar", name: "Fix grammar only", prompt: "Fix spelling, grammar and punctuation only. Do not change the wording or the tone."),
        Transform(id: "friendlier", name: "Make it friendlier", prompt: "Rewrite this in a warmer, friendlier tone. Keep the meaning and every fact."),
        Transform(id: "formal", name: "Make it more formal", prompt: "Rewrite this in a polite, professional tone suitable for work email. Keep the meaning and every fact."),
        Transform(id: "bullets", name: "Turn into bullet points", prompt: "Turn this into a short bulleted list, one point per line. Keep every fact, name and number."),
    ]

    /// The saved file, or the starting set when there is none yet.
    static func load(url: URL = Paths.modes) -> ModesFile {
        if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(ModesFile.self, from: data) { return f }
        return ModesFile(modes: [], transforms: seedTransforms, activeMode: nil)
    }

    static func save(_ f: ModesFile, url: URL = Paths.modes) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(f) { try? data.write(to: url, options: .atomic) }
    }

    /// The writing instruction for an app: a mode given to that app first, then the one switched on everywhere.
    static func tone(for app: String?, in f: ModesFile) -> CustomMode? {
        if let app = app, let m = f.modes.first(where: { $0.apps.contains(app) && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty }) { return m }
        if let id = f.activeMode, let m = f.modes.first(where: { $0.id == id && !$0.prompt.trimmingCharacters(in: .whitespaces).isEmpty }) { return m }
        return nil
    }

    static func newId() -> String { UUID().uuidString.lowercased() }
}
