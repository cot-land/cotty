import AppKit
import CCottyCore
import CoreText

/// Single-window workspace controller. Manages a custom tab bar, sidebar,
/// and multiple tabs. All tab logic (ordering, selection, preview/pin) lives
/// in Cot via CottyWorkspace. Swift only manages views and platform I/O.
class WorkspaceWindowController: NSWindowController, NSWindowDelegate, FileTreeDelegate, TabBarDelegate {
    let workspace: CottyWorkspace

    // View dictionaries keyed by surface handle
    private var viewsBySurface: [cotty_surface_t: NSView] = [:]
    private var surfacesBySurface: [cotty_surface_t: CottySurface] = [:]

    // File paths keyed by surface handle (Foundation URLs stay in Swift)
    private var filePathsBySurface: [cotty_surface_t: URL] = [:]

    // Layout
    private var tabBarView: TabBarView!
    private var splitView: NSSplitView!
    private var sidebarContainer: NSView!
    private var fileTreeView: FileTreeView!
    private var contentContainer: NSView!

    // Inspector (shown for current terminal tab)
    private var inspectorView: InspectorView?
    private var dividerView: DividerView?
    private(set) var inspectorVisible = false
    private var inspectorHeight: CGFloat = 260
    private let dividerHeight: CGFloat = 5

    // Command palette overlay
    private var paletteView: CommandPaletteView?

    // Theme selector overlay
    private var themeSelectorView: ThemeSelectorView?

    private static var cascadePoint = NSPoint.zero

    // MARK: - Init

    init(workspace: CottyWorkspace) {
        self.workspace = workspace
        let window = Self.makeWindow()
        super.init(window: window)
        window.delegate = self
        setupLayout()
        syncSidebarFromState()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        window.makeKeyAndOrderFront(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Helpers

    /// Get the view for the currently selected tab.
    private var selectedView: NSView? {
        let idx = workspace.selectedIndex
        guard idx >= 0 else { return nil }
        let handle = workspace.tabSurface(at: idx)
        return viewsBySurface[handle]
    }

    /// Get the CottySurface for the currently selected tab.
    private var selectedSurface: CottySurface? {
        let idx = workspace.selectedIndex
        guard idx >= 0 else { return nil }
        return surfacesBySurface[workspace.tabSurface(at: idx)]
    }

    /// The active terminal view (used by InspectorView to return focus).
    var activeTerminalView: TerminalView? {
        selectedView as? TerminalView
    }

    /// Build tab info array from CottyWorkspace for the tab bar.
    private func buildTabInfos() -> [TabBarView.TabInfo] {
        (0..<workspace.tabCount).map { i in
            TabBarView.TabInfo(
                title: tabDisplayTitle(at: i),
                isPreview: workspace.tabIsPreview(at: i),
                isDirty: workspace.tabIsDirty(at: i),
                isTerminal: workspace.tabIsTerminal(at: i),
                shortcutIndex: i < 9 ? i : -1
            )
        }
    }

    /// Compute the display title for a tab. For editor tabs, includes dirty prefix
    /// and uses the Swift-side file path for the last path component.
    private func tabDisplayTitle(at index: Int) -> String {
        if workspace.tabIsTerminal(at: index) {
            return workspace.tabTitle(at: index)
        }
        // Editor tab: prefer Swift-side file path for the title
        let handle = workspace.tabSurface(at: index)
        let name = filePathsBySurface[handle]?.lastPathComponent ?? "Untitled"
        let dirty = workspace.tabIsDirty(at: index)
        return dirty ? "\u{25CF} \(name)" : name
    }

    private func reloadTabBar() {
        tabBarView.reloadTabs(buildTabInfos(), selectedIndex: workspace.selectedIndex)
    }

    // MARK: - Cmd+1–9 Tab Switching

    @objc func selectTab1(_ sender: Any?) { selectTab(at: 0) }
    @objc func selectTab2(_ sender: Any?) { selectTab(at: 1) }
    @objc func selectTab3(_ sender: Any?) { selectTab(at: 2) }
    @objc func selectTab4(_ sender: Any?) { selectTab(at: 3) }
    @objc func selectTab5(_ sender: Any?) { selectTab(at: 4) }
    @objc func selectTab6(_ sender: Any?) { selectTab(at: 5) }
    @objc func selectTab7(_ sender: Any?) { selectTab(at: 6) }
    @objc func selectTab8(_ sender: Any?) { selectTab(at: 7) }
    @objc func selectTab9(_ sender: Any?) { selectTab(at: max(0, workspace.tabCount - 1)) }

    // MARK: - Window Setup

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 400, height: 300)
        window.backgroundColor = Theme.shared.background
        if Theme.shared.bgOpacity < 1.0 {
            window.isOpaque = false
        }
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovable = false
        window.title = "Cotty"
        return window
    }

