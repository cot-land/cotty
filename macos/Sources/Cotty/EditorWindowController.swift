import AppKit

class EditorWindowController: NSWindowController, NSWindowDelegate, FileTreeDelegate {
    private(set) var editorView: EditorView!
    private(set) var filePath: URL?
    let surface: CottySurface
    private var isDirty = false {
        didSet { updateTitle() }
    }

    private var splitView: NSSplitView!
    private var fileTreeView: FileTreeView!
    private var fileTreeVisible = true

    private static var cascadePoint = NSPoint.zero

    convenience init(surface: CottySurface) {
        self.init(surface: surface, fileURL: nil)
    }

    init(surface: CottySurface, fileURL: URL?) {
        self.surface = surface
        self.filePath = fileURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 400, height: 300)
        window.backgroundColor = Theme.shared.background
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred

        super.init(window: window)

        window.delegate = self

        // File tree sidebar
        fileTreeView = FileTreeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        fileTreeView.delegate = self

        let sidebarContainer = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1).cgColor
        fileTreeView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(fileTreeView)
        NSLayoutConstraint.activate([
            fileTreeView.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            fileTreeView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            fileTreeView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            fileTreeView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
        ])

        // Editor
        editorView = EditorView(frame: NSRect(x: 0, y: 0, width: 780, height: 600), surface: surface)
        editorView.windowController = self

        // Split view
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.frame = window.contentView!.bounds
        splitView.addArrangedSubview(sidebarContainer)
        splitView.addArrangedSubview(editorView)
        splitView.setPosition(220, ofDividerAt: 0)

        window.contentView = splitView

        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editorView)

        if let url = fileURL {
            loadFile(url)
        }

        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: - Title

    private func updateTitle() {
        let name = filePath?.lastPathComponent ?? "Untitled"
        window?.title = isDirty ? "* \(name)" : name
    }

    func markDirty() {
        isDirty = true
    }

    // MARK: - File I/O

    private func loadFile(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            surface.loadContent(content)
            editorView.resetScroll()
            filePath = url
            isDirty = false
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc func saveDocument(_ sender: Any) {
        if let path = filePath {
            saveToFile(path)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filePath?.lastPathComponent ?? "Untitled.cot"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveToFile(url)
        }
    }

    private func saveToFile(_ url: URL) {
        let content = surface.bufferContent
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            surface.setClean()
            filePath = url
            isDirty = false
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: - File Tree

    @objc func openFolder(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.fileTreeView.rootURL = url
        }
    }

    @objc func toggleSidebar(_ sender: Any) {
        let sidebarView = splitView.arrangedSubviews[0]
        if fileTreeVisible {
            sidebarView.isHidden = true
        } else {
            sidebarView.isHidden = false
            splitView.setPosition(220, ofDividerAt: 0)
        }
        fileTreeVisible.toggle()
    }

    func fileTree(_ tree: FileTreeView, didSelect url: URL) {
        loadFile(url)
    }

    // MARK: - Tabs

    @objc func newTab(_ sender: Any) {
        guard let currentWindow = window,
              let delegate = NSApp.delegate as? AppDelegate else { return }
        let surface = delegate.cottyApp.createSurface()
        let wc = EditorWindowController(surface: surface)
        delegate.trackWindowController(wc)
        currentWindow.addTabbedWindow(wc.window!, ordered: .above)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.windowControllerDidClose(self)
        }
    }
}
