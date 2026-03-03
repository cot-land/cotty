import AppKit
import CCottyCore
import Metal
import QuartzCore

/// Editor surface rendered via a cell grid from Cot (same pipeline as terminal).
/// Cot owns the grid — Swift just reads the raw cell pointer and renders via Metal.
class EditorView: NSView {
    // MARK: - State

    private var blinkTimer: Timer?

    let surface: CottySurface
    weak var workspaceController: WorkspaceWindowController?

    // Metal
    private static let metalDevice = MTLCreateSystemDefaultDevice()!
    private var renderer: MetalRenderer!

    // Views
    private let metalView: MetalLayerView

    // Scrollbar — transparent NSScrollView overlay (visual only, scroll input handled directly)
    private let scrollView = TrackingScrollView()
    private let sizerView = EditorSizerView()
    private var ignoreScrollUpdate = false

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

    private func setupViews() {
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)

        // Transparent scroll view on top — provides native scrollbar
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        sizerView.editorView = self
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
        computeGridSize()
        startBlinkTimer()
        renderFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        renderer?.updateScaleFactor(window.backingScaleFactor)
        updateDrawableSize()
        computeGridSize()
        renderFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        computeGridSize()
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

    /// Compute grid rows/cols from the frame size and tell Cot to resize.
    private func computeGridSize() {
        guard renderer != nil else { return }
        let cellW = renderer.cellWidthPoints
        let cellH = renderer.cellHeightPoints
        guard cellW > 0, cellH > 0 else { return }
        let pad = Theme.shared.paddingPoints
        let usableW = bounds.width - pad * 2
        let usableH = bounds.height - pad * 2
        let cols = max(1, Int(floor(usableW / cellW)))
        let rows = max(1, Int(floor(usableH / cellH)))
        surface.editorResize(rows: rows, cols: cols)
    }

    // MARK: - Rendering

    func renderFrame() {
        guard renderer != nil else { return }
        let isFocused = window?.firstResponder === self
        renderer.renderEditor(
            layer: metalView.metalLayer,
            surface: surface,
            cursorVisible: cursorBlinkOn,
            focused: isFocused
        )
        updateScrollbar()
        workspaceController?.updateStatusBar()
    }

    // MARK: - Scrollbar

