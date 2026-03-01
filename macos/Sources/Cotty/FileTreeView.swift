import AppKit
import CCottyCore

protocol FileTreeDelegate: AnyObject {
    func fileTree(_ tree: FileTreeView, didSelect url: URL)
    func fileTree(_ tree: FileTreeView, didDoubleClick url: URL)
}

/// Custom-drawn file tree view. All tree logic lives in Cot (CottyFileTree).
/// Swift only draws rows and forwards mouse events.
class FileTreeView: NSView {
    weak var delegate: FileTreeDelegate?

    private let scrollView = NSScrollView()
    private let contentView = FileTreeContentView()
    fileprivate var fileTree: CottyFileTree?

    // Layout constants (Zed-style)
    fileprivate static let rowHeight: CGFloat = 26
    fileprivate static let indentWidth: CGFloat = 20
    fileprivate static let leftPad: CGFloat = 12
    fileprivate static let iconSize: CGFloat = 15
    fileprivate static let gapAfterIcon: CGFloat = 6
    fileprivate static let selectionInsetX: CGFloat = 4
    fileprivate static let selectionRadius: CGFloat = 4

    // Colors (Zed dark theme)
    fileprivate static let bgColor = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
    fileprivate static let selectedColor = NSColor(red: 0.18, green: 0.20, blue: 0.24, alpha: 1)
    fileprivate static let hoverColor = NSColor(red: 0.14, green: 0.14, blue: 0.14, alpha: 1)
    fileprivate static let textColor = NSColor(red: 0.75, green: 0.78, blue: 0.82, alpha: 1)
    fileprivate static let iconTint = NSColor(red: 0.45, green: 0.50, blue: 0.55, alpha: 1)
    fileprivate static let guideColor = NSColor(red: 0.25, green: 0.27, blue: 0.30, alpha: 0.40)

    fileprivate var textFont: NSFont = {
        let theme = Theme.shared
        if theme.uiFontName.isEmpty {
            return NSFont.systemFont(ofSize: theme.uiFontSize, weight: .regular)
        }
        return NSFont(name: theme.uiFontName, size: theme.uiFontSize)
            ?? NSFont.systemFont(ofSize: theme.uiFontSize, weight: .regular)
    }()

