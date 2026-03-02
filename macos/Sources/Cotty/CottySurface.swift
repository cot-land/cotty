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

    /// Atomically check and clear the render dirty flag.
    /// Returns true if the IO thread produced new content since last check.
    var renderDirty: Bool { cotty_terminal_check_dirty(handle) != 0 }

    /// Check if the child process has exited.
    var childExited: Bool { cotty_terminal_child_exited(handle) != 0 }

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
    /// Each cell = 8 x Int64 (codepoint, fg_type, fg_val, bg_type, bg_val, flags, ul_type, ul_val).
    /// Stride = 64 bytes. Total cells = terminalRows * terminalCols.
    /// Color types: 0=none (use default), 1=palette (val=index), 2=rgb (val=packed).
    var terminalCellsPtr: UnsafeRawPointer? {
        let ptr = cotty_terminal_cells_ptr(handle)
        guard ptr != 0 else { return nil }
        return UnsafeRawPointer(bitPattern: Int(ptr))
    }

    /// Raw pointer to the terminal's 256-color palette (768 i64 values = 256 × 3 RGB).
    var terminalPalettePtr: UnsafeRawPointer? {
        let ptr = cotty_terminal_palette_ptr(handle)
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

    func selectWord(row: Int, col: Int) {
        cotty_terminal_select_word(handle, Int64(row), Int64(col))
    }

    func selectLine(row: Int) {
        cotty_terminal_select_line(handle, Int64(row))
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

    // MARK: - Terminal PWD (OSC 7)

    var terminalPwd: String? {
        let ptr = cotty_terminal_pwd(handle)
        let len = cotty_terminal_pwd_len(handle)
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

    func sendMouseEvent(button: Int64, col: Int, row: Int, pressed: Bool, mods: Int64 = 0) {
        cotty_terminal_mouse_event(handle, button, Int64(col), Int64(row), pressed ? 1 : 0, mods)
    }

    func sendScroll(delta: Int64, precise: Int64, cellHeight: Int64, col: Int, row: Int) {
        cotty_terminal_scroll(handle, delta, precise, cellHeight, Int64(col), Int64(row))
    }

    // MARK: - Terminal Key Input

    func terminalKey(_ key: Int64, mods: Int64) {
        cotty_terminal_key(handle, key, mods)
    }

    func terminalKeyEvent(_ key: Int64, mods: Int64, eventType: Int64) {
        cotty_terminal_key_event(handle, key, mods, eventType)
    }

    var kittyKeyboardFlags: Int64 {
        cotty_terminal_kitty_keyboard(handle)
    }

    // MARK: - Key Translation (macOS keyCode → Cot KEY_* constants)

    /// Translate a macOS NSEvent into abstract (key, mods) for Cot.
    /// Shared by both EditorView and TerminalView.
    static func translateKeyEvent(_ event: NSEvent) -> (key: Int64, mods: Int64) {
        var mods: Int64 = 0
        if event.modifierFlags.contains(.control) { mods |= 1 }  // MOD_CTRL
        if event.modifierFlags.contains(.shift) { mods |= 2 }    // MOD_SHIFT
        if event.modifierFlags.contains(.option) { mods |= 4 }   // MOD_ALT
        if event.modifierFlags.contains(.command) { mods |= 8 }  // MOD_SUPER

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
        case 114: return (276, mods)  // Help/Insert → KEY_INSERT
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
        case 105: return (277, mods)  // F13 → KEY_F13
        case 107: return (278, mods)  // F14 → KEY_F14
        case 113: return (279, mods)  // F15 → KEY_F15
        case 106: return (280, mods)  // F16 → KEY_F16
        case 64:  return (281, mods)  // F17 → KEY_F17
        case 79:  return (282, mods)  // F18 → KEY_F18
        case 80:  return (283, mods)  // F19 → KEY_F19
        case 90:  return (284, mods)  // F20 → KEY_F20
        case 76:  return (285, mods)  // KP Enter → KEY_KP_ENTER
        case 82:  return (286, mods)  // KP 0 → KEY_KP_0
        case 83:  return (287, mods)  // KP 1 → KEY_KP_1
        case 84:  return (288, mods)  // KP 2 → KEY_KP_2
        case 85:  return (289, mods)  // KP 3 → KEY_KP_3
        case 86:  return (290, mods)  // KP 4 → KEY_KP_4
        case 87:  return (291, mods)  // KP 5 → KEY_KP_5
        case 88:  return (292, mods)  // KP 6 → KEY_KP_6
        case 89:  return (293, mods)  // KP 7 → KEY_KP_7
        case 91:  return (294, mods)  // KP 8 → KEY_KP_8
        case 92:  return (295, mods)  // KP 9 → KEY_KP_9
        case 65:  return (296, mods)  // KP . → KEY_KP_DECIMAL
        case 67:  return (297, mods)  // KP * → KEY_KP_MULTIPLY
        case 69:  return (298, mods)  // KP + → KEY_KP_PLUS
        case 75:  return (299, mods)  // KP / → KEY_KP_DIVIDE
        case 78:  return (300, mods)  // KP - → KEY_KP_MINUS
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

    // MARK: - Semantic Prompts (OSC 133)

    func jumpToPreviousPrompt() -> Int {
        Int(cotty_terminal_jump_prev_prompt(handle))
    }

    func jumpToNextPrompt() -> Int {
        Int(cotty_terminal_jump_next_prompt(handle))
    }

    func rowSemantic(_ row: Int) -> Int {
        Int(cotty_terminal_row_semantic(handle, Int64(row)))
    }

    // MARK: - Inspector

    var inspectorActive: Bool { cotty_inspector_active(handle) != 0 }
    var inspectorRows: Int { Int(cotty_inspector_rows(handle)) }
    var inspectorCols: Int { Int(cotty_inspector_cols(handle)) }

    var inspectorCellsPtr: UnsafeRawPointer? {
        let ptr = cotty_inspector_cells_ptr(handle)
        guard ptr != 0 else { return nil }
        return UnsafeRawPointer(bitPattern: Int(ptr))
    }

    func toggleInspector() {
        cotty_inspector_toggle(handle)
    }

    func inspectorSetPanel(_ panel: Int) {
        cotty_inspector_set_panel(handle, Int64(panel))
    }

    func inspectorScroll(delta: Int) {
        cotty_inspector_scroll(handle, Int64(delta))
    }

    var inspectorContentRows: Int {
        Int(cotty_inspector_content_rows(handle))
    }

    var inspectorScrollOffset: Int {
        Int(cotty_inspector_scroll_offset(handle))
    }

    func inspectorSetScroll(offset: Int) {
        cotty_inspector_set_scroll(handle, Int64(offset))
    }

    func inspectorResize(rows: Int, cols: Int) {
        cotty_inspector_resize(handle, Int64(rows), Int64(cols))
    }

    func inspectorRebuildTerminalState() {
        cotty_inspector_rebuild_terminal_state(handle)
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
