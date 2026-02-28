import AppKit
import CCottyCore
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
        resizeTerminalGrid(bounds.size)
        startPtyMonitor()
        startBlinkTimer()
        renderFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeTerminalGrid(newSize)
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

    private func resizeTerminalGrid(_ size: NSSize) {
        guard renderer != nil else { return }
        let pad = Theme.shared.paddingPoints
        let newCols = max(2, Int((size.width - 2 * pad) / renderer.cellWidthPoints))
        let newRows = max(2, Int((size.height - 2 * pad) / renderer.cellHeightPoints))
        if newRows != surface.terminalRows || newCols != surface.terminalCols {
            surface.terminalResize(rows: newRows, cols: newCols)
        }
    }

    // MARK: - PTY Monitoring (fd owned by Cot's Pty struct)

    private func startPtyMonitor() {
        let fd = surface.ptyFd
        guard fd >= 0 else { return }
        // Compiler workaround: Cot's set_nonblocking may not work in dylib mode,
        // so we ensure O_NONBLOCK from Swift. The DispatchSource I/O monitoring
        // itself is platform-specific and correctly lives here.
        let flags = fcntl(fd, F_GETFL)
        fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readPty()
        }
        source.setCancelHandler { /* fd closed in deinit */ }
        source.resume()
        readSource = source
    }

    private func readPty() {
        let fd = surface.ptyFd
        while true {
            let n = Darwin.read(fd, readBuffer, 4096)
            if n <= 0 { break }
            for i in 0..<n {
                cotty_terminal_feed_byte(surface.handle, Int64(readBuffer[i]))
            }
        }
        renderFrame()
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard renderer != nil else { return }
        renderer.renderTerminal(
            layer: metalView.metalLayer,
            surface: surface,
            cursorVisible: cursorVisible && surface.terminalCursorVisible
        )
    }

    // MARK: - Mouse Selection

    private func gridPosition(from event: NSEvent) -> (row: Int, col: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let pad = Theme.shared.paddingPoints
        let col = Int((point.x - pad) / renderer.cellWidthPoints)
        let row = Int((point.y - pad) / renderer.cellHeightPoints)
        let clampedRow = max(0, min(row, surface.terminalRows - 1))
        let clampedCol = max(0, min(col, surface.terminalCols - 1))
        return (clampedRow, clampedCol)
    }

    override func mouseDown(with event: NSEvent) {
        let pos = gridPosition(from: event)
        surface.selectionStart(row: pos.row, col: pos.col)
        renderFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        let pos = gridPosition(from: event)
        surface.selectionUpdate(row: pos.row, col: pos.col)
        renderFrame()
    }

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        // Cmd+C → copy selection to clipboard
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            if surface.selectionActive, let text = surface.selectedText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                surface.selectionClear()
                renderFrame()
                return
            }
        }

        // Let Cmd+key combos through to the menu responder chain
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        // Clear selection when typing
        if surface.selectionActive {
            surface.selectionClear()
            renderFrame()
        }

        let (key, mods) = CottySurface.translateKeyEvent(event)
        guard key != 0 else { return }
        surface.terminalKey(key, mods: mods)
        resetCursorBlink()
    }

    // MARK: - Cursor Blink

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: Theme.shared.blinkInterval, repeats: true) { [weak self] _ in
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
