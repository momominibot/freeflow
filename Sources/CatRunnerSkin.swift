import SwiftUI
import AppKit

/// What the running cat (CatRunner.swift) needs from the Mac app: its pictures, colours and the Reduce motion setting.
enum CatRunnerSkin {
    static func picture(_ name: String) -> (image: Image, size: CGSize)? {
        Art.catImage(name).map { (Image(nsImage: $0), $0.size) }
    }
    static var printColor: Color { RT.mauve }
    static var zColor: Color { RT.ink3 }
    static func zFont(_ size: CGFloat) -> Font { Fonts.serif(size) }
    static var roster: [String] { Settings.shared.catRoster }
    static func labelFont(_ size: CGFloat) -> Font { Fonts.sans(size, .semibold) }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
