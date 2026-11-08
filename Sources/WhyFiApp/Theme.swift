import AppKit
import SwiftUI
import WhyFiCore

extension Color {
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

/// Roles, not hues: neighbours stay neutral so the user's own network, the selection and the
/// recommendation stand out.
enum Theme {
    static let own = Color(light: "#2a78d6", dark: "#3987e5")
    static let selected = Color(light: "#eb6834", dark: "#d95926")
    static let neighbour = Color(light: "#52514e", dark: "#c3c2b7")
    static let recommended = Color(light: "#0ca30c", dark: "#0ca30c")
    static let grid = Color.secondary.opacity(0.18)

    static func grade(_ g: Grade) -> Color {
        switch g {
        case .a: Color(light: "#0ca30c", dark: "#0ca30c")
        case .b: Color(light: "#6fbf3a", dark: "#5fae2c")
        case .c: Color(light: "#fab219", dark: "#fab219")
        case .d: Color(light: "#ec835a", dark: "#ec835a")
        case .f: Color(light: "#d03b3b", dark: "#d03b3b")
        }
    }
}
