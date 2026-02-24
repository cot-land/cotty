import Foundation

/// Gap buffer for text storage.
/// Direct Swift translation of src/buffer.cot — same data structure, same algorithms.
/// Will be replaced by Cot core via Wasm FFI once compiler bugs are fixed.
struct GapBuffer {
    private static let initialGapSize = 64

    private var data: [UInt8]
    private(set) var gapStart: Int
    private(set) var gapEnd: Int

    /// Create an empty buffer with an initial gap.
    init() {
        data = [UInt8](repeating: 0, count: Self.initialGapSize)
        gapStart = 0
        gapEnd = Self.initialGapSize
    }

    /// Create a buffer initialized with content.
    init(content: String) {
        self.init()
        for byte in content.utf8 {
            insert(byte)
        }
    }

    /// Number of actual characters in the buffer (excluding the gap).
    var len: Int {
        data.count - (gapEnd - gapStart)
    }

    /// Size of the current gap.
    var gapSize: Int {
        gapEnd - gapStart
    }

    /// Insert a byte at the current gap position.
    mutating func insert(_ ch: UInt8) {
        if gapStart == gapEnd {
            growGap()
        }
        data[gapStart] = ch
        gapStart += 1
    }

    /// Delete one byte before the gap (backspace).
    mutating func deleteBack() {
        if gapStart > 0 {
            gapStart -= 1
        }
    }

    /// Delete one byte after the gap (delete key).
    mutating func deleteForward() {
        if gapEnd < data.count {
            gapEnd += 1
        }
    }

    /// Move the gap to a specific position in the logical text.
    mutating func moveGapTo(_ pos: Int) {
        if pos == gapStart { return }

        if pos < gapStart {
            // Move gap left: shift bytes from [pos, gapStart) to after gap
            let shift = gapStart - pos
            for i in 0..<shift {
                data[gapEnd - shift + i] = data[pos + i]
            }
            gapStart = pos
            gapEnd -= shift
        } else {
            // Move gap right: shift bytes from [gapEnd, gapEnd + (pos - gapStart)) to before gap
            let shift = pos - gapStart
            for i in 0..<shift {
                data[gapStart + i] = data[gapEnd + i]
            }
            gapStart += shift
            gapEnd += shift
        }
    }

    /// Get the byte at a logical position (accounting for the gap).
    func charAt(_ pos: Int) -> UInt8 {
        if pos < gapStart {
            return data[pos]
        }
        return data[pos + gapSize]
    }

    /// Count the number of lines in the buffer.
    func lineCount() -> Int {
        var count = 1
        for i in 0..<len {
            if charAt(i) == UInt8(ascii: "\n") {
                count += 1
            }
        }
        return count
    }

    /// Get the content of a specific line (0-indexed). Returns the line without newline.
    func lineAt(_ lineNum: Int) -> String {
        var currentLine = 0
        var lineStart = 0
        var i = 0
        let textLen = len

        // Find the start of the requested line
        while i < textLen && currentLine < lineNum {
            if charAt(i) == UInt8(ascii: "\n") {
                currentLine += 1
                lineStart = i + 1
            }
            i += 1
        }

        if currentLine != lineNum {
            return ""
        }

        // Find the end of the line
        var lineEnd = lineStart
        while lineEnd < textLen {
            if charAt(lineEnd) == UInt8(ascii: "\n") { break }
            lineEnd += 1
        }

        // Build the line string
        var bytes = [UInt8]()
        bytes.reserveCapacity(lineEnd - lineStart)
        for j in lineStart..<lineEnd {
            bytes.append(charAt(j))
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Get the length of a specific line (0-indexed), not including newline.
    func lineLength(_ lineNum: Int) -> Int {
        var currentLine = 0
        var lineStart = 0
        var i = 0
        let textLen = len

        while i < textLen && currentLine < lineNum {
            if charAt(i) == UInt8(ascii: "\n") {
                currentLine += 1
                lineStart = i + 1
            }
            i += 1
        }

        if currentLine != lineNum {
            return 0
        }

        var lineEnd = lineStart
        while lineEnd < textLen {
            if charAt(lineEnd) == UInt8(ascii: "\n") { break }
            lineEnd += 1
        }
        return lineEnd - lineStart
    }

    /// Get the byte offset of the start of a specific line (0-indexed).
    func lineStartOffset(_ lineNum: Int) -> Int {
        if lineNum == 0 { return 0 }

        var currentLine = 0
        for i in 0..<len {
            if charAt(i) == UInt8(ascii: "\n") {
                currentLine += 1
                if currentLine == lineNum {
                    return i + 1
                }
            }
        }
        return len
    }

    /// Convert the entire buffer to a string.
    func toString() -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(len)
        for i in 0..<len {
            bytes.append(charAt(i))
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Grow the gap when it's full. Doubles the gap size.
    private mutating func growGap() {
        let oldGapSize = gapSize
        let newGapSize = oldGapSize > 0 ? oldGapSize * 2 : Self.initialGapSize

        // Extend the array
        data.append(contentsOf: [UInt8](repeating: 0, count: newGapSize))

        // Shift bytes after the gap to make room
        let bytesAfterGap = data.count - newGapSize - gapEnd
        if bytesAfterGap > 0 {
            for j in stride(from: bytesAfterGap - 1, through: 0, by: -1) {
                data[gapEnd + newGapSize + j] = data[gapEnd + j]
            }
        }

        gapEnd += newGapSize
    }
}
