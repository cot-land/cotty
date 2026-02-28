import AppKit
import Foundation

/// Window controller for terminal surfaces.
/// Simpler than EditorWindowController — no file I/O, no sidebar.
class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var terminalView: TerminalView!
    let surface: CottySurface

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
        window.title = "Cotty — build 20260228.2"

        super.init(window: window)

        window.delegate = self
        terminalView = TerminalView(frame: window.contentView!.bounds, surface: surface)
        terminalView.windowController = self
        terminalView.autoresizingMask = [.width, .height]
        window.contentView = terminalView

        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Actions

    @objc func toggleKeyInspector(_ sender: Any) {
        terminalView.toggleInspector()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.terminalWindowControllerDidClose(self)
        }
    }
}
