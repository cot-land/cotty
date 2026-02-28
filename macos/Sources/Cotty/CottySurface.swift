import AppKit
import CCottyCore
import Foundation

/// Swift wrapper around the opaque cotty_surface_t handle (a stable pointer).
final class CottySurface {
    weak var app: CottyApp?
    let handle: cotty_surface_t

    init(app: CottyApp, handle: cotty_surface_t) {
        self.app = app
        self.handle = handle
    }

    deinit {
        if isTerminal {
            cotty_terminal_surface_free(handle)
        } else {
            cotty_surface_free(handle)
        }
    }

    // MARK: - Input

    func sendKey(_ key: Int64, mods: Int64) {
        cotty_surface_key(handle, key, mods)
    }

    func sendText(_ text: String) {
        text.withCString { cStr in
            cStr.withMemoryRebound(to: UInt8.self, capacity: text.utf8.count) { ptr in
                cotty_surface_text(handle, ptr, Int64(text.utf8.count))
            }
        }
    }

    func loadContent(_ content: String) {
        content.withCString { cStr in
            cStr.withMemoryRebound(to: UInt8.self, capacity: content.utf8.count) { ptr in
                cotty_surface_load_content(handle, ptr, Int64(content.utf8.count))
            }
        }
    }

    // MARK: - Buffer Queries

    var bufferLen: Int { Int(cotty_surface_buffer_len(handle)) }
    var lineCount: Int { Int(cotty_surface_buffer_line_count(handle)) }

    func lineLength(_ line: Int) -> Int {
        Int(cotty_surface_buffer_line_length(handle, Int64(line)))
    }

    func lineStartOffset(_ line: Int) -> Int {
        Int(cotty_surface_buffer_line_start_offset(handle, Int64(line)))
    }

    func charAt(_ pos: Int) -> UInt8 {
        UInt8(cotty_surface_buffer_char_at(handle, Int64(pos)))
    }

    // MARK: - Cursor Queries

    var cursorLine: Int { Int(cotty_surface_cursor_line(handle)) }
    var cursorCol: Int { Int(cotty_surface_cursor_col(handle)) }
    var cursorOffset: Int { Int(cotty_surface_cursor_offset(handle)) }

    // MARK: - State

    var isDirty: Bool { cotty_surface_is_dirty(handle) != 0 }

    func setClean() {
        cotty_surface_set_clean(handle)
    }

    // MARK: - Surface Kind

    var isTerminal: Bool { cotty_surface_kind(handle) == COTTY_SURFACE_TERMINAL }

    // MARK: - Terminal Grid Queries

    var terminalRows: Int { Int(cotty_terminal_rows(handle)) }
    var terminalCols: Int { Int(cotty_terminal_cols(handle)) }

    func cellCodepoint(row: Int, col: Int) -> UInt32 {
        UInt32(cotty_terminal_cell_codepoint(handle, Int64(row), Int64(col)))
    }

