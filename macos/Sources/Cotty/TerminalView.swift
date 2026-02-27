import AppKit
import CCottyCore
import Foundation  // for Data
import Metal
import QuartzCore

/// NSView for terminal surfaces — renders the terminal grid via Metal and
/// bridges keyboard input to the PTY.
///
/// Shell is spawned by Cot's Pty.spawn() (in surface.cot). Swift monitors
/// the PTY fd for output, feeds bytes through Cot's VT parser
/// (cotty_terminal_feed), and renders the cell grid via Metal.
class TerminalView: NSView {
    let surface: CottySurface
    weak var windowController: TerminalWindowController?

    // Metal
    private static let metalDevice = MTLCreateSystemDefaultDevice()!
    private var renderer: MetalRenderer!
    private let metalView: MetalLayerView

    // PTY I/O — fd owned by Cot's Pty struct
    private var readSource: DispatchSourceRead?
    private let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)

    // Cursor blink
    private var cursorVisible = true
    private var blinkTimer: Timer?

    // MARK: - NSView Setup

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, surface: CottySurface) {
        self.surface = surface
        metalView = MetalLayerView(frame: frame, device: Self.metalDevice)
        super.init(frame: frame)
        renderer = MetalRenderer(device: Self.metalDevice)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        readSource?.cancel()
        readBuffer.deallocate()
        blinkTimer?.invalidate()
    }

    private func setupViews() {
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        metalView.metalLayer.contentsScale = window.backingScaleFactor
        updateDrawableSize()
        startPtyMonitor()
        startBlinkTimer()
        renderFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        renderFrame()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalView.metalLayer.contentsScale = scale
        metalView.metalLayer.drawableSize = CGSize(
            width: metalView.bounds.width * scale,
            height: metalView.bounds.height * scale
        )
    }

    // MARK: - PTY Monitoring (fd owned by Cot's Pty struct)

    private func startPtyMonitor() {
        let fd = surface.ptyFd
        fputs("[TerminalView] ptyFd=\(fd) rows=\(surface.terminalRows) cols=\(surface.terminalCols)\n", stderr)
        guard fd >= 0 else {
            fputs("[TerminalView] ERROR: ptyFd < 0, Pty.spawn() failed\n", stderr)
            return
        }
        // Ensure non-blocking (Cot's set_nonblocking may not work in dylib mode)
        let flags = fcntl(fd, F_GETFL)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        fputs("[TerminalView] set nonblocking: flags=\(flags) -> \(flags | O_NONBLOCK)\n", stderr)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            fputs("[TerminalView] dispatch source fired\n", stderr)
            self?.readPty()
        }
        source.setCancelHandler { /* fd closed in deinit */ }
        source.resume()
        readSource = source
        fputs("[TerminalView] dispatch source resumed on fd=\(fd)\n", stderr)
    }

    private func readPty() {
        fputs("[readPty] ENTER fd=\(surface.ptyFd) handle=\(surface.handle)\n", stderr)
        let fd = surface.ptyFd
        var totalBytes = 0
        while true {
            let n = Darwin.read(fd, readBuffer, 4096)
            fputs("[readPty] read returned \(n)\n", stderr)
            if n <= 0 { break }
            totalBytes += n
            for i in 0..<n {
                cotty_terminal_feed_byte(surface.handle, Int64(readBuffer[i]))
            }
            fputs("[readPty] fed \(n) bytes OK\n", stderr)
        }
        fputs("[readPty] total=\(totalBytes) cursor=(\(surface.terminalCursorRow),\(surface.terminalCursorCol))\n", stderr)
        renderFrame()
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard renderer != nil else { return }
        renderer.renderTerminal(
            layer: metalView.metalLayer,
            surface: surface,
            cursorVisible: cursorVisible
        )
    }

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        // Let Cmd+key combos through to the menu responder chain
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        let data = translateKeyToBytes(event)
        guard !data.isEmpty else { return }
        let fd = surface.ptyFd
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = Darwin.write(fd, ptr, data.count)
        }
        resetCursorBlink()
    }

    /// Translate a key event to the bytes the terminal expects.
    private func translateKeyToBytes(_ event: NSEvent) -> Data {
        let ctrl = event.modifierFlags.contains(.control)

        // Special keys → escape sequences
        switch event.keyCode {
        case 36:  return Data([0x0D])           // Return
        case 48:  return Data([0x09])           // Tab
        case 51:  return Data([0x7F])           // Backspace → DEL
        case 117: return Data([0x1B, 0x5B, 0x33, 0x7E]) // Delete → ESC[3~
        case 126: return Data([0x1B, 0x5B, 0x41]) // Up → ESC[A
        case 125: return Data([0x1B, 0x5B, 0x42]) // Down → ESC[B
        case 124: return Data([0x1B, 0x5B, 0x43]) // Right → ESC[C
        case 123: return Data([0x1B, 0x5B, 0x44]) // Left → ESC[D
        case 115: return Data([0x1B, 0x5B, 0x48]) // Home → ESC[H
        case 119: return Data([0x1B, 0x5B, 0x46]) // End → ESC[F
        case 116: return Data([0x1B, 0x5B, 0x35, 0x7E]) // PageUp → ESC[5~
        case 121: return Data([0x1B, 0x5B, 0x36, 0x7E]) // PageDown → ESC[6~
        case 53:  return Data([0x1B])           // Escape
        default: break
        }

        // Ctrl+key → control character (0x01-0x1A)
        if ctrl, let ch = event.charactersIgnoringModifiers?.lowercased().first {
            let val = ch.asciiValue ?? 0
            if val >= 0x61 && val <= 0x7A { // a-z
                return Data([val - 0x60])
            }
        }

        // Printable characters → UTF-8 bytes
        if let chars = event.characters, !chars.isEmpty {
            return Data(chars.utf8)
        }

        return Data()
    }

    // MARK: - Cursor Blink

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Theme.blinkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorVisible.toggle()
            self.renderFrame()
        }
    }

    private func resetCursorBlink() {
        cursorVisible = true
        startBlinkTimer()
    }
}

// MARK: - MetalLayerView (shared with EditorView)

/// CAMetalLayer-backed view for GPU rendering. Passes mouse events through.
private class MetalLayerView: NSView {
    let device: MTLDevice

    override var isFlipped: Bool { true }

    init(frame: NSRect, device: MTLDevice) {
        self.device = device
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        return layer
    }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
