import CCottyCore

/// Swift wrapper around the opaque cotty_surface_t handle (a surface index).
final class CottySurface {
    weak var app: CottyApp?
    let handle: cotty_surface_t

    init(app: CottyApp, handle: cotty_surface_t) {
        self.app = app
        self.handle = handle
    }

    deinit {
        cotty_surface_free(handle)
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
