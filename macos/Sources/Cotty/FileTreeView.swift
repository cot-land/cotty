import AppKit

protocol FileTreeDelegate: AnyObject {
    func fileTree(_ tree: FileTreeView, didSelect url: URL)
    func fileTree(_ tree: FileTreeView, didDoubleClick url: URL)
}

/// Sidebar file tree using NSOutlineView.
class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: FileTreeDelegate?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()

    var rootURL: URL? {
        didSet {
            rootChildren = nil
            childrenCache.removeAll()
            if let url = rootURL {
                rootChildren = loadChildren(of: url)
            }
            outlineView.reloadData()
        }
    }

    private var rootChildren: [URL]?
    private var childrenCache: [URL: [URL]] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Files"
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.target = self
        outlineView.action = #selector(onRowClick)
        outlineView.doubleAction = #selector(onRowDoubleClick)

        // Style
        outlineView.backgroundColor = .clear
        if #available(macOS 11.0, *) {
            outlineView.style = .sourceList
        }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - Data

    private func loadChildren(of url: URL) -> [URL] {
        if let cached = childrenCache[url] { return cached }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sorted = contents.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
        childrenCache[url] = sorted
        return sorted
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootChildren?.count ?? 0 }
        guard let url = item as? URL, isDirectory(url) else { return 0 }
        return loadChildren(of: url).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootChildren![index] }
        return loadChildren(of: item as! URL)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let url = item as? URL else { return false }
        return isDirectory(url)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let url = item as? URL else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
            ?? makeCellView(id: id)

        cell.textField?.stringValue = url.lastPathComponent
        cell.textField?.textColor = .secondaryLabelColor
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
        cell.imageView?.image?.size = NSSize(width: 16, height: 16)
        return cell
    }

    private func makeCellView(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id

        let imageView = NSImageView()
        let textField = NSTextField(labelWithString: "")
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail

        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    // MARK: - Click

    @objc private func onRowClick() {
        let row = outlineView.clickedRow
        guard row >= 0, let url = outlineView.item(atRow: row) as? URL else { return }
        if !isDirectory(url) {
            delegate?.fileTree(self, didSelect: url)
        }
    }

    @objc private func onRowDoubleClick() {
        let row = outlineView.clickedRow
        guard row >= 0, let url = outlineView.item(atRow: row) as? URL else { return }
        if !isDirectory(url) {
            delegate?.fileTree(self, didDoubleClick: url)
        }
    }
}
