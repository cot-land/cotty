import AppKit
import Foundation

/// Window controller for terminal surfaces.
/// Manual split layout: terminal (top) + divider + inspector (bottom).
/// Inspector toggled via Cmd+Opt+I (matches Ghostty's "Terminal Inspector").
/// Divider is draggable to resize the inspector panel.
class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var terminalView: TerminalView!
    let surface: CottySurface

    private var inspectorView: InspectorView?
    private var dividerView: DividerView?
    private(set) var inspectorVisible = false
    private var inspectorHeight: CGFloat = 260
    private let dividerHeight: CGFloat = 5

    private static var cascadePoint = NSPoint.zero

    init(surface: CottySurface) {
        self.surface = surface

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 300, height: 200)
        window.backgroundColor = Theme.shared.background
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.title = "Cotty"

        super.init(window: window)

        window.delegate = self

        // Terminal view fills the whole window initially
        let contentBounds = window.contentView!.bounds
        terminalView = TerminalView(frame: contentBounds, surface: surface)
        terminalView.windowController = self
        terminalView.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(terminalView)

        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Inspector Toggle

    @objc func toggleTerminalInspector(_ sender: Any) {
        if inspectorVisible {
            hideInspector()
        } else {
            showInspector()
        }
    }

    private func showInspector() {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds

        // Toggle on in Cot
        surface.lockTerminal()
        if !surface.inspectorActive {
            surface.toggleInspector()
        }
        surface.unlockTerminal()

        // Create inspector view if needed
        if inspectorView == nil {
            let inspFrame = NSRect(x: 0, y: 0, width: bounds.width, height: inspectorHeight)
            let iv = InspectorView(frame: inspFrame, surface: surface, renderer: terminalView.renderer)
            iv.windowController = self
            contentView.addSubview(iv)
            inspectorView = iv
        }

        // Create divider if needed
        if dividerView == nil {
            let dv = DividerView(frame: NSRect(x: 0, y: inspectorHeight, width: bounds.width, height: dividerHeight))
            dv.windowController = self
            contentView.addSubview(dv)
            dividerView = dv
        }

        inspectorView?.isHidden = false
        dividerView?.isHidden = false
        inspectorVisible = true
        layoutSubviews()
    }

    private func hideInspector() {
        guard let contentView = window?.contentView else { return }

        // Toggle off in Cot
        surface.lockTerminal()
        if surface.inspectorActive {
            surface.toggleInspector()
        }
        surface.unlockTerminal()

        // Expand terminal to fill window
        inspectorView?.isHidden = true
        dividerView?.isHidden = true
        terminalView.autoresizingMask = [.width, .height]
        terminalView.frame = contentView.bounds

        inspectorVisible = false
    }

    /// Update the inspector height from divider drag.
    func setInspectorHeight(_ newHeight: CGFloat) {
        guard let contentView = window?.contentView else { return }
        let bounds = contentView.bounds
        let minInspector: CGFloat = 80
        let minTerminal: CGFloat = 100
        inspectorHeight = max(minInspector, min(newHeight, bounds.height - minTerminal - dividerHeight))
        layoutSubviews()
    }

    /// Re-layout terminal + divider + inspector after window resize or divider drag.
    private func layoutSubviews() {
        guard inspectorVisible, let contentView = window?.contentView else { return }
        let bounds = contentView.bounds

        // Clamp inspector height to available space
        let maxInspector = bounds.height - 100 - dividerHeight
        if inspectorHeight > maxInspector {
            inspectorHeight = max(80, maxInspector)
        }

        let termHeight = bounds.height - inspectorHeight - dividerHeight

        // Non-flipped: y=0 is bottom. Inspector at bottom, divider above it, terminal on top.
        inspectorView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: inspectorHeight)
        dividerView?.frame = NSRect(x: 0, y: inspectorHeight, width: bounds.width, height: dividerHeight)
        terminalView.autoresizingMask = []
        terminalView.frame = NSRect(x: 0, y: inspectorHeight + dividerHeight, width: bounds.width, height: termHeight)
    }

    // MARK: - Inspector Render Notify

    /// Called by TerminalView after it renders, so the inspector can update too.
    func notifyInspectorRender() {
        guard inspectorVisible, let inspectorView else { return }
        inspectorView.renderFrame()
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        if inspectorVisible {
            layoutSubviews()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.terminalWindowControllerDidClose(self)
        }
    }
}

// MARK: - Divider View

/// Thin draggable divider between terminal and inspector.
/// Shows a resize cursor and handles drag to resize the inspector panel.
class DividerView: NSView {
    weak var windowController: TerminalWindowController?

    override func draw(_ dirtyRect: NSRect) {
        // Draw a subtle separator line
        NSColor(white: 0.25, alpha: 1.0).setFill()
        bounds.fill()
        // Draw a 1px highlight line at the top
        NSColor(white: 0.35, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        // Start drag — we handle everything in mouseDragged
    }

    override func mouseDragged(with event: NSEvent) {
        guard let contentView = window?.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        // Non-flipped: point.y is the divider position from bottom
        // Inspector height = distance from bottom to divider
        windowController?.setInspectorHeight(point.y)
    }
}
