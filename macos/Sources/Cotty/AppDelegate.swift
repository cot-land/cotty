import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var cottyApp: CottyApp!
    private var workspaceControllers: [WorkspaceWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        cottyApp = CottyApp()
        Theme.shared.load()
        buildMenuBar()
        newWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Helpers

    func activeWorkspaceController() -> WorkspaceWindowController? {
        workspaceControllers.first { $0.window?.isKeyWindow == true }
            ?? workspaceControllers.last
    }

    // MARK: - Window Management

    /// Cmd+N — new workspace window with a terminal tab.
    @objc func newWindow(_ sender: Any) {
        let ws = CottyWorkspace(app: cottyApp)
        let wc = WorkspaceWindowController(workspace: ws)
        wc.addTerminalTab()
        workspaceControllers.append(wc)
    }

    /// Cmd+T — new terminal tab in current window.
    @objc func newTerminal(_ sender: Any) {
        if let active = activeWorkspaceController() {
            active.addTerminalTab()
        } else {
            newWindow(sender)
        }
    }

    /// Cmd+E — new editor tab in current window.
    @objc func newEditor(_ sender: Any) {
        if let active = activeWorkspaceController() {
            active.addEditorTab()
        } else {
            let ws = CottyWorkspace(app: cottyApp)
            let wc = WorkspaceWindowController(workspace: ws)
            wc.addEditorTab()
            workspaceControllers.append(wc)
        }
    }

    @objc func openDocument(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if let active = self.activeWorkspaceController() {
                active.addEditorTab(fileURL: url)
            } else {
                let ws = CottyWorkspace(app: self.cottyApp)
                let wc = WorkspaceWindowController(workspace: ws)
                wc.addEditorTab(fileURL: url)
                self.workspaceControllers.append(wc)
            }
        }
    }

    func workspaceControllerDidClose(_ controller: WorkspaceWindowController) {
        workspaceControllers.removeAll { $0 === controller }
    }

    // MARK: - Menu Bar

    private func buildMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cotty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cotty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "New Terminal", action: #selector(newTerminal(_:)), keyEquivalent: "t")
        fileMenu.addItem(withTitle: "New Editor", action: #selector(newEditor(_:)), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let openFolderItem = NSMenuItem(title: "Open Folder...", action: #selector(WorkspaceWindowController.openFolder(_:)), keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(openFolderItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(WorkspaceWindowController.saveDocument(_:)), keyEquivalent: "s")

        let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(WorkspaceWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAsItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(WorkspaceWindowController.toggleSidebar(_:)), keyEquivalent: "b")
        let inspectorItem = NSMenuItem(title: "Terminal Inspector", action: #selector(WorkspaceWindowController.toggleTerminalInspector(_:)), keyEquivalent: "i")
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(inspectorItem)
        viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu (Cmd+1–9 tab switching)
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Select Tab \(i)",
                action: NSSelectorFromString("selectTab\(i):"),
                keyEquivalent: "\(i)"
            )
            windowMenu.addItem(item)
        }
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
