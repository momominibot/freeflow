import SwiftUI
import AppKit
import CoreText

/// The Rhythme look: soft lavender paper, plum ink, blush and lilac accents (rhythme.app room.css and site.css).
/// Every colour that sits on a page has a light and a dark royal purple value and follows the window's appearance.
enum RT {
    static let paper = Color.dyn(0xF8F3FB, 0x180D31)
    static let paper2 = Color.dyn(0xF1E9F7, 0x22134A)
    static let card = Color.dyn(0xFFFFFF, 0x2B1A59)
    static let ink = Color.dyn(0x3B2D52, 0xF3ECFF)
    static let ink2 = Color.dyn(0x6F5F8C, 0xC5B5E6)
    static let ink3 = Color.dyn(0x9A8CB3, 0xA798CE)
    static let plum = Color.dyn(0x5A4274, 0xE4D7FB)
    static let mauve = Color.dyn(0x7A5C96, 0xB99DE3)
    static let lilac = Color.dyn(0xC9B6E6, 0x7459BB)
    static let lilac2 = Color.dyn(0xE7DCF5, 0x3C2872)
    static let blush = Color.dyn(0xF6C9D6, 0x9A5A92)
    static let blush2 = Color.dyn(0xFBE3EA, 0x4B2552)
    static let ok = Color.dyn(0x6BA88A, 0x86D6AE)
    static let warn = Color.dyn(0xD4A85A, 0xEEC47E)
    static let high = Color.dyn(0xD4707A, 0xFF8E9C)

    // The floating bar is night plum on any wallpaper, so its colours never change with the appearance.
    static let cream = Color(hex: 0xFFF6EC)
    static let gold = Color(hex: 0xF3D49B)
    static let mint = Color(hex: 0xBFE3D4)
    static let night = Color(hex: 0x2B1F44)
    static let night2 = Color(hex: 0x4A3666)
    static let pillLilac = Color(hex: 0xC9B6E6)
    static let pillBlush = Color(hex: 0xF6C9D6)

    static let primary = LinearGradient(colors: [Color.dyn(0x7B5DB3, 0x7C5BCB), Color.dyn(0x5F4596, 0x5A3DAE)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let soft = LinearGradient(colors: [lilac, blush], startPoint: .leading, endPoint: .trailing)
    static let shadow = Color.dyn(0x5A4274, 0x000000, 0.18, 0.40)
    /// Card shadows, hairlines and the dimmed backdrop behind a dialog.
    static let lift = Color.dyn(0x5A4274, 0x000000, 0.10, 0.35)
    static let lift2 = Color.dyn(0x5A4274, 0x000000, 0.22, 0.50)
    static let line = Color.dyn(0x6B528E, 0xB99DE3, 0.22, 0.26)
    static let line2 = Color.dyn(0x6B528E, 0xB99DE3, 0.14, 0.18)
    static let scrim = Color.dyn(0x2B1F44, 0x000000, 0.32, 0.55)
    /// The window itself, for the part of the frame SwiftUI does not draw.
    static let windowBackground = NSColor.dyn(0xF8F3FB, 0x180D31)

    static let radius: CGFloat = 22
    static let radiusSmall: CGFloat = 14
}

extension NSColor {
    /// One colour for the light appearance and one for the dark, picked each time it is drawn.
    static func dyn(_ light: UInt32, _ dark: UInt32, _ lightAlpha: CGFloat = 1, _ darkAlpha: CGFloat? = nil) -> NSColor {
        NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: isDark ? (darkAlpha ?? lightAlpha) : lightAlpha)
        }
    }
}

extension Color {
    static func dyn(_ light: UInt32, _ dark: UInt32, _ lightAlpha: Double = 1, _ darkAlpha: Double? = nil) -> Color {
        Color(nsColor: NSColor.dyn(light, dark, CGFloat(lightAlpha), darkAlpha.map { CGFloat($0) }))
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Manrope for text, Newsreader for headings, as in the Rhythme app.
enum Fonts {
    enum Weight { case medium, semibold, bold, heavy }

    static func registerAll() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    static func sans(_ size: CGFloat, _ weight: Weight = .medium) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Manrope-Medium"
        case .semibold: name = "Manrope-SemiBold"
        case .bold: name = "Manrope-Bold"
        case .heavy: name = "Manrope-ExtraBold"
        }
        return .custom(name, fixedSize: size)
    }

    static func serif(_ size: CGFloat) -> Font {
        .custom("Newsreader-SemiBold", fixedSize: size)
    }
}

