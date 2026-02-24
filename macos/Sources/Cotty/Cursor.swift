/// Cursor position tracking for an editor surface.
/// Direct Swift translation of src/cursor.cot.
/// Will be replaced by Cot core via Wasm FFI once compiler bugs are fixed.
struct Cursor {
    var line: Int
    var col: Int
    var offset: Int

    /// Create a cursor at the start of the buffer.
    init() {
        line = 0
        col = 0
        offset = 0
    }

    /// Move cursor one position to the right.
    mutating func moveRight(bufLen: Int) {
        if offset < bufLen {
            offset += 1
            col += 1
        }
    }

    /// Move cursor one position to the left.
    mutating func moveLeft() {
        if offset > 0 {
            offset -= 1
            if col > 0 {
                col -= 1
            }
        }
    }

    /// Move cursor up one line.
    mutating func moveUp() {
        if line > 0 {
            line -= 1
        }
    }

    /// Move cursor down one line.
    mutating func moveDown(totalLines: Int) {
        if line < totalLines - 1 {
            line += 1
        }
    }

    /// Move cursor to the start of the current line.
    mutating func moveToLineStart() {
        col = 0
    }

    /// Move cursor to a specific position.
    mutating func moveTo(line: Int, col: Int, offset: Int) {
        self.line = line
        self.col = col
        self.offset = offset
    }
}
