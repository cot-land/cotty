import AppKit
import CCottyCore
import Metal
import QuartzCore

/// NSView for terminal surfaces — renders the terminal grid via Metal and
/// bridges keyboard input to the PTY.
///
/// Shell is spawned by Cot's Pty.spawn() (in surface.cot). A Cot IO thread
/// reads PTY output and feeds bytes through the VT parser. Swift monitors
/// a notification pipe for render signals and reads the cell grid under mutex.
class TerminalView: NSView {
    let surface: CottySurface
    weak var windowController: TerminalWindowController?

    // Metal
    private static let metalDevice = MTLCreateSystemDefaultDevice()!
    private var renderer: MetalRenderer!
    private let metalView: MetalLayerView

    // Notification pipe — IO thread signals when new content is available
    private var notifySource: DispatchSourceRead?
    private let notifyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)

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
        notifySource?.cancel()
        notifyBuffer.deallocate()
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
        startNotifyMonitor()
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
            surface.lockTerminal()
            surface.terminalResize(rows: newRows, cols: newCols)
            cotty_inspector_resize(Int64(newCols))
            surface.unlockTerminal()
        }
    }

    // MARK: - Notification Pipe Monitoring

    /// Monitor the notification pipe from the IO reader thread.
    /// When the IO thread finishes a VT parse batch, it writes to the pipe.
    /// We drain the pipe and re-render under lock.
    private func startNotifyMonitor() {
        let fd = surface.notifyFd
        guard fd >= 0 else { return }
        // Set notify pipe read end to non-blocking so we can drain it
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Drain the pipe (just a signal, content doesn't matter)
            while Darwin.read(fd, self.notifyBuffer, 1024) > 0 {}
            self.renderFrame()
        }
        source.setCancelHandler { /* pipe closed by cotty_terminal_surface_free */ }
        source.resume()
        notifySource = source
    }

    // MARK: - Rendering

    private func renderFrame() {
        guard renderer != nil else { return }
        surface.lockTerminal()
        renderer.renderTerminal(
            layer: metalView.metalLayer,
            surface: surface,
            cursorVisible: cursorVisible && surface.terminalCursorVisible,
            inspectorActive: cotty_inspector_active() != 0
        )
        surface.unlockTerminal()
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
        surface.lockTerminal()
        if surface.mouseTrackingMode != 0 {
            // 1-indexed for SGR mouse protocol
            surface.sendMouseEvent(button: 0, col: pos.col + 1, row: pos.row + 1, pressed: true)
            surface.unlockTerminal()
            return
        }
        surface.selectionStart(row: pos.row, col: pos.col)
        surface.unlockTerminal()
        renderFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        let pos = gridPosition(from: event)
        surface.lockTerminal()
        if surface.mouseTrackingMode >= 1002 {
            // Button-event or any-event tracking: report motion with button 32 (drag)
            surface.sendMouseEvent(button: 32, col: pos.col + 1, row: pos.row + 1, pressed: true)
            surface.unlockTerminal()
            return
        }
        if surface.mouseTrackingMode != 0 {
            surface.unlockTerminal()
            return  // mode 1000 doesn't report drag
        }
        surface.selectionUpdate(row: pos.row, col: pos.col)
        surface.unlockTerminal()
        renderFrame()
    }

    override func mouseUp(with event: NSEvent) {
        let pos = gridPosition(from: event)
        surface.lockTerminal()
        if surface.mouseTrackingMode != 0 {
            surface.sendMouseEvent(button: 0, col: pos.col + 1, row: pos.row + 1, pressed: false)
            surface.unlockTerminal()
            return
        }
        surface.unlockTerminal()
    }

    override func scrollWheel(with event: NSEvent) {
        // Ghostty: SurfaceView_AppKit.swift scrollWheel — thin platform forwarder
        let pos = gridPosition(from: event)
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { y *= 2 }  // Ghostty's 2x precision multiplier
        let delta = Int64(y * 1000)
        let cellH = Int64(renderer.cellHeightPoints * 1000)
        surface.lockTerminal()
        surface.sendScroll(delta: delta, precise: precise ? 1 : 0, cellHeight: cellH, col: pos.col + 1, row: pos.row + 1)
        surface.unlockTerminal()
        renderFrame()
    }

    // MARK: - Inspector

    func toggleInspector() {
        surface.lockTerminal()
        cotty_inspector_toggle(surface.handle)
        surface.unlockTerminal()
        renderFrame()
    }

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        // Cmd+C → copy selection to clipboard
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            surface.lockTerminal()
            let hasSelection = surface.selectionActive
            let text = hasSelection ? surface.selectedText : nil
            if hasSelection {
                surface.selectionClear()
            }
            surface.unlockTerminal()
            if let text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
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
        surface.lockTerminal()
        if surface.selectionActive {
            surface.selectionClear()
        }
        surface.unlockTerminal()

        let (key, mods) = CottySurface.translateKeyEvent(event)
        guard key != 0 else { return }
        // terminalKey writes to PTY fd (thread-safe) and reads mode_app_cursor
        surface.lockTerminal()
        surface.terminalKey(key, mods: mods)
        surface.unlockTerminal()
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
