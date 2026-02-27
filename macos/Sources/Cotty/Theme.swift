import AppKit
import CoreText

struct Theme {
    // Font — matches Ghostty config
    static let fontName = "JetBrains Mono"
    static let fontSize: CGFloat = 18

    // Monokai Remastered
    static let bgR: Double = 0x0D / 255.0
    static let bgG: Double = 0x0D / 255.0
    static let bgB: Double = 0x0D / 255.0
    static let background = NSColor(red: bgR, green: bgG, blue: bgB, alpha: 1)

    static let fgR: UInt8 = 0xD9
    static let fgG: UInt8 = 0xD9
    static let fgB: UInt8 = 0xD9

    static let cursorR: UInt8 = 0xFD
    static let cursorG: UInt8 = 0x97
    static let cursorB: UInt8 = 0x1F

    // Selection (Monokai)
    static let selR: UInt8 = 0x44
    static let selG: UInt8 = 0x47
    static let selB: UInt8 = 0x5A
    static let selA: UInt8 = 0xA0

    // Layout
    static let paddingPoints: CGFloat = 8
    static let blinkInterval: TimeInterval = 0.5
}