    func cellFg(row: Int, col: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let packed = cotty_terminal_cell_fg(handle, Int64(row), Int64(col))
        return (UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF), UInt8(packed & 0xFF))
    }

    func cellBg(row: Int, col: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let packed = cotty_terminal_cell_bg(handle, Int64(row), Int64(col))
        return (UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF), UInt8(packed & 0xFF))
    }

    func cellFlags(row: Int, col: Int) -> Int64 {
        cotty_terminal_cell_flags(handle, Int64(row), Int64(col))
    }

    // MARK: - Terminal Cursor

    var terminalCursorRow: Int { Int(cotty_terminal_cursor_row(handle)) }
    var terminalCursorCol: Int { Int(cotty_terminal_cursor_col(handle)) }
    var terminalCursorVisible: Bool { cotty_terminal_cursor_visible(handle) != 0 }

    // MARK: - Terminal Scrollback

    var scrollbackRows: Int { Int(cotty_terminal_scrollback_rows(handle)) }
    var viewportRow: Int { Int(cotty_terminal_viewport_row(handle)) }

    func setViewport(row: Int) {
        cotty_terminal_set_viewport(handle, Int64(row))
    }

    // MARK: - Terminal Thread Synchronization

    func lockTerminal() { cotty_terminal_lock(handle) }
    func unlockTerminal() { cotty_terminal_unlock(handle) }
    var notifyFd: Int32 { Int32(cotty_terminal_notify_fd(handle)) }

    // MARK: - Terminal I/O

    var ptyFd: Int32 { Int32(cotty_terminal_pty_fd(handle)) }

    func terminalWrite(_ data: Data) {
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            cotty_terminal_write(handle, ptr, Int64(data.count))
        }
    }

    func terminalRead(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        Int(cotty_terminal_read(handle, buffer, Int64(maxLength)))
    }

    func terminalFeed(_ data: UnsafePointer<UInt8>, length: Int) {
        cotty_terminal_feed(handle, data, Int64(length))
    }

    func terminalResize(rows: Int, cols: Int) {
        cotty_terminal_resize(handle, Int64(rows), Int64(cols))
    }

    /// Raw pointer to the contiguous cell buffer.
    /// Each cell = 8 x Int64 (codepoint, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b, flags).
    /// Stride = 64 bytes. Total cells = terminalRows * terminalCols.
    var terminalCellsPtr: UnsafeRawPointer? {
        let ptr = cotty_terminal_cells_ptr(handle)
        guard ptr != 0 else { return nil }
        return UnsafeRawPointer(bitPattern: Int(ptr))
    }

    // MARK: - Terminal Selection

    func selectionStart(row: Int, col: Int) {
        cotty_terminal_selection_start(handle, Int64(row), Int64(col))
    }

    func selectionUpdate(row: Int, col: Int) {
        cotty_terminal_selection_update(handle, Int64(row), Int64(col))
    }

    func selectionClear() {
        cotty_terminal_selection_clear(handle)
    }

    var selectionActive: Bool {
        cotty_terminal_selection_active(handle) != 0
    }

    var selectedText: String? {
        let ptr = cotty_terminal_selected_text(handle)
        let len = cotty_terminal_selected_text_len(handle)
        guard ptr != 0, len > 0 else { return nil }
        let bufPtr = UnsafeRawPointer(bitPattern: Int(ptr))!
        let data = Data(bytes: bufPtr, count: Int(len))
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Terminal Cursor Shape

    var cursorShape: Int { Int(cotty_terminal_cursor_shape(handle)) }

    // MARK: - Terminal Title

    var terminalTitle: String? {
        let ptr = cotty_terminal_title(handle)
        let len = cotty_terminal_title_len(handle)
        guard ptr != 0, len > 0 else { return nil }
        let bufPtr = UnsafeRawPointer(bitPattern: Int(ptr))!
        let data = Data(bytes: bufPtr, count: Int(len))
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Terminal Bell

    var bellPending: Bool { cotty_terminal_bell(handle) != 0 }

    // MARK: - Terminal Modes

    var bracketedPasteMode: Bool { cotty_terminal_bracketed_paste_mode(handle) != 0 }
    var focusEventMode: Bool { cotty_terminal_focus_event_mode(handle) != 0 }

    // MARK: - Mouse Tracking

    var mouseTrackingMode: Int64 { cotty_terminal_mouse_mode(handle) }
    var mouseFormat: Int64 { cotty_terminal_mouse_format(handle) }

    func sendMouseEvent(button: Int64, col: Int, row: Int, pressed: Bool) {
        cotty_terminal_mouse_event(handle, button, Int64(col), Int64(row), pressed ? 1 : 0)
    }

    func sendScroll(delta: Int64, precise: Int64, cellHeight: Int64, col: Int, row: Int) {
        cotty_terminal_scroll(handle, delta, precise, cellHeight, Int64(col), Int64(row))
    }

    // MARK: - Terminal Key Input

    func terminalKey(_ key: Int64, mods: Int64) {
        cotty_terminal_key(handle, key, mods)
    }

    // MARK: - Key Translation (macOS keyCode → Cot KEY_* constants)

    /// Translate a macOS NSEvent into abstract (key, mods) for Cot.
    /// Shared by both EditorView and TerminalView.
    static func translateKeyEvent(_ event: NSEvent) -> (key: Int64, mods: Int64) {
        var mods: Int64 = 0
        if event.modifierFlags.contains(.control) { mods |= 1 }  // MOD_CTRL
        if event.modifierFlags.contains(.shift) { mods |= 2 }    // MOD_SHIFT
        if event.modifierFlags.contains(.option) { mods |= 4 }   // MOD_ALT

        // Special keys → Cot KEY_* constants
        switch event.keyCode {
        case 51:  return (8, mods)    // Backspace → KEY_BACKSPACE
        case 117: return (127, mods)  // Delete → KEY_DELETE
        case 123: return (258, mods)  // Left → KEY_ARROW_LEFT
        case 124: return (259, mods)  // Right → KEY_ARROW_RIGHT
        case 125: return (257, mods)  // Down → KEY_ARROW_DOWN
        case 126: return (256, mods)  // Up → KEY_ARROW_UP
        case 115: return (260, mods)  // Home → KEY_HOME
        case 119: return (261, mods)  // End → KEY_END
        case 116: return (262, mods)  // PageUp → KEY_PAGE_UP
        case 121: return (263, mods)  // PageDown → KEY_PAGE_DOWN
        case 36:  return (13, mods)   // Return → KEY_ENTER
        case 48:  return (9, mods)    // Tab → KEY_TAB
        case 53:  return (27, mods)   // Escape → KEY_ESCAPE
        case 122: return (264, mods)  // F1 → KEY_F1
        case 120: return (265, mods)  // F2 → KEY_F2
        case 99:  return (266, mods)  // F3 → KEY_F3
        case 118: return (267, mods)  // F4 → KEY_F4
        case 96:  return (268, mods)  // F5 → KEY_F5
        case 97:  return (269, mods)  // F6 → KEY_F6
        case 98:  return (270, mods)  // F7 → KEY_F7
        case 100: return (271, mods)  // F8 → KEY_F8
        case 101: return (272, mods)  // F9 → KEY_F9
        case 109: return (273, mods)  // F10 → KEY_F10
        case 103: return (274, mods)  // F11 → KEY_F11
        case 111: return (275, mods)  // F12 → KEY_F12
        default: break
        }

        // Ctrl+key — use the unmodified character so Cot sees the letter
        if mods & 1 != 0, let ch = event.charactersIgnoringModifiers?.unicodeScalars.first {
            return (Int64(ch.value), mods)
        }

        // Printable characters
        if let chars = event.characters, !chars.isEmpty {
            let scalar = chars.unicodeScalars.first!
            if scalar.value >= 32 && scalar.value <= 126 {
                return (Int64(scalar.value), mods)
            }
        }

        return (0, 0)
    }

    // MARK: - Convenience

    var bufferContent: String {
        let len = bufferLen
        var bytes = [UInt8]()
        bytes.reserveCapacity(len)
        for i in 0..<len {
            bytes.append(charAt(i))
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
