import CCottyCore
import Foundation

/// Swift wrapper around the opaque cotty_surface_t handle (a surface index).
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
