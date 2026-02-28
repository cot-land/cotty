import AppKit
import CCottyCore
import Metal
import QuartzCore

/// Custom NSView containing a Metal rendering surface and native scrollbar.
/// The Metal view renders behind a transparent NSScrollView that provides
/// the native macOS scrollbar and momentum scrolling.
class EditorView: NSView {
    // MARK: - State

    private var scrollPixelOffset: CGFloat = 0
    private var cursorVisible: Bool = true
    private var blinkTimer: Timer?

    let surface: CottySurface
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
        let contentHeight = CGFloat(surface.lineCount) * renderer.cellHeightPoints + Theme.shared.paddingPoints * 2
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
            surface: surface,
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

        let (key, mods) = CottySurface.translateKeyEvent(event)
        guard key != 0 else { return }

        surface.sendKey(key, mods: mods)
        drainActions()

        updateContentSize()
        ensureCursorVisible()
        resetCursorBlink()
        renderFrame()
    }

    // MARK: - Action Queue

    private func drainActions() {
        guard let app = surface.app else { return }
        while let action = app.nextAction() {
            switch action.tag {
            case Int64(COTTY_ACTION_MARK_DIRTY):
                windowController?.markDirty()
            case Int64(COTTY_ACTION_QUIT):
                NSApp.terminate(nil)
            case Int64(COTTY_ACTION_NEW_WINDOW):
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.newDocument(self)
                }
            case Int64(COTTY_ACTION_CLOSE_SURFACE):
                window?.performClose(nil)
            default:
                break
            }
        }
    }

    // MARK: - Cursor Positioning

    private func ensureCursorVisible() {
        let lineH = renderer.cellHeightPoints
        let cursorY = CGFloat(surface.cursorLine) * lineH
        let rect = NSRect(x: 0, y: cursorY, width: 1, height: lineH + Theme.shared.paddingPoints)
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

    func resetScroll() {
        scrollPixelOffset = 0
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateContentSize()
        renderFrame()
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
class TrackingScrollView: NSScrollView {
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
