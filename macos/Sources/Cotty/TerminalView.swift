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
///
/// Uses standard macOS coordinates (y=0 at bottom) — no isFlipped, matching Ghostty.
class TerminalView: NSView {
    let surface: CottySurface
    weak var windowController: TerminalWindowController?

    // Metal
    private static let metalDevice = MTLCreateSystemDefaultDevice()!
    private(set) var renderer: MetalRenderer!
    private let metalView: MetalLayerView

    // Notification pipe — IO thread signals when new content is available
    private var notifySource: DispatchSourceRead?
    private let notifyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)

    // Scrollbar — transparent NSScrollView overlay (same pattern as EditorView)
    private let scrollView = TrackingScrollView()
    private let sizerView = TerminalSizerView()
    private var ignoreScrollUpdate = false

    // Cursor blink
    private var cursorVisible = true
    private var blinkTimer: Timer?

    // MARK: - NSView Setup

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

        // Transparent scroll view on top — provides native scrollbar
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasHorizontalScroller = false

        // Use standard (non-flipped) clip view
        let clipView = scrollView.contentView
        clipView.drawsBackground = false

        sizerView.terminalView = self
        sizerView.frame = bounds
        scrollView.documentView = sizerView

        addSubview(scrollView)

        // Observe scroll position changes from the clip view
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
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

        // Check cursor shape for blink behavior
        let shape = surface.cursorShape
        let isBlinkingShape = shape == 0 || shape == 1 || shape == 3 || shape == 5
        let effectiveCursorVisible = (isBlinkingShape ? cursorVisible : true) && surface.terminalCursorVisible

        renderer.renderTerminal(
            layer: metalView.metalLayer,
            surface: surface,
            cursorVisible: effectiveCursorVisible,
            cursorShape: shape
        )

        // Read bell state
        let bellPending = surface.bellPending

        // Read title and PWD
        let title = surface.terminalTitle
        let pwd = surface.terminalPwd

        let scrollback = surface.scrollbackRows
        let rows = surface.terminalRows
        let viewportRow = surface.viewportRow
        surface.unlockTerminal()

        // Handle bell
        if bellPending {
            NSApp.requestUserAttention(.informationalRequest)
        }

        // Update window title
        if let title {
            windowController?.window?.title = title
        }

        // Update proxy icon (folder icon in titlebar) from OSC 7 PWD
        if let pwd, let url = URL(string: pwd) {
            windowController?.window?.representedURL = url
        }

        updateScrollbar(scrollbackRows: scrollback, visibleRows: rows, viewportRow: viewportRow)

        // Notify inspector to re-render
        windowController?.notifyInspectorRender()
    }

    // MARK: - Scrollbar

    /// Update the sizer view height and scroll position to reflect scrollback state.
    /// Non-flipped: y=0 is bottom of document. Active area at bottom, scrollback at top.
    private func updateScrollbar(scrollbackRows: Int, visibleRows: Int, viewportRow: Int) {
        guard renderer != nil else { return }
        let cellH = renderer.cellHeightPoints
        let visibleHeight = scrollView.contentView.bounds.height
        let totalRows = scrollbackRows + visibleRows
        let contentHeight = CGFloat(totalRows) * cellH

        // Update sizer to represent total content
        let sizerHeight = max(contentHeight, visibleHeight)
        if abs(sizerView.frame.height - sizerHeight) > 1 {
            sizerView.frame = NSRect(
                x: 0, y: 0,
                width: scrollView.contentView.bounds.width,
                height: sizerHeight
            )
        }

        // Non-flipped scroll mapping:
        // viewportRow=-1 (bottom/active) → targetY = 0 (bottom of document)
        // viewportRow=0 (oldest scrollback) → targetY = sizerHeight - visibleHeight (top)
        let targetY: CGFloat
        if viewportRow < 0 {
            targetY = 0
        } else {
            targetY = max(0, sizerHeight - visibleHeight - CGFloat(viewportRow) * cellH)
        }

        let currentY = scrollView.contentView.bounds.origin.y
        if abs(currentY - targetY) > 1 {
            ignoreScrollUpdate = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            ignoreScrollUpdate = false
        }
    }

    /// When the user drags the scrollbar, map scroll position to viewport row.
    /// Non-flipped: scrollY=0 → bottom (active), scrollY=max → top (oldest scrollback).
    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard !ignoreScrollUpdate else { return }
        guard renderer != nil else { return }

        let scrollY = scrollView.contentView.bounds.origin.y
        let cellH = renderer.cellHeightPoints
        guard cellH > 0 else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        let sizerHeight = sizerView.frame.height

        // Map scroll position to viewport row
        let row = Int((sizerHeight - visibleHeight - scrollY) / cellH)

        surface.lockTerminal()
        let scrollback = surface.scrollbackRows
        if row >= scrollback {
            surface.setViewport(row: -1)
        } else {
            surface.setViewport(row: max(0, row))
        }
        surface.unlockTerminal()
        renderFrame()
    }

    // MARK: - Mouse Selection

    /// Convert mouse event to grid (row, col). Non-flipped: y=0 at bottom, row 0 at top.
    private func gridPosition(from event: NSEvent) -> (row: Int, col: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let pad = Theme.shared.paddingPoints
        let col = Int((point.x - pad) / renderer.cellWidthPoints)
        // Non-flipped: flip Y so row 0 is at the top of the view
        let row = Int((bounds.height - point.y - pad) / renderer.cellHeightPoints)
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
        switch event.clickCount {
        case 2:
            surface.selectWord(row: pos.row, col: pos.col)
        case 3:
            surface.selectLine(row: pos.row)
        default:
            surface.selectionStart(row: pos.row, col: pos.col)
        }
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

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        // Cmd+V → paste from clipboard
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            guard let pasteString = NSPasteboard.general.string(forType: .string) else { return }
            // Replace \n with \r for terminal input
            let termString = pasteString.replacingOccurrences(of: "\n", with: "\r")
            surface.lockTerminal()
            let bracketed = surface.bracketedPasteMode
            surface.unlockTerminal()
            if bracketed {
                // Bracketed paste: ESC[200~ content ESC[201~
                if let data = "\u{1b}[200~".data(using: .utf8) {
                    surface.terminalWrite(data)
                }
                if let data = termString.data(using: .utf8) {
                    surface.terminalWrite(data)
                }
                if let data = "\u{1b}[201~".data(using: .utf8) {
                    surface.terminalWrite(data)
                }
            } else {
                if let data = termString.data(using: .utf8) {
                    surface.terminalWrite(data)
                }
            }
            return
        }

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

        // Cmd+Up → jump to previous prompt (OSC 133)
        if event.modifierFlags.contains(.command) && event.keyCode == 126 {
            surface.lockTerminal()
            let _ = surface.jumpToPreviousPrompt()
            surface.unlockTerminal()
            renderFrame()
            return
        }

        // Cmd+Down → jump to next prompt (OSC 133)
        if event.modifierFlags.contains(.command) && event.keyCode == 125 {
            surface.lockTerminal()
            let _ = surface.jumpToNextPrompt()
            surface.unlockTerminal()
            renderFrame()
            return
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
        // Route through Kitty-aware encoder (falls back to legacy when no flags)
        surface.lockTerminal()
        surface.terminalKeyEvent(key, mods: mods, eventType: 0)  // 0 = press
        surface.unlockTerminal()
        resetCursorBlink()
    }

    override func keyUp(with event: NSEvent) {
        // Only send keyUp when Kitty report_events (bit 1) is active
        surface.lockTerminal()
        let kittyFlags = surface.kittyKeyboardFlags
        surface.unlockTerminal()
        guard kittyFlags & 2 != 0 else { return }

        let (key, mods) = CottySurface.translateKeyEvent(event)
        guard key != 0 else { return }
        surface.lockTerminal()
        surface.terminalKeyEvent(key, mods: mods, eventType: 2)  // 2 = release
        surface.unlockTerminal()
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier key press/release for Kitty protocol
        surface.lockTerminal()
        let kittyFlags = surface.kittyKeyboardFlags
        surface.unlockTerminal()
        guard kittyFlags & 2 != 0 else { return }

        // Map modifier key to KEY_* constant
        // macOS keyCodes: 56=LShift, 60=RShift, 59=LCtrl, 62=RCtrl,
        //                 58=LAlt, 61=RAlt, 55=LCmd, 54=RCmd
        // We send these as the modifier key itself — Kitty uses special codepoints
        // but for now we just need the event flow; apps that care will use the mods
    }

    // MARK: - Focus Events

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            surface.lockTerminal()
            let focusMode = surface.focusEventMode
            surface.unlockTerminal()
            if focusMode {
                if let data = "\u{1b}[I".data(using: .utf8) {
                    surface.terminalWrite(data)
                }
            }
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            surface.lockTerminal()
            let focusMode = surface.focusEventMode
            surface.unlockTerminal()
            if focusMode {
                if let data = "\u{1b}[O".data(using: .utf8) {
                    surface.terminalWrite(data)
                }
            }
        }
        return result
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

// MARK: - Helper Views

/// Transparent document view that provides content height for the scrollbar.
/// Forwards mouse events through to the terminal view.
private class TerminalSizerView: NSView {
    weak var terminalView: TerminalView?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(terminalView)
        terminalView?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        terminalView?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        terminalView?.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        terminalView?.scrollWheel(with: event)
    }
}

// MARK: - MetalLayerView (shared with EditorView)

/// CAMetalLayer-backed view for GPU rendering. Passes mouse events through.
private class MetalLayerView: NSView {
    let device: MTLDevice

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