    var rootURL: URL? {
        didSet {
            if let url = rootURL {
                let path = url.path
                if let ft = fileTree {
                    ft.setRoot(path)
                } else {
                    fileTree = CottyFileTree(rootPath: path)
                }
            } else {
                fileTree = nil
            }
            contentView.owner = self
            updateContentSize()
            contentView.needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        contentView.owner = self

        scrollView.documentView = contentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.backgroundColor = Self.bgColor

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    fileprivate func updateContentSize() {
        let rows = fileTree?.rowCount ?? 0
        let height = max(CGFloat(rows) * Self.rowHeight, scrollView.contentSize.height)
        contentView.frame = NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: height)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updateContentSize()
    }

    // MARK: - Row hit testing

    fileprivate func rowAt(point: NSPoint) -> Int {
        let row = Int(point.y / Self.rowHeight)
        guard let ft = fileTree, row >= 0, row < ft.rowCount else { return -1 }
        return row
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let pt = contentView.convert(event.locationInWindow, from: nil)
        let row = rowAt(point: pt)
        guard row >= 0, let ft = fileTree else { return }

        let isDir = ft.rowIsDir(at: row)

        if isDir {
            ft.toggleExpand(at: row)
            ft.selectRow(row)
            updateContentSize()
            contentView.needsDisplay = true
        } else {
            ft.selectRow(row)
            contentView.needsDisplay = true
            let path = ft.rowPath(at: row)
            if !path.isEmpty {
                delegate?.fileTree(self, didSelect: URL(fileURLWithPath: path))
            }
        }

        if event.clickCount == 2 && !isDir {
            let path = ft.rowPath(at: row)
            if !path.isEmpty {
                delegate?.fileTree(self, didDoubleClick: URL(fileURLWithPath: path))
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = contentView.convert(event.locationInWindow, from: nil)
        let row = rowAt(point: pt)
        if row != contentView.hoverRow {
            contentView.hoverRow = row
            contentView.needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if contentView.hoverRow != -1 {
            contentView.hoverRow = -1
            contentView.needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }
}

// MARK: - Content View (flipped, custom draw)

private class FileTreeContentView: NSView {
    weak var owner: FileTreeView?
    var hoverRow: Int = -1

    override var isFlipped: Bool { true }

    /// Draw an SF Symbol tinted to a specific color.
    private func drawTintedSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .regular)
        guard let configured = img.withSymbolConfiguration(config) else { return }

        // Create a tinted copy by drawing into a temporary image with sourceAtop compositing
        let tinted = NSImage(size: rect.size, flipped: false) { drawRect in
            configured.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            color.setFill()
            drawRect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner = owner, let ft = owner.fileTree else {
            FileTreeView.bgColor.setFill()
            dirtyRect.fill()
            return
        }

        // Background
        FileTreeView.bgColor.setFill()
        dirtyRect.fill()

        let rowHeight = FileTreeView.rowHeight
        let totalRows = ft.rowCount
        guard totalRows > 0 else { return }

        let firstRow = max(0, Int(dirtyRect.minY / rowHeight))
        let lastRow = min(totalRows - 1, Int(dirtyRect.maxY / rowHeight))
        guard firstRow <= lastRow else { return }

        let selectedRow = ft.selectedRow
        let textFont = owner.textFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: FileTreeView.textColor,
        ]

        for row in firstRow...lastRow {
            let y = CGFloat(row) * rowHeight
            let depth = ft.rowDepth(at: row)
            let isDir = ft.rowIsDir(at: row)
            let isExpanded = ft.rowIsExpanded(at: row)
            let name = ft.rowName(at: row)

            // Selection/hover background (rounded rect with horizontal inset)
            if row == selectedRow || row == hoverRow {
                let color = row == selectedRow ? FileTreeView.selectedColor : FileTreeView.hoverColor
                let selRect = NSRect(
                    x: FileTreeView.selectionInsetX,
                    y: y,
                    width: bounds.width - FileTreeView.selectionInsetX * 2,
                    height: rowHeight
                )
                let path = NSBezierPath(roundedRect: selRect, xRadius: FileTreeView.selectionRadius, yRadius: FileTreeView.selectionRadius)
                color.setFill()
                path.fill()
            }

            // Indent guide lines
            if depth > 0 {
                FileTreeView.guideColor.setStroke()
                for d in 0..<depth {
                    let guideX = FileTreeView.leftPad + CGFloat(d) * FileTreeView.indentWidth + FileTreeView.indentWidth / 2
                    let line = NSBezierPath()
                    line.move(to: NSPoint(x: guideX, y: y))
                    line.line(to: NSPoint(x: guideX, y: y + rowHeight))
                    line.lineWidth = 1
                    line.stroke()
                }
            }

            // Content x position
            var x = FileTreeView.leftPad + CGFloat(depth) * FileTreeView.indentWidth

            // Icon — folder.fill/folder for dirs, doc.text for files
            let symbolName: String
            if isDir {
                symbolName = isExpanded ? "folder.fill" : "folder"
            } else {
                symbolName = "doc.text"
            }
            let iconH = FileTreeView.iconSize
            let iconY = y + (rowHeight - iconH) / 2
            let iconRect = NSRect(x: x, y: iconY, width: iconH, height: iconH)
            drawTintedSymbol(symbolName, in: iconRect, color: FileTreeView.iconTint)
            x += FileTreeView.iconSize + FileTreeView.gapAfterIcon

            // Name text — use attributed string size for precise vertical centering
            let str = name as NSString
            let textSize = str.size(withAttributes: attrs)
            let textY = y + (rowHeight - textSize.height) / 2
            str.draw(at: NSPoint(x: x, y: textY), withAttributes: attrs)
        }
    }
}
