import SwiftUI
import UIKit

/// Rhea and her cats, the same pictures the Mac app shows (assets/art/cats, drawn for Rhythme).
enum CatArt {
    private static var cache: [String: UIImage] = [:]

    static func image(_ name: String) -> UIImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache[name] = img
        return img
    }

    /// The picture on the Talk tab: Rhea does what the app is doing.
    static func hero(for phase: Dictation.Phase) -> String {
        switch phase {
        case .ready: return "hero-hug"
        case .listening: return "hero-listen"
        case .transcribing: return "hero-note"
        case .preparing, .failed: return "hero-sleep"
        }
    }
}

/// A cat picture at a given height, nothing at all when the picture is missing.
struct CatPicture: View {
    let name: String
    var height: CGFloat = 160

    var body: some View {
        if let img = CatArt.image(name) {
            Image(uiImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }
}