    private func setupLayout() {
        guard let window else { return }
        let container = window.contentView!

        // Tab bar
        tabBarView = TabBarView(frame: .zero)
        tabBarView.delegate = self
        tabBarView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tabBarView)

        // Sidebar
        fileTreeView = FileTreeView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        fileTreeView.delegate = self

        sidebarContainer = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
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

        // Content container
        contentContainer = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 600))

        // Split view
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(sidebarContainer)
        splitView.addArrangedSubview(contentContainer)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)

        NSLayoutConstraint.activate([
            tabBarView.topAnchor.constraint(equalTo: container.topAnchor),
            tabBarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBarView.heightAnchor.constraint(equalToConstant: TabBarView.barHeight),

            splitView.topAnchor.constraint(equalTo: tabBarView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Set sidebar position after layout settles
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.splitView.setPosition(CGFloat(self.workspace.sidebarWidth), ofDividerAt: 0)
        }

        if let rootURL = workspace.rootURL {
            fileTreeView.rootURL = rootURL
        }
    }

    private func syncSidebarFromState() {
        sidebarContainer.isHidden = !workspace.sidebarVisible
        if workspace.sidebarVisible {
            splitView.setPosition(CGFloat(workspace.sidebarWidth), ofDividerAt: 0)
        }
    }

    // MARK: - Tab Management

    func addTerminalTab() {
        guard let app = workspace.app else { return }
        let (rows, cols) = terminalGridSizeForContent()
        let surfaceHandle = workspace.addTerminalTab(rows: rows, cols: cols)
        let surface = CottySurface(app: app, handle: surfaceHandle)
        let tv = TerminalView(frame: contentContainer.bounds, surface: surface)
        tv.workspaceController = self
        viewsBySurface[surfaceHandle] = tv
        surfacesBySurface[surfaceHandle] = surface
        selectTab(at: workspace.selectedIndex)
    }

    func addEditorTab(fileURL: URL? = nil, isPreview: Bool = false) {
        guard let app = workspace.app else { return }
        let surfaceHandle: cotty_surface_t
        if isPreview {
            surfaceHandle = workspace.addEditorTabPreview()
        } else {
            surfaceHandle = workspace.addEditorTab()
        }
        let surface = CottySurface(app: app, handle: surfaceHandle)
        let ev = EditorView(frame: contentContainer.bounds, surface: surface)
        ev.workspaceController = self
        viewsBySurface[surfaceHandle] = ev
        surfacesBySurface[surfaceHandle] = surface

        if let url = fileURL {
            filePathsBySurface[surfaceHandle] = url
            loadFile(url, surfaceHandle: surfaceHandle)
        }

        selectTab(at: workspace.selectedIndex)
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < workspace.tabCount else { return }

        // Hide current content + inspector + split containers
        for sub in contentContainer.subviews {
            if sub is SplitContainerView { sub.removeFromSuperview() }
        }
        for (_, view) in viewsBySurface {
            view.isHidden = true
        }
        hideInspectorViews()

        workspace.selectTab(at: index)

        // Check if this tab has splits
        if workspace.isSplit {
            rebuildSplitLayout()
        } else {
            let surfaceHandle = workspace.tabSurface(at: index)
            guard let view = viewsBySurface[surfaceHandle] else { return }

            if view.superview !== contentContainer {
                contentContainer.addSubview(view)
            }
            view.isHidden = false
            view.autoresizingMask = [.width, .height]
            view.frame = contentContainer.bounds
            window?.makeFirstResponder(view)
        }

        // Restore inspector if terminal tab had it visible
        if workspace.tabIsTerminal(at: index) && workspace.tabInspectorVisible(at: index) {
            showInspector()
        }

        // Update chrome
        window?.title = tabDisplayTitle(at: index)
        reloadTabBar()
    }

    /// Close the active pane. If in a split, closes just the focused pane.
    /// If the last pane, closes the tab.
    @objc func closeActivePane(_ sender: Any?) {
        let idx = workspace.selectedIndex
        guard idx >= 0 else { return }

        if workspace.isSplit {
            let closedHandle = workspace.closeSplit()
            if closedHandle > 0 {
                viewsBySurface[closedHandle]?.removeFromSuperview()
                viewsBySurface.removeValue(forKey: closedHandle)
                surfacesBySurface.removeValue(forKey: closedHandle)
                // Rebuild split layout (may now be single pane)
                rebuildSplitLayout()
                return
            }
        }
        closeTab(at: idx)
    }

    func closeTab(at index: Int) {
        guard index >= 0, index < workspace.tabCount else { return }
        let surfaceHandle = workspace.tabSurface(at: index)

        // Remove view
        viewsBySurface[surfaceHandle]?.removeFromSuperview()
        viewsBySurface.removeValue(forKey: surfaceHandle)
        surfacesBySurface.removeValue(forKey: surfaceHandle)
        filePathsBySurface.removeValue(forKey: surfaceHandle)

        // Close in Cot (adjusts selection, preview tracking)
        _ = workspace.closeTab(at: index)

        if workspace.tabCount == 0 {
            window?.close()
            return
        }

        selectTab(at: workspace.selectedIndex)
    }

    /// Close a terminal tab/pane when its child process exits.
    /// If the view is a split pane, closes just that pane. Otherwise closes the tab.
    func closeTerminalView(_ view: TerminalView) {
        // Check if this view is in a split (its handle won't match the tab root)
        if workspace.isSplit, tabIndex(for: view) == nil {
            // The exiting pane should be focused (user typed 'exit' in it).
            // closeSplit closes the currently focused pane in Cot.
            let closedHandle = workspace.closeSplit()
            if closedHandle > 0 {
                viewsBySurface[closedHandle]?.removeFromSuperview()
                viewsBySurface.removeValue(forKey: closedHandle)
                surfacesBySurface.removeValue(forKey: closedHandle)
                rebuildSplitLayout()
                return
            }
        }
        guard let index = tabIndex(for: view) else { return }
        closeTab(at: index)
    }

    /// Find the tab index for a given view.
    private func tabIndex(for view: NSView) -> Int? {
        for i in 0..<workspace.tabCount {
            let handle = workspace.tabSurface(at: i)
            if viewsBySurface[handle] === view { return i }
        }
        return nil
    }

    // MARK: - Grid Size

    private func terminalGridSizeForContent() -> (rows: Int, cols: Int) {
        let windowSize = window?.contentView?.bounds.size ?? NSSize(width: 1000, height: 600)
        let sidebarW: CGFloat = workspace.sidebarVisible ? CGFloat(workspace.sidebarWidth) + 1 : 0
        let contentW = windowSize.width - sidebarW
        let contentH = windowSize.height - TabBarView.barHeight
        return Self.terminalGridSize(contentWidth: contentW, contentHeight: contentH)
    }

    static func terminalGridSize(contentWidth: CGFloat, contentHeight: CGFloat) -> (rows: Int, cols: Int) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let font = CTFontCreateWithName(Theme.shared.fontName as CFString, Theme.shared.fontSize * scale, nil)
        let cellH = (ceil(CTFontGetAscent(font)) + ceil(CTFontGetDescent(font))
                      + ceil(CTFontGetLeading(font))) / scale
        var glyph: CGGlyph = 0
        var adv = CGSize.zero
        var ch: UniChar = 0x4D // 'M'
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &adv, 1)
        let cellW = ceil(adv.width) / scale
        let pad = Theme.shared.paddingPoints
        let cols = max(2, Int((contentWidth - 2 * pad) / cellW))
        let rows = max(2, Int((contentHeight - 2 * pad) / cellH))
        return (rows, cols)
    }

    // MARK: - Title Updates (called by views)

    func updateTerminalTitle(_ title: String, from view: TerminalView) {
        guard let index = tabIndex(for: view) else { return }
        if index == workspace.selectedIndex {
            window?.title = title
        }
        // Update just the one tab button
        tabBarView.updateTab(
            at: index,
            title: title,
            isDirty: workspace.tabIsDirty(at: index),
            isPreview: workspace.tabIsPreview(at: index)
        )
    }

    func updateRepresentedURL(_ url: URL, from view: TerminalView) {
        guard let index = tabIndex(for: view), index == workspace.selectedIndex else { return }
        window?.representedURL = url
    }

    func markDirty() {
        let idx = workspace.selectedIndex
        guard idx >= 0, !workspace.tabIsTerminal(at: idx) else { return }
        workspace.markDirty(at: idx)
        updateEditorChrome()
    }

    func pinTab(at index: Int) {
        workspace.pinTab(at: index)
        reloadTabBar()
    }

    private func updateEditorChrome() {
        let idx = workspace.selectedIndex
        guard idx >= 0 else { return }
        let title = tabDisplayTitle(at: idx)
        window?.title = title
        reloadTabBar()
    }

    // MARK: - Inspector Toggle (terminal only)

    @objc func toggleTerminalInspector(_ sender: Any) {
        let idx = workspace.selectedIndex
        guard idx >= 0, workspace.tabIsTerminal(at: idx) else { return }
        if inspectorVisible {
            workspace.setTabInspectorVisible(at: idx, visible: false)
            hideInspector()
        } else {
            workspace.setTabInspectorVisible(at: idx, visible: true)
            showInspector()
        }
    }

    private func showInspector() {
        let idx = workspace.selectedIndex
        guard idx >= 0, workspace.tabIsTerminal(at: idx) else { return }
        let surfaceHandle = workspace.tabSurface(at: idx)
        guard let surface = surfacesBySurface[surfaceHandle],
              let tv = viewsBySurface[surfaceHandle] as? TerminalView else { return }
        let bounds = contentContainer.bounds

        surface.lockTerminal()
        if !surface.inspectorActive { surface.toggleInspector() }
        surface.unlockTerminal()

        // Recreate inspector if surface changed (different terminal tab)
        if inspectorView == nil || inspectorView!.surface !== surface {
            inspectorView?.removeFromSuperview()
            let iv = InspectorView(
                frame: NSRect(x: 0, y: 0, width: bounds.width, height: inspectorHeight),
                surface: surface, renderer: tv.renderer
            )
            iv.workspaceController = self
            contentContainer.addSubview(iv)
            inspectorView = iv
        }

        if dividerView == nil {
            let dv = DividerView(
                frame: NSRect(x: 0, y: inspectorHeight, width: bounds.width, height: dividerHeight)
            )
            dv.workspaceController = self
            contentContainer.addSubview(dv)
            dividerView = dv
        }

        inspectorView?.isHidden = false
        dividerView?.isHidden = false
        inspectorVisible = true
        layoutInspector()
    }

    private func hideInspector() {
        let idx = workspace.selectedIndex
        if idx >= 0, workspace.tabIsTerminal(at: idx) {
            if let surface = surfacesBySurface[workspace.tabSurface(at: idx)] {
                surface.lockTerminal()
                if surface.inspectorActive { surface.toggleInspector() }
                surface.unlockTerminal()
            }
        }
        hideInspectorViews()
    }

    /// Hide inspector views without toggling Cot state (used during tab switching).
    private func hideInspectorViews() {
        inspectorView?.isHidden = true
        dividerView?.isHidden = true
        inspectorVisible = false
        if let view = selectedView {
            view.autoresizingMask = [.width, .height]
            view.frame = contentContainer.bounds
        }
    }

    func setInspectorHeight(_ newHeight: CGFloat) {
        let bounds = contentContainer.bounds
        inspectorHeight = max(80, min(newHeight, bounds.height - 100 - dividerHeight))
        layoutInspector()
    }

    private func layoutInspector() {
        guard inspectorVisible, let view = selectedView else { return }
        let bounds = contentContainer.bounds
        let maxInspector = bounds.height - 100 - dividerHeight
        if inspectorHeight > maxInspector { inspectorHeight = max(80, maxInspector) }
        let termHeight = bounds.height - inspectorHeight - dividerHeight

        inspectorView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: inspectorHeight)
        dividerView?.frame = NSRect(x: 0, y: inspectorHeight, width: bounds.width, height: dividerHeight)
        view.autoresizingMask = []
        view.frame = NSRect(x: 0, y: inspectorHeight + dividerHeight, width: bounds.width, height: termHeight)
    }

    func notifyInspectorRender() {
        guard inspectorVisible, let inspectorView else { return }
        inspectorView.renderFrame()
    }

    // MARK: - File I/O

    func loadFile(_ url: URL, surfaceHandle: cotty_surface_t) {
        guard let ev = viewsBySurface[surfaceHandle] as? EditorView,
              let surface = surfacesBySurface[surfaceHandle] else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            surface.loadContent(content)
            ev.resetScroll()
            filePathsBySurface[surfaceHandle] = url
            updateEditorChrome()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc func saveDocument(_ sender: Any) {
        let idx = workspace.selectedIndex
        guard idx >= 0, !workspace.tabIsTerminal(at: idx) else { return }
        let surfaceHandle = workspace.tabSurface(at: idx)
        if let path = filePathsBySurface[surfaceHandle] {
            saveToFile(path, surfaceHandle: surfaceHandle)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any) {
        let idx = workspace.selectedIndex
        guard idx >= 0, !workspace.tabIsTerminal(at: idx) else { return }
        let surfaceHandle = workspace.tabSurface(at: idx)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filePathsBySurface[surfaceHandle]?.lastPathComponent ?? "Untitled.cot"
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.saveToFile(url, surfaceHandle: surfaceHandle)
        }
    }

    private func saveToFile(_ url: URL, surfaceHandle: cotty_surface_t) {
        guard let surface = surfacesBySurface[surfaceHandle] else { return }
        let content = surface.bufferContent
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            surface.setClean()
            filePathsBySurface[surfaceHandle] = url
            updateEditorChrome()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    // MARK: - File Tree

    func updateWorkspaceRoot(from pwd: String) {
        guard workspace.rootURL == nil else { return }
        guard let url = URL(string: pwd) else { return }
        let localURL = url.isFileURL ? url : URL(fileURLWithPath: url.path)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        workspace.rootURL = localURL
        fileTreeView.rootURL = localURL
    }

    @objc func openFolder(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.workspace.rootURL = url
            self.fileTreeView.rootURL = url
        }
    }

    @objc func toggleSidebar(_ sender: Any) {
        if workspace.sidebarVisible {
            sidebarContainer.isHidden = true
            workspace.sidebarVisible = false
        } else {
            sidebarContainer.isHidden = false
            splitView.setPosition(CGFloat(workspace.sidebarWidth), ofDividerAt: 0)
            workspace.sidebarVisible = true
        }
    }

    func fileTree(_ tree: FileTreeView, didSelect url: URL) {
        let previewIdx = workspace.previewTabIndex
        if previewIdx >= 0 {
            // Reuse existing preview tab
            let handle = workspace.tabSurface(at: previewIdx)
            loadFile(url, surfaceHandle: handle)
            selectTab(at: previewIdx)
            return
        }
        // Open new preview tab
        addEditorTab(fileURL: url, isPreview: true)
    }

    func fileTree(_ tree: FileTreeView, didDoubleClick url: URL) {
        let previewIdx = workspace.previewTabIndex
        if previewIdx >= 0 {
            let handle = workspace.tabSurface(at: previewIdx)
            loadFile(url, surfaceHandle: handle)
            pinTab(at: previewIdx)
            selectTab(at: previewIdx)
        } else {
            addEditorTab(fileURL: url, isPreview: false)
        }
    }

    // MARK: - TabBarDelegate

    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int) {
        selectTab(at: index)
    }

    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabBar(_ tabBar: TabBarView, didDoubleClickTabAt index: Int) {
        guard index >= 0, index < workspace.tabCount else { return }
        if workspace.tabIsPreview(at: index) { pinTab(at: index) }
    }

    func tabBar(_ tabBar: TabBarView, didMoveTabFrom oldIndex: Int, to newIndex: Int) {
        guard oldIndex >= 0, oldIndex < workspace.tabCount else { return }
        workspace.moveTab(from: oldIndex, to: newIndex)
        reloadTabBar()
    }

    func tabBarDidClickAddButton(_ tabBar: TabBarView) {
        addTerminalTab()
    }

    // MARK: - Command Palette

    @objc func toggleCommandPalette(_ sender: Any?) {
        if let pv = paletteView, !pv.isHidden {
            pv.dismiss()
            return
        }
        if paletteView == nil {
            let pv = CommandPaletteView(frame: .zero)
            pv.workspaceController = self
            window?.contentView?.addSubview(pv)
            paletteView = pv
        }
        paletteView?.show()
    }

    func paletteDidDismiss() {
        window?.makeFirstResponder(selectedView)
    }

    // MARK: - Theme Selector

    @objc func showThemeSelector(_ sender: Any?) {
        if let tv = themeSelectorView, !tv.isHidden {
            tv.dismiss()
            return
        }
        if themeSelectorView == nil {
            let tv = ThemeSelectorView(frame: .zero)
            tv.workspaceController = self
            window?.contentView?.addSubview(tv)
            themeSelectorView = tv
        }
        themeSelectorView?.show()
    }

    func themeSelectorDidDismiss() {
        window?.makeFirstResponder(selectedView)
    }

    /// Refresh Theme.shared from already-updated FFI config (no disk reload) and rebuild views.
    func applyThemeChange() {
        Theme.shared.load()
        window?.backgroundColor = Theme.shared.background
        for (_, view) in viewsBySurface {
            if let tv = view as? TerminalView {
                tv.renderer.rebuildAtlas()
                tv.setFrameSize(tv.frame.size)
            }
        }
    }

    func executePaletteAction(tag: Int) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        switch tag {
        case 1: delegate.newWindow(self)
        case 2: delegate.newTerminal(self)
        case 3: delegate.newEditor(self)
        case 4: toggleSidebar(self)
        case 5: toggleTerminalInspector(self)
        case 6: reloadConfig(self)
        case 7: increaseFontSize(self)
        case 8: decreaseFontSize(self)
        case 9: resetFontSize(self)
        case 10: closeTab(at: workspace.selectedIndex)
        case 11: showThemeSelector(self)
        default: break
        }
    }

    // MARK: - Font Size

    @objc func increaseFontSize(_ sender: Any?) {
        adjustFontSize(to: Theme.shared.fontSize + 1)
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        adjustFontSize(to: Theme.shared.fontSize - 1)
    }

    @objc func resetFontSize(_ sender: Any?) {
        // Reload config to get the default font size, then apply it
        Theme.shared.reload()
        // rebuildAtlas is needed since reload changed the theme
        for (_, view) in viewsBySurface {
            if let tv = view as? TerminalView {
                tv.renderer.rebuildAtlas()
                tv.setFrameSize(tv.frame.size)
            }
        }
        window?.backgroundColor = Theme.shared.background
    }

    private func adjustFontSize(to size: CGFloat) {
        Theme.shared.setFontSize(size)
        // Rebuild atlas on all terminal views in this window
        for (_, view) in viewsBySurface {
            if let tv = view as? TerminalView {
                tv.renderer.rebuildAtlas()
                tv.setFrameSize(tv.frame.size)
            }
        }
        window?.backgroundColor = Theme.shared.background
    }

    // MARK: - Split Panes

    @objc func splitRight(_ sender: Any?) {
        performSplit(direction: 1) // SPLIT_HORIZONTAL
    }

    @objc func splitDown(_ sender: Any?) {
        performSplit(direction: 2) // SPLIT_VERTICAL
    }

    private func performSplit(direction: Int) {
        guard let app = workspace.app else { return }
        let (rows, cols) = terminalGridSizeForContent()
        let surfaceHandle = workspace.split(direction: direction, rows: rows, cols: cols)
        guard surfaceHandle > 0 else { return }
        let surface = CottySurface(app: app, handle: surfaceHandle)
        let tv = TerminalView(frame: contentContainer.bounds, surface: surface)
        tv.workspaceController = self
        viewsBySurface[surfaceHandle] = tv
        surfacesBySurface[surfaceHandle] = surface
        rebuildSplitLayout()
    }

    func rebuildSplitLayout() {
        let idx = workspace.selectedIndex
        guard idx >= 0, idx < workspace.tabCount else { return }

        if !workspace.isSplit {
            // Single view — remove split container, show view directly
            for sub in contentContainer.subviews {
                if sub is SplitContainerView { sub.removeFromSuperview() }
            }
            if let view = selectedView {
                view.isHidden = false
                view.autoresizingMask = [.width, .height]
                if view.superview !== contentContainer {
                    contentContainer.addSubview(view)
                }
                view.frame = contentContainer.bounds
                window?.makeFirstResponder(view)
            }
            return
        }

        // Hide all views and suppress rendering during layout rebuild.
        // Views stay hidden until rendered at their final size to prevent
        // the Metal layer stretching old content into the new frame.
        for (_, view) in viewsBySurface {
            view.isHidden = true
            (view as? TerminalView)?.suppressRender = true
        }

        // Build split container
        let container = SplitContainerView(frame: contentContainer.bounds)
        container.workspaceController = self
        // Remove old split containers
        for sub in contentContainer.subviews {
            if sub is SplitContainerView { sub.removeFromSuperview() }
        }
        contentContainer.addSubview(container)

        // Add views to split (still hidden) — NSSplitView sets their frames
        container.rebuild(workspace: workspace) { [weak self] handle in
            guard let self else { return nil }
            let view = self.viewsBySurface[handle]
            if let tv = view as? TerminalView {
                tv.removeFromSuperview()
            } else {
                view?.removeFromSuperview()
            }
            return view
        }

        // Now render each view at its final size, then unhide
        for (_, view) in viewsBySurface {
            if let tv = view as? TerminalView, tv.superview != nil {
                tv.suppressRender = false
                tv.setFrameSize(tv.frame.size)
                tv.isHidden = false
            }
        }

        // Focus the active split's terminal
        let focusedHandle = workspace.focusedSurface
        if let focusView = viewsBySurface[focusedHandle] {
            window?.makeFirstResponder(focusView)
        }
    }

    /// Resize all visible terminal views (called after split divider drag).
    func resizeTerminalViewsInSplits() {
        for (_, view) in viewsBySurface {
            if let tv = view as? TerminalView, !tv.isHidden, tv.superview != nil {
                tv.setFrameSize(tv.frame.size)
            }
        }
    }

    @objc func focusSplitRight(_ sender: Any?) {
        workspace.splitMoveFocus(direction: 1)
        focusActiveSplit()
    }

    @objc func focusSplitDown(_ sender: Any?) {
        workspace.splitMoveFocus(direction: 2)
        focusActiveSplit()
    }

    @objc func focusSplitLeft(_ sender: Any?) {
        workspace.splitMoveFocus(direction: 3)
        focusActiveSplit()
    }

    @objc func focusSplitUp(_ sender: Any?) {
        workspace.splitMoveFocus(direction: 4)
        focusActiveSplit()
    }

    private func focusActiveSplit() {
        let handle = workspace.focusedSurface
        if let view = viewsBySurface[handle] {
            window?.makeFirstResponder(view)
        }
    }

    /// Look up a view by its surface handle (used by SplitContainerView).
    func viewForSurface(_ handle: cotty_surface_t) -> NSView? {
        viewsBySurface[handle]
    }

    // MARK: - Config Reload

    @objc func reloadConfig(_ sender: Any?) {
        Theme.shared.reload()
        window?.backgroundColor = Theme.shared.background
        for (_, view) in viewsBySurface {
            if let tv = view as? TerminalView {
                tv.renderer.rebuildAtlas()
                tv.setFrameSize(tv.frame.size)
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        if inspectorVisible { layoutInspector() }
    }

    func windowWillClose(_ notification: Notification) {
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.workspaceControllerDidClose(self)
        }
    }
}

// MARK: - Divider View

/// Thin draggable divider between terminal and inspector.
class DividerView: NSView {
    weak var workspaceController: WorkspaceWindowController?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.25, alpha: 1.0).setFill()
        bounds.fill()
        NSColor(white: 0.35, alpha: 1.0).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseDragged(with event: NSEvent) {
        guard let contentView = superview else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        workspaceController?.setInspectorHeight(point.y)
    }
}
