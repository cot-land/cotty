import AppKit
import Metal
import QuartzCore

/// Metal-rendered inspector panel. Displays the inspector cell grid
/// (same rendering approach as the terminal). Tab switching via native
/// NSSegmentedControl (like Ghostty's ImGui tabs — framework-rendered,
/// not character cells). Includes a native scrollbar overlay.
class InspectorView: NSView {
    let surface: CottySurface
    let isTerminal: Bool
    weak var workspaceController: WorkspaceWindowController?
    private(set) var renderer: MetalRenderer
    private let metalView: InspectorMetalLayerView

    // Native tab bar (like Ghostty's ImGui docked window tabs)
    private let tabControl = NSSegmentedControl()
    private let tabHeight: CGFloat = 28

    // Scrollbar — same pattern as TerminalView (TrackingScrollView for hover visibility)
    private let scrollView = TrackingScrollView()
    private let sizerView = InspectorSizerView()
    private var ignoreScrollUpdate = false

    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, surface: CottySurface, device: MTLDevice, isTerminal: Bool = true) {
        self.surface = surface
        self.isTerminal = isTerminal
        self.renderer = MetalRenderer(
            device: device,
            fontSizeOverride: Theme.shared.effectiveInspectorFontSize
        )
        metalView = InspectorMetalLayerView(frame: frame, device: device)
        super.init(frame: frame)

        // Tab bar at top (non-flipped: top = max Y)
        setupTabBar()

        // Metal view fills area below tab bar
        let contentFrame = contentAreaFrame()
        metalView.frame = contentFrame
        addSubview(metalView)

        // Scroll view overlay on metal view
        setupScrollView(frame: contentFrame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Tab Bar (native NSSegmentedControl, like Ghostty's ImGui tabs)

    private func setupTabBar() {
        if isTerminal {
            tabControl.segmentCount = 4
            tabControl.setLabel("Screen", forSegment: 0)
            tabControl.setLabel("Modes", forSegment: 1)
            tabControl.setLabel("Keyboard", forSegment: 2)
            tabControl.setLabel("Terminal IO", forSegment: 3)
            tabControl.selectedSegment = 0
        } else {
            tabControl.segmentCount = 1
            tabControl.setLabel("Editor", forSegment: 0)
            tabControl.selectedSegment = 0
        }
        tabControl.segmentStyle = .texturedRounded
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.appearance = NSAppearance(named: .darkAqua)
        // Non-flipped: top of view = bounds.height - tabHeight
        tabControl.frame = NSRect(x: 0, y: bounds.height - tabHeight, width: bounds.width, height: tabHeight)
        addSubview(tabControl)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        if isTerminal {
            surface.lockTerminal()
            surface.inspectorSetPanel(sender.selectedSegment)
            surface.inspectorRebuildTerminalState()
            surface.unlockTerminal()
        } else {
            surface.inspectorSetPanel(4)  // PANEL_EDITOR
            surface.inspectorRebuildEditorState()
        }
        renderFrame()
    }

    /// Content area below the tab bar.
    private func contentAreaFrame() -> NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - tabHeight))
    }

    private func setupScrollView(frame contentFrame: NSRect) {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.frame = contentFrame
        scrollView.hasHorizontalScroller = false

        let clipView = scrollView.contentView
        clipView.drawsBackground = false

        sizerView.inspectorView = self
        sizerView.frame = NSRect(x: 0, y: 0, width: contentFrame.width, height: contentFrame.height)
        scrollView.documentView = sizerView

        addSubview(scrollView)

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
        resizeInspectorGrid()
        renderFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        renderer.updateScaleFactor(window.backingScaleFactor)
        updateDrawableSize()
        resizeInspectorGrid()
        renderFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Reposition tab bar and content area
        tabControl.frame = NSRect(x: 0, y: newSize.height - tabHeight, width: newSize.width, height: tabHeight)
        let contentFrame = contentAreaFrame()
        metalView.frame = contentFrame
        scrollView.frame = contentFrame
        updateDrawableSize()
        resizeInspectorGrid()
        renderFrame()
    }

    private func updateDrawableSize() {
        guard metalView.bounds.width > 0, metalView.bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        metalView.metalLayer.contentsScale = scale
        metalView.metalLayer.drawableSize = CGSize(
            width: metalView.bounds.width * scale,
            height: metalView.bounds.height * scale
        )
    }

    private func resizeInspectorGrid() {
        let contentFrame = contentAreaFrame()
        guard contentFrame.width > 0, contentFrame.height > 0 else { return }
        let pad = Theme.shared.paddingPoints
        let newCols = max(2, Int((contentFrame.width - 2 * pad) / renderer.cellWidthPoints))
        let newRows = max(2, Int((contentFrame.height - 2 * pad) / renderer.cellHeightPoints))
        if isTerminal {
            surface.lockTerminal()
            surface.inspectorResize(rows: newRows, cols: newCols)
            surface.unlockTerminal()
        } else {
            surface.inspectorResize(rows: newRows, cols: newCols)
        }
    }

    // MARK: - Rendering

    func renderFrame() {
        guard metalView.bounds.width > 0, metalView.bounds.height > 0 else { return }

        let contentRows: Int
        let scrollOffset: Int
        let inspectorRows: Int

        if isTerminal {
            surface.lockTerminal()
            surface.inspectorRebuildTerminalState()
            contentRows = surface.inspectorContentRows
            scrollOffset = surface.inspectorScrollOffset
            inspectorRows = surface.inspectorRows
            surface.unlockTerminal()
        } else {
            surface.inspectorRebuildEditorState()
            contentRows = surface.inspectorContentRows
            scrollOffset = surface.inspectorScrollOffset
            inspectorRows = surface.inspectorRows
        }

        renderer.renderInspector(
            layer: metalView.metalLayer,
            surface: surface
        )

        updateScrollbar(contentRows: contentRows, scrollOffset: scrollOffset, inspectorRows: inspectorRows)
    }

    // MARK: - Scrollbar

    private func updateScrollbar(contentRows: Int, scrollOffset: Int, inspectorRows: Int) {
        let cellH = renderer.cellHeightPoints
        let visibleHeight = scrollView.contentView.bounds.height

        // If no scrollable content, hide scrollbar by making sizer match visible area
        guard contentRows > inspectorRows else {
            if abs(sizerView.frame.height - visibleHeight) > 1 {
                sizerView.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width, height: visibleHeight)
            }
            return
        }

        // Sizer represents total content in cell units
        let sizerHeight = max(CGFloat(contentRows) * cellH, visibleHeight)
        let sizerChanged = abs(sizerView.frame.height - sizerHeight) > 1
        if sizerChanged {
            sizerView.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width, height: sizerHeight)
        }

        // Non-flipped scroll mapping:
        // offset=0 (top of content) → clipView at top → targetY = sizerHeight - visibleHeight
        // offset=max (bottom) → clipView at bottom → targetY = 0
        let targetY = max(0, sizerHeight - visibleHeight - CGFloat(scrollOffset) * cellH)

        let currentY = scrollView.contentView.bounds.origin.y
        if abs(currentY - targetY) > 1 {
            ignoreScrollUpdate = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            ignoreScrollUpdate = false
        }

        // Flash scrollers when content becomes scrollable
        if sizerChanged {
            scrollView.flashScrollers()
        }
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard !ignoreScrollUpdate else { return }

        let scrollY = scrollView.contentView.bounds.origin.y
        let cellH = renderer.cellHeightPoints
        guard cellH > 0 else { return }

        let visibleHeight = scrollView.contentView.bounds.height
        let sizerHeight = sizerView.frame.height

        // Map scroll position to offset (non-flipped: top = max Y, bottom = 0)
        let offset = Int((sizerHeight - visibleHeight - scrollY) / cellH)

        if isTerminal {
            surface.lockTerminal()
            surface.inspectorSetScroll(offset: max(0, offset))
            surface.unlockTerminal()
        } else {
            surface.inspectorSetScroll(offset: max(0, offset))
        }
        renderFrame()
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        // Make inspector first responder on click
        window?.makeFirstResponder(self)
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        // Tab shortcuts only for terminal mode (4 tabs)
        if isTerminal, let chars = event.charactersIgnoringModifiers {
            switch chars {
            case "1":
                tabControl.selectedSegment = 0
                tabChanged(tabControl)
                return
            case "2":
                tabControl.selectedSegment = 1
                tabChanged(tabControl)
                return
            case "3":
                tabControl.selectedSegment = 2
                tabChanged(tabControl)
                return
            case "4":
                tabControl.selectedSegment = 3
                tabChanged(tabControl)
                return
            default:
                break
            }
        }

        switch event.keyCode {
        case 126: // Up — scroll up (like Ghostty's K/UpArrow)
            if isTerminal { surface.lockTerminal() }
            surface.inspectorScroll(delta: -1)
            if isTerminal { surface.unlockTerminal() }
            renderFrame()
        case 125: // Down — scroll down (like Ghostty's J/DownArrow)
            if isTerminal { surface.lockTerminal() }
            surface.inspectorScroll(delta: 1)
            if isTerminal { surface.unlockTerminal() }
            renderFrame()
        case 116: // Page Up
            if isTerminal { surface.lockTerminal() }
            let pageSize = max(1, surface.inspectorRows - 2)
            surface.inspectorScroll(delta: -pageSize)
            if isTerminal { surface.unlockTerminal() }
            renderFrame()
        case 121: // Page Down
            if isTerminal { surface.lockTerminal() }
            let pageSize = max(1, surface.inspectorRows - 2)
            surface.inspectorScroll(delta: pageSize)
            if isTerminal { surface.unlockTerminal() }
            renderFrame()
        case 36, 53: // Enter or Escape — return focus to content view
            if let wc = workspaceController {
                window?.makeFirstResponder(wc.activeContentView)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// Handle scroll wheel: update Cot scroll state and re-render.
    /// Direction matches terminal: swipe up = scroll up (toward top of content).
    override func scrollWheel(with event: NSEvent) {
        let delta = Int(event.scrollingDeltaY)
        if delta != 0 {
            if isTerminal { surface.lockTerminal() }
            // Negate: scrollingDeltaY > 0 (swipe up) → scroll toward top (delta -1)
            surface.inspectorScroll(delta: delta > 0 ? -1 : 1)
            if isTerminal { surface.unlockTerminal() }
            renderFrame()
        }
    }
}

// MARK: - Inspector Sizer View

/// Transparent document view for the inspector scrollbar.
/// Forwards mouse clicks and scroll events to the inspector view.
private class InspectorSizerView: NSView {
    weak var inspectorView: InspectorView?

    override func mouseDown(with event: NSEvent) {
        inspectorView?.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        inspectorView?.scrollWheel(with: event)
    }
}

// MARK: - Metal Layer View for Inspector

/// CAMetalLayer-backed view for GPU rendering.
/// Passes mouse events through to the parent InspectorView.
private class InspectorMetalLayerView: NSView {
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

    // Pass mouse events through to parent InspectorView
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
