import AppKit
import SwiftUI

/// Colors from docs/design.md, light and dark.
enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    static let accent = Color(nsColor: NSColor(hex: 0x5B4CF5))
    static let accentText = dyn(0x4B3DE0, 0xB4ABFF)
    static let danger = dyn(0xC92A2A, 0xFF8787)
    static let canvas = dyn(0xEEF0F6, 0x121319)
    static let canvasDot = dyn(0xD7DAE6, 0x262833)
    static let line = dyn(0xE4E6EE, 0x30323F)
    static let nextBox = dyn(0xFFFFFF, 0x23242E)
    static let rowSelected = dyn(0xE7E4FF, 0x2F2A63)
    static let rowSelectedLine = dyn(0xCBC4FF, 0x4A40A8)
    static let latestBg = dyn(0xE3F8F0, 0x1B3B33)
    static let latestInk = dyn(0x0B7D5B, 0x63E6BE)
    static let todo = dyn(0xCDD0DC, 0x4A4D5C)

    // Activity colors
    static let ready = Color(nsColor: NSColor(hex: 0x5B4CF5))
    static let scanning = Color(nsColor: NSColor(hex: 0xFF5D3A))
    static let cleaning = Color(nsColor: NSColor(hex: 0xF08C00))
    static let saved = Color(nsColor: NSColor(hex: 0x12B886))
    static let stopped = Color(nsColor: NSColor(hex: 0xE8590C))
    static let offline = Color(nsColor: NSColor(hex: 0x868B9C))

    static let tints: [UInt32: UInt32] = [0x5B4CF5: 0xEEECFF, 0xFF5D3A: 0xFFEDE8, 0xF08C00: 0xFFF4DB,
                                          0x12B886: 0xE3F8F0, 0xE8590C: 0xFFF4DB, 0x868B9C: 0xF1F2F6]

    /// Card background for an activity color: pale tint in light mode, 18% glow in dark mode.
    static func tint(_ hex: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            if a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(hex: hex).withAlphaComponent(0.18)
            }
            return NSColor(hex: tints[hex] ?? 0xF1F2F6)
        })
    }

    static let brandGradient = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0x6C5CFF)),
                                                       Color(nsColor: NSColor(hex: 0xB14BF4)),
                                                       Color(nsColor: NSColor(hex: 0xFF5D3A))],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static let folderGradient = LinearGradient(colors: [Color(nsColor: NSColor(hex: 0xFFB020)),
                                                        Color(nsColor: NSColor(hex: 0xFF5D3A))],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String { self == .system ? "Match System" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .dark: "moon"
        case .system: "circle.lefthalf.filled"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
