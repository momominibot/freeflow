import Foundation

// The Mac app's text code (Sources/Text.swift) is shared with this app. It expects a `Paths` and a `LearnedFile`; here they are small.
// The dictionary lives in the app's Documents folder, so it shows up in the Files app (On My iPhone › FreeFlow › dictionary.txt)
// and can be replaced with the one from the Mac.

enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let support = documents
    static let dictionary = documents.appendingPathComponent("dictionary.txt")
    static let history = documents.appendingPathComponent("history.json")
}

/// Words learned on the Mac from corrections are not on the phone yet; the dictionary covers it.
struct LearnedFile {
    func activeFixes(isCommon: (String) -> Bool) -> [(wrong: String, right: String)] { [] }
    func topTerms(_ n: Int) -> [String] { [] }
}
