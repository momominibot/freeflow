import SwiftUI
import UIKit

// The same soft plum and lilac as the Mac app, light and dark.
enum RT {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let paper = dyn(0xF8F3FB, 0x180D31)
    static let paper2 = dyn(0xEFE6F6, 0x22134A)
    static let card = dyn(0xFFFFFF, 0x2B1A59)
    static let plum = dyn(0x5A4274, 0xE9DDFB)
    static let ink = dyn(0x2A2140, 0xF3ECFF)
    static let ink2 = dyn(0x5E5478, 0xC9BCE6)
    static let ink3 = dyn(0x7A6F94, 0xA798CB)
    static let lilac = Color(UIColor(hex: 0xA98BD6))
    static let primary = dyn(0x5A4274, 0x8E6FC8)
    static let live = Color(UIColor(hex: 0xE5708B))
    static let ok = dyn(0x2F7D5B, 0x6FD3A5)
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(RT.card))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
    }
}

struct SoftButton: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(prominent ? .white : RT.plum)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(prominent ? RT.primary : RT.paper2))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
