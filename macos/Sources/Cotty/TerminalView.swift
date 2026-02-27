import AppKit
import CCottyCore
import Foundation  // for Data
import Metal
import QuartzCore

/// NSView for terminal surfaces — renders the terminal grid via Metal and
/// bridges keyboard input to the PTY.
///
/// Shell spawning uses Swift's forkpty() (fork-safe in GUI apps). PTY output
/// is fed through Cot's VT parser (cotty_terminal_feed) for terminal state
/// updates, then rendered via Metal from the Cot cell grid.
class TerminalView: NSView {
    let surface: CottySurface
    weak var windowController: TerminalWindowController?

    // Metal
    private static let metalDevice = MTLCreateSystemDefaultDevice()!
    private var renderer: MetalRenderer!
    private let metalView: MetalLayerView

    // PTY I/O — spawned from Swift side via forkpty()
    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
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
        if masterFd >= 0 { close(masterFd) }
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
        spawnShell()
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

    // MARK: - Shell Spawning (Swift-side forkpty)

    private func spawnShell() {
        let rows = surface.terminalRows
        let cols = surface.terminalCols
        guard rows > 0 && cols > 0 else { return }

        var master: Int32 = -1
        var winSize = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let pid = forkpty(&master, nil, nil, &winSize)
        if pid < 0 { return }

        if pid == 0 {
            // Child process — exec the shell
            let shell = "/bin/zsh"
            shell.withCString { path in
                let argv: [UnsafeMutablePointer<CChar>?] = [
                    strdup(path),
                    nil
                ]
                execvp(path, argv)
                _exit(127)
            }
        }

        // Parent
        masterFd = master
        childPid = pid

        // Set non-blocking
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        startPtyMonitor()
    }

    // MARK: - PTY Monitoring

    private func startPtyMonitor() {
        guard masterFd >= 0 else { return }

        let fd = masterFd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readPty()
        }
        source.setCancelHandler { /* fd closed in deinit */ }
        source.resume()
        readSource = source
    }

    private func readPty() {
        while true {
            let n = Darwin.read(masterFd, readBuffer, 4096)
            if n <= 0 { break }
            // Feed multi-byte chunk through Cot VT parser.
            // The *Cell heap corruption bug is fixed (ARC managed flag),
            // so Cot-side loops over cells are safe now.
            surface.terminalFeed(readBuffer, length: n)
        }
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
        // Write directly to the PTY master fd
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            _ = Darwin.write(masterFd, ptr, data.count)
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