/// The little face from the Rhythme corner: two dots and a smile.
struct Face: View {
    enum Mood { case smile, flat, talk(CGFloat), sleepy }
    var mood: Mood = .smile
    var color: Color = RT.plum

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let eye = h * 0.27
            ZStack {
                Circle().fill(color).frame(width: eye, height: eye).position(x: w * 0.20, y: h * 0.34)
                Circle().fill(color).frame(width: eye, height: eye).position(x: w * 0.80, y: h * 0.34)
                mouth(w, h)
            }
        }
        .aspectRatio(2.0, contentMode: .fit)
    }

    @ViewBuilder
    private func mouth(_ w: CGFloat, _ h: CGFloat) -> some View {
        let line = max(1.3, h * 0.15)
        switch mood {
        case .smile:
            Path { p in
                p.move(to: CGPoint(x: w * 0.36, y: h * 0.46))
                p.addQuadCurve(to: CGPoint(x: w * 0.64, y: h * 0.46), control: CGPoint(x: w * 0.5, y: h * 1.06))
            }.stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
        case .flat:
            Path { p in
                p.move(to: CGPoint(x: w * 0.41, y: h * 0.68))
                p.addLine(to: CGPoint(x: w * 0.59, y: h * 0.68))
            }.stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
        case .sleepy:
            Path { p in
                p.move(to: CGPoint(x: w * 0.40, y: h * 0.58))
                p.addQuadCurve(to: CGPoint(x: w * 0.60, y: h * 0.58), control: CGPoint(x: w * 0.5, y: h * 0.90))
            }.stroke(color, style: StrokeStyle(lineWidth: line * 0.9, lineCap: .round))
        case .talk(let level):
            let open = max(0.16, min(0.58, 0.16 + level * 0.5))
            Ellipse().fill(color)
                .frame(width: w * 0.2, height: h * open)
                .position(x: w * 0.5, y: h * (0.50 + open / 2))
        }
    }
}

/// The painted pictures (assets/art): the mascot in a scene for each part of the app. Missing ones fall back to the little face.
enum Art {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let i = cache[name] { return i }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Brand/art/\(name).webp"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}

/// A painted picture at a given size, or the little face when there is none.
struct ArtView: View {
    let name: String
    var size: CGFloat = 96
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let img = Art.image(name) {
            let pic = Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            if scheme == .dark {
                // The pictures are painted for pale paper: their glass is see-through. On royal purple they sit on a pearly tile.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xEFE6FB), Color(hex: 0xD8C7F1)], startPoint: .top, endPoint: .bottom))
                    pic.frame(width: size * 0.9, height: size * 0.9)
                }
                .frame(width: size, height: size)
            } else {
                pic.frame(width: size, height: size)
            }
        } else {
            Face(mood: .sleepy, color: RT.mauve).frame(width: size * 0.5)
        }
    }
}

/// The FreeFlow logo: the pearly bubble with its face. Falls back to a drawn disc if the picture is missing.
struct Emblem: View {
    var size: CGFloat = 34
    private static let logo: NSImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Brand/logo-mark.png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let img = Self.logo {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: [RT.lilac, RT.blush], startPoint: .topLeading, endPoint: .bottomTrailing))
                Face(mood: .smile, color: RT.plum).frame(width: size * 0.64)
            }
            .frame(width: size, height: size)
            .shadow(color: RT.shadow.opacity(0.6), radius: size * 0.16, y: size * 0.08)
        }
    }
}

// MARK: - Controls

struct PrimaryButton: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.sans(small ? 13 : 14, .heavy))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundColor(.white)
            .padding(.horizontal, small ? 14 : 20)
            .padding(.vertical, small ? 8 : 11)
            .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.primary))
            .shadow(color: Color(hex: 0x7A5C96, opacity: 0.32), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    var small = true
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.sans(small ? 13 : 14, .bold))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundColor(danger ? RT.high : RT.ink2)
            .padding(.horizontal, small ? 14 : 20)
            .padding(.vertical, small ? 8 : 11)
            .background(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous).fill(RT.card.opacity(0.7)))
            .overlay(RoundedRectangle(cornerRadius: RT.radiusSmall, style: .continuous)
                .strokeBorder(danger ? RT.high.opacity(0.4) : RT.line, lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct RhythmeToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 8)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AnyShapeStyle(RT.primary) : AnyShapeStyle(RT.lilac2))
                        .frame(width: 42, height: 25)
                    Circle().fill(Color.white).frame(width: 19, height: 19)
                        .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                        .padding(3)
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.8), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A row of soft chips, one of them selected.
struct ChipPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button { selection = o.0 } label: {
                    Text(o.1)
                        .font(Fonts.sans(13, on ? .heavy : .bold))
                        .foregroundColor(on ? .white : RT.ink2)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(on ? AnyShapeStyle(RT.primary) : AnyShapeStyle(RT.paper2)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension View {
    /// A rounded card with the soft shadow.
    func rtCard(padding: CGFloat = 20, radius: CGFloat = RT.radius) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(RT.card))
            .shadow(color: RT.lift, radius: 16, y: 6)
    }
}

/// Chips that wrap onto new lines, one selected. For longer lists such as languages.
struct WrapChipPicker<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button { selection = o.0 } label: {
                    Text(o.1)
                        .font(Fonts.sans(13, on ? .heavy : .bold))
                        .foregroundColor(on ? .white : RT.ink2)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(on ? AnyShapeStyle(RT.primary) : AnyShapeStyle(RT.paper2)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A key cap such as Fn or right ⌃.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Fonts.sans(13, .heavy))
            .foregroundColor(RT.plum)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(RT.lilac2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(RT.lilac, lineWidth: 1))
    }
}
