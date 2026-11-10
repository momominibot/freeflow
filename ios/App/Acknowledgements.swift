import SwiftUI

/// Who made the parts FreeFlow is built on, and under which licence. The full texts ship inside the app (ThirdPartyNotices.txt).
struct AcknowledgementsView: View {
    private struct Part: Identifiable {
        let name: String, what: String, licence: String
        var id: String { name }
    }

    private let parts = [
        Part(name: "Harper", what: "The grammar and spelling checker in the Polish tab. By Automattic.", licence: "Apache-2.0"),
        Part(name: "WhisperKit", what: "Runs the speech model on this iPhone. By Argmax.", licence: "MIT"),
        Part(name: "Whisper", what: "The speech models themselves. By OpenAI.", licence: "MIT"),
        Part(name: "Rhea and the cats", what: "The pictures on the Talk and Polish tabs and the app icon. Our own artwork, drawn for Rhythme.", licence: "Ours"),
        Part(name: "Apple Intelligence", what: "Writes the rewrites on iPhones that support it. Part of iOS.", licence: "Apple"),
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = info?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// The licence file is long (hundreds of KB), so it is shown in pieces that load as you scroll.
    private let notices: [String] = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ["The licence texts are in ThirdPartyNotices.txt in the FreeFlow source."] }
        return text.components(separatedBy: "\n\n")
    }()

    var body: some View {
        List {
            Section {
                HStack { Text("FreeFlow"); Spacer(); Text(version).foregroundColor(RT.ink3) }
            } footer: {
                Text("Your voice and your writing stay on this iPhone. There is no account and nothing is sent to a server.")
            }
            Section("Built on") {
                ForEach(parts) { part in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(part.name).font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text(part.licence).font(.system(size: 13, weight: .medium)).foregroundColor(RT.ink3)
                        }
                        Text(part.what).font(.system(size: 13)).foregroundColor(RT.ink3)
                    }
                }
            }
            Section {
                NavigationLink("Full licence texts") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(notices.enumerated()), id: \.offset) { _, piece in
                                Text(piece).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(16)
                    }
                    .background(RT.paper.ignoresSafeArea())
                    .navigationTitle("Licences")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(RT.paper.ignoresSafeArea())
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
