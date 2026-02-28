import AppKit
import CCottyCore
import CoreText

class Theme {
    static let shared = Theme()

    // Font
    var fontName: String = "JetBrains Mono"
    var fontSize: CGFloat = 18

    // Background
    var bgR: Double = 0x0C / 255.0
    var bgG: Double = 0x0C / 255.0
    var bgB: Double = 0x0C / 255.0
    var background: NSColor = NSColor(red: 0x0C / 255.0, green: 0x0C / 255.0, blue: 0x0C / 255.0, alpha: 1)

    // Foreground
    var fgR: UInt8 = 0xD9
    var fgG: UInt8 = 0xD9
    var fgB: UInt8 = 0xD9

    // Cursor
    var cursorR: UInt8 = 0xFC
    var cursorG: UInt8 = 0x97
    var cursorB: UInt8 = 0x1F

    // Selection
    var selR: UInt8 = 0x34
    var selG: UInt8 = 0x34
    var selB: UInt8 = 0x34
    var selA: UInt8 = 0xFF

    // Layout
    var paddingPoints: CGFloat = 8
    let blinkInterval: TimeInterval = 0.5

    /// Load theme values from Cot config via FFI.
    /// Must be called after cotty_app_new().
    func load() {
        // Font name from Cot string pointer + length
        let namePtr = cotty_config_font_name()
        let nameLen = cotty_config_font_name_len()
        if namePtr != 0 && nameLen > 0 {
            if let ptr = UnsafeRawPointer(bitPattern: Int(namePtr)) {
                let data = Data(bytes: ptr, count: Int(nameLen))
                if let name = String(data: data, encoding: .utf8) {
                    fontName = name
                }
            }
        }

        fontSize = CGFloat(cotty_config_font_size())
        paddingPoints = CGFloat(cotty_config_padding())

        // Background
        let bgRi = cotty_config_bg_r()
        let bgGi = cotty_config_bg_g()
        let bgBi = cotty_config_bg_b()
        bgR = Double(bgRi) / 255.0
        bgG = Double(bgGi) / 255.0
        bgB = Double(bgBi) / 255.0
        background = NSColor(red: bgR, green: bgG, blue: bgB, alpha: 1)

        // Foreground
        fgR = UInt8(clamping: cotty_config_fg_r())
        fgG = UInt8(clamping: cotty_config_fg_g())
        fgB = UInt8(clamping: cotty_config_fg_b())

        // Cursor
        cursorR = UInt8(clamping: cotty_config_cursor_r())
        cursorG = UInt8(clamping: cotty_config_cursor_g())
        cursorB = UInt8(clamping: cotty_config_cursor_b())

        // Selection
        selR = UInt8(clamping: cotty_config_sel_bg_r())
        selG = UInt8(clamping: cotty_config_sel_bg_g())
        selB = UInt8(clamping: cotty_config_sel_bg_b())
    }
}