    /// Update the sizer view size and scroll position for both axes.
    /// NSScrollView handles all scroll input (wheel + scrollbar drag).
    /// We just keep the sizer dimensions and scroll position in sync with Cot state.
    private func updateScrollbar() {
        guard renderer != nil else { return }
        let cellW = renderer.cellWidthPoints
        let cellH = renderer.cellHeightPoints
        guard cellW > 0, cellH > 0 else { return }
        let pad = Theme.shared.paddingPoints

        let lineCount = surface.editorLineCount
        let visibleRows = surface.editorRows
        let visibleCols = surface.editorCols
        let maxLineLen = surface.editorMaxLineLength
        let scrollOffset = surface.editorScrollOffset
        let hScrollOffset = surface.editorHScrollOffset

        // Sizer dimensions reflect full content size
        let contentHeight = CGFloat(max(lineCount, visibleRows)) * cellH + pad * 2
        let contentWidth = CGFloat(max(maxLineLen + 6, visibleCols)) * cellW + pad * 2  // +6 for gutter

        let newSize = NSSize(width: contentWidth, height: contentHeight)
        if sizerView.frame.size != newSize {
            sizerView.frame = NSRect(origin: .zero, size: newSize)
        }

        // Sync scroll position to Cot state
        let targetX = CGFloat(hScrollOffset) * cellW
        let targetY = CGFloat(scrollOffset) * cellH
        let current = scrollView.contentView.bounds.origin

        if abs(current.x - targetX) > 1 || abs(current.y - targetY) > 1 {
            ignoreScrollUpdate = true
            scrollView.contentView.scroll(to: NSPoint(x: targetX, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            ignoreScrollUpdate = false
        }
    }

    /// When user scrolls (wheel or scrollbar drag), map pixel position to line/col offset.
    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard !ignoreScrollUpdate else { return }
        guard renderer != nil else { return }

        let cellW = renderer.cellWidthPoints
        let cellH = renderer.cellHeightPoints
        guard cellW > 0, cellH > 0 else { return }

        let origin = scrollView.contentView.bounds.origin
        let vOffset = Int(origin.y / cellH)
        let hOffset = Int(origin.x / cellW)

        surface.editorSetScrollOffset(vOffset)
        surface.editorSetHScrollOffset(hOffset)
        renderFrame()
    }

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        // Cmd+key shortcuts
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "v":
                // Cmd+V — smart paste (single transaction, indent-aware, linewise-aware)
                if let text = NSPasteboard.general.string(forType: .string) {
                    surface.editorPaste(text)
                    drainActions()
                    resetCursorBlink()
                    renderFrame()
                }
                return
            case "c":
                // Cmd+C — copy selection to clipboard
                surface.editorCopy()
                drainActions()
                return
            case "x":
                // Cmd+X — cut selection to clipboard
                surface.editorCut()
                drainActions()
                resetCursorBlink()
                renderFrame()
                return
            case "a":
                // Cmd+A — select all
                surface.editorSelectAll()
                renderFrame()
                return
            case "d":
                // Cmd+D — add next occurrence (multi-cursor)
                surface.editorAddNextOccurrence()
                resetCursorBlink()
                renderFrame()
                return
            default:
                break
            }
            // Let the system handle other Cmd+key combos via menu responder chain
            super.keyDown(with: event)
            return
        }

        let (key, mods) = CottySurface.translateKeyEvent(event)
        guard key != 0 else { return }

        surface.sendKey(key, mods: mods)
        drainActions()
        resetCursorBlink()
        renderFrame()
    }

    // MARK: - Action Queue

    private func drainActions() {
        guard let app = surface.app else { return }
        while let action = app.nextAction() {
            switch action.tag {
            case Int64(COTTY_ACTION_MARK_DIRTY):
                workspaceController?.markDirty()
            case Int64(COTTY_ACTION_QUIT):
                NSApp.terminate(nil)
            case Int64(COTTY_ACTION_NEW_WINDOW):
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.newWindow(self)
                }
            case Int64(COTTY_ACTION_CLOSE_SURFACE):
                window?.performClose(nil)
            case Int64(COTTY_ACTION_YANK):
                if let text = surface.editorYankText {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                }
            default:
                break
            }
        }
    }

    // MARK: - Cursor Blink

    private var cursorBlinkOn = true

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        cursorBlinkOn = true
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorBlinkOn.toggle()
            self.surface.editorSetCursorVisible(self.cursorBlinkOn)
            self.surface.editorRebuild()
            self.renderFrame()
        }
    }

    private func resetCursorBlink() {
        surface.editorSetCursorVisible(true)
        startBlinkTimer()
    }

    // MARK: - Public API

    func resetScroll() {
        renderFrame()
    }

    /// Convert a point in view coordinates to grid (row, col).
    private func gridPosition(from point: NSPoint) -> (row: Int, col: Int) {
        guard renderer != nil else { return (0, 0) }
        let cellW = renderer.cellWidthPoints
        let cellH = renderer.cellHeightPoints
        guard cellW > 0, cellH > 0 else { return (0, 0) }
        let pad = Theme.shared.paddingPoints
        let col = Int((point.x - pad) / cellW)
        let row = Int((point.y - pad) / cellH)
        return (row, col)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = gridPosition(from: point)
        if event.modifierFlags.contains(.command) {
            // Cmd+Click — add cursor at click position
            surface.editorAddCursor(row: row, col: col)
        } else {
            surface.editorClick(row: row, col: col)
        }
        resetCursorBlink()
        renderFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let (row, col) = gridPosition(from: point)
        surface.editorDrag(row: row, col: col)
        renderFrame()
    }
}

// MARK: - Helper Views

/// CAMetalLayer-backed view for GPU rendering.
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
}

/// Transparent document view that provides content height for the scrollbar.
/// Forwards mouse events through to the editor view.
private class EditorSizerView: NSView {
    weak var editorView: EditorView?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        editorView?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        editorView?.mouseDragged(with: event)
    }

}

/// NSScrollView subclass that shows the overlay scroller on hover.
/// Shared by TerminalView and InspectorView.
class TrackingScrollView: NSScrollView {
    private var scrollbarTrackingArea: NSTrackingArea?
    private var updatingTrackingAreas = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updatingTrackingAreas = true
        if let area = scrollbarTrackingArea {
            removeTrackingArea(area)
        }
        let scrollerWidth: CGFloat = 20
        let trackRect = NSRect(
            x: bounds.width - scrollerWidth,
            y: 0,
            width: scrollerWidth,
            height: bounds.height
        )
        scrollbarTrackingArea = NSTrackingArea(
            rect: trackRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(scrollbarTrackingArea!)
        updatingTrackingAreas = false
    }

    private var hoveringScrollbar = false
    private var flashTimer: Timer?

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === scrollbarTrackingArea {
            hoveringScrollbar = true
            keepScrollerVisible()
        } else {
            super.mouseEntered(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === scrollbarTrackingArea {
            hoveringScrollbar = false
            flashTimer?.invalidate()
            flashTimer = nil
            // Don't flash during tracking area rebuild (resize) — prevents scrollbar flicker
            if !updatingTrackingAreas {
                flashScrollers()
            }
        } else {
            super.mouseExited(with: event)
        }
    }

    private func keepScrollerVisible() {
        flashScrollers()
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            guard let self, self.hoveringScrollbar else { return }
            self.flashScrollers()
        }
    }
}
