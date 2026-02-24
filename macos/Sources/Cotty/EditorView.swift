import AppKit
import Metal
import QuartzCore

/// Custom NSView containing a Metal rendering surface and native scrollbar.
/// The Metal view renders behind a transparent NSScrollView that provides
/// the native macOS scrollbar and momentum scrolling.
class EditorView: NSView {
    // MARK: - State

    private var buffer = GapBuffer()
    private var cursor = Cursor()
    private var scrollPixelOffset: CGFloat = 0
    private var cursorVisible: Bool = true
    private var blinkTimer: Timer?

    weak var windowController: EditorWindowController?

    // Metal
    private static let metalDevice = MTLCreateSystemDefaultDevice()!
    private var renderer: MetalRenderer!

    // Views
    private let metalView: MetalLayerView
    private let scrollView = TrackingScrollView()
    private let sizerView = SizerView()

    // MARK: - NSView Setup

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        metalView = MetalLayerView(frame: frame, device: Self.metalDevice)
        super.init(frame: frame)
        renderer = MetalRenderer(device: Self.metalDevice)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Metal rendering surface (behind everything)
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

        let clipView = FlippedClipView()
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

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        scrollPixelOffset = scrollView.contentView.bounds.origin.y
        renderFrame()
    }

    private func updateContentSize() {
        guard renderer != nil else { return }
        let contentHeight = CGFloat(buffer.lineCount()) * renderer.cellHeightPoints + Theme.paddingPoints * 2
        let viewH = scrollView.contentView.bounds.height
        sizerView.frame = NSRect(
            x: 0, y: 0,
            width: scrollView.contentView.bounds.width,
            height: max(contentHeight, viewH)
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        metalView.metalLayer.contentsScale = window.backingScaleFactor
        updateDrawableSize()
        updateContentSize()
        startBlinkTimer()
        renderFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        updateContentSize()
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

    // MARK: - Rendering

    private func renderFrame() {
        guard renderer != nil else { return }
        renderer.render(
            layer: metalView.metalLayer,
            buffer: buffer,
            cursor: cursor,
            scrollPixelOffset: scrollPixelOffset,
            cursorVisible: cursorVisible
        )
    }

    // MARK: - Input Handling

    override func keyDown(with event: NSEvent) {
        // Let the system handle Cmd+key combos via menu responder chain
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        let action = mapKeyEvent(event)
        switch action {
        case .insertChar:
            if let chars = event.characters {
                for ch in chars.utf8 {
                    buffer.moveGapTo(cursor.offset)
                    buffer.insert(ch)
                    cursor.offset += 1
                    cursor.col += 1
                    if ch == UInt8(ascii: "\n") {
                        cursor.line += 1
                        cursor.col = 0
                    }
                }
                windowController?.markDirty()
            }

        case .insertNewline:
            buffer.moveGapTo(cursor.offset)
            buffer.insert(UInt8(ascii: "\n"))
            cursor.offset += 1
            cursor.line += 1
            cursor.col = 0
            windowController?.markDirty()

        case .insertTab:
            buffer.moveGapTo(cursor.offset)
            for _ in 0..<4 {
                buffer.insert(UInt8(ascii: " "))
                cursor.offset += 1
                cursor.col += 1
            }
            windowController?.markDirty()

        case .deleteBack:
            if cursor.offset > 0 {
                let deletedChar = buffer.charAt(cursor.offset - 1)
                buffer.moveGapTo(cursor.offset)
                buffer.deleteBack()
                cursor.offset -= 1
                if deletedChar == UInt8(ascii: "\n") {
                    recomputeLineCol()
                } else {
                    cursor.col -= 1
                }
                windowController?.markDirty()
            }

        case .deleteForward:
            if cursor.offset < buffer.len {
                buffer.moveGapTo(cursor.offset)
                buffer.deleteForward()
                windowController?.markDirty()
            }

        case .moveLeft:
            if cursor.offset > 0 {
                cursor.offset -= 1
                if cursor.col > 0 {
                    cursor.col -= 1
                } else {
                    recomputeLineCol()
                }
            }

        case .moveRight:
            if cursor.offset < buffer.len {
                let ch = buffer.charAt(cursor.offset)
                cursor.offset += 1
                if ch == UInt8(ascii: "\n") {
                    cursor.line += 1
                    cursor.col = 0
                } else {
                    cursor.col += 1
                }
            }

        case .moveUp:
            if cursor.line > 0 {
                let targetCol = cursor.col
                cursor.line -= 1
                let lineLen = buffer.lineLength(cursor.line)
                cursor.col = min(targetCol, lineLen)
                recomputeOffset()
            }

        case .moveDown:
            let totalLines = buffer.lineCount()
            if cursor.line < totalLines - 1 {
                let targetCol = cursor.col
                cursor.line += 1
                let lineLen = buffer.lineLength(cursor.line)
                cursor.col = min(targetCol, lineLen)
                recomputeOffset()
            }

        case .moveLineStart:
            cursor.col = 0
            recomputeOffset()

        case .moveLineEnd:
            cursor.col = buffer.lineLength(cursor.line)
            recomputeOffset()

        case .pageUp:
            let visibleLines = max(1, Int(bounds.height / renderer.cellHeightPoints) - 1)
            cursor.line = max(0, cursor.line - visibleLines)
            let lineLen = buffer.lineLength(cursor.line)
            cursor.col = min(cursor.col, lineLen)
            recomputeOffset()

        case .pageDown:
            let totalLines = buffer.lineCount()
            let visibleLines = max(1, Int(bounds.height / renderer.cellHeightPoints) - 1)
            cursor.line = min(totalLines - 1, cursor.line + visibleLines)
            let lineLen = buffer.lineLength(cursor.line)
            cursor.col = min(cursor.col, lineLen)
            recomputeOffset()

        case .none:
            break
        }

        updateContentSize()
        ensureCursorVisible()
        resetCursorBlink()
        renderFrame()
    }

    // MARK: - Key Mapping

    private enum EditorAction {
        case insertChar
        case insertNewline
        case insertTab
        case deleteBack
        case deleteForward
        case moveLeft
        case moveRight
        case moveUp
        case moveDown
        case moveLineStart
        case moveLineEnd
        case pageUp
        case pageDown
        case none
    }

    private func mapKeyEvent(_ event: NSEvent) -> EditorAction {
        switch event.keyCode {
        case 51: return .deleteBack
        case 117: return .deleteForward
        case 123:
            if event.modifierFlags.contains(.command) { return .moveLineStart }
            return .moveLeft
        case 124:
            if event.modifierFlags.contains(.command) { return .moveLineEnd }
            return .moveRight
        case 125: return .moveDown
        case 126: return .moveUp
        case 115: return .moveLineStart
        case 119: return .moveLineEnd
        case 116: return .pageUp
        case 121: return .pageDown
        case 36: return .insertNewline
        case 48: return .insertTab
        default: break
        }

        if let chars = event.characters, !chars.isEmpty {
            let scalar = chars.unicodeScalars.first!
            if scalar.value >= 32 && scalar.value <= 126 {
                return .insertChar
            }
        }

        return .none
    }

    // MARK: - Cursor Positioning

    private func recomputeLineCol() {
        var line = 0
        var col = 0
        for i in 0..<cursor.offset {
            if buffer.charAt(i) == UInt8(ascii: "\n") {
                line += 1
                col = 0
            } else {
                col += 1
            }
        }
        cursor.line = line
        cursor.col = col
    }

    private func recomputeOffset() {
        cursor.offset = buffer.lineStartOffset(cursor.line) + cursor.col
    }

    private func ensureCursorVisible() {
        let lineH = renderer.cellHeightPoints
        let cursorY = CGFloat(cursor.line) * lineH
        let rect = NSRect(x: 0, y: cursorY, width: 1, height: lineH + Theme.paddingPoints)
        sizerView.scrollToVisible(rect)
    }

    // MARK: - Cursor Blink

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorVisible.toggle()
            self.renderFrame()
        }
    }

    private func resetCursorBlink() {
        cursorVisible = true
        startBlinkTimer()
    }

    // MARK: - Public API

    func loadContent(_ content: String) {
        buffer = GapBuffer(content: content)
        cursor = Cursor()
        scrollPixelOffset = 0
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateContentSize()
        renderFrame()
    }

    func bufferContent() -> String {
        buffer.toString()
    }
}

// MARK: - Helper Views

/// CAMetalLayer-backed view for GPU rendering. Returns nil from hitTest
/// so all mouse events pass through to the NSScrollView on top.
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

/// NSScrollView subclass that shows the overlay scroller on hover.
private class TrackingScrollView: NSScrollView {
    private var scrollbarTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
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
            // Let the system fade out naturally — keeps trackpad scrolling working
            flashScrollers()
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

/// Flipped clip view for top-left origin scroll coordinates.
private class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Transparent document view that provides content size to the scroll view.
/// Forwards mouseDown to the editor so it stays first responder.
private class SizerView: NSView {
    weak var editorView: EditorView?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(editorView)
    }
}
