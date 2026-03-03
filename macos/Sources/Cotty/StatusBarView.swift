import AppKit
import CCottyCore

/// Native status bar at the bottom of the workspace window (Zed-style).
/// Displays mode indicator, cursor position, and language label.
class StatusBarView: NSView {
    static let barHeight: CGFloat = 28

    // Left items
    private let sidebarToggleButton: NSButton
    private let modeIndicator: ModeIndicatorView

    // Right items
    private let positionLabel: NSTextField
    private let languageLabel: NSTextField

    // Layout stacks
    private let leftStack: NSStackView
    private let rightStack: NSStackView

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        // Sidebar toggle button
        sidebarToggleButton = NSButton(frame: .zero)
        sidebarToggleButton.bezelStyle = .accessoryBarAction
        sidebarToggleButton.isBordered = false
        sidebarToggleButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
        sidebarToggleButton.contentTintColor = .init(white: 0.6, alpha: 1.0)
        sidebarToggleButton.action = #selector(WorkspaceWindowController.toggleSidebar(_:))
        sidebarToggleButton.setContentHuggingPriority(.required, for: .horizontal)

        // Mode indicator pill
        modeIndicator = ModeIndicatorView()
        modeIndicator.setContentHuggingPriority(.required, for: .horizontal)

        // Position label (Ln X, Col Y)
        positionLabel = Self.makeLabel("Ln 1, Col 0")
        languageLabel = Self.makeLabel("Cot")

        // Stacks
        leftStack = NSStackView(views: [sidebarToggleButton, modeIndicator])
        leftStack.orientation = .horizontal
        leftStack.spacing = 6
        leftStack.alignment = .centerY
        leftStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)

        rightStack = NSStackView(views: [positionLabel, languageLabel])
        rightStack.orientation = .horizontal
        rightStack.spacing = 14
        rightStack.alignment = .centerY
        rightStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)

        super.init(frame: frame)
        wantsLayer = true

        leftStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Dark background
        NSColor(red: 37/255.0, green: 37/255.0, blue: 38/255.0, alpha: 1.0).setFill()
        bounds.fill()
        // 1px top separator
        NSColor(white: 0.2, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func update(mode: Int, cursorLine: Int, cursorCol: Int, isTerminal: Bool) {
        if isTerminal {
            modeIndicator.isHidden = true
            positionLabel.isHidden = true
            languageLabel.stringValue = "Terminal"
        } else {
            modeIndicator.isHidden = false
            positionLabel.isHidden = false
            positionLabel.stringValue = "Ln \(cursorLine + 1), Col \(cursorCol)"
            languageLabel.stringValue = "Cot"
            modeIndicator.update(mode: mode)
        }
    }

    private static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor(white: 0.55, alpha: 1.0)
        label.isSelectable = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
}

// MARK: - Mode Indicator Pill

/// Small colored pill showing the current editor mode (NOR/INS/SEL).
private class ModeIndicatorView: NSView {
    private let label: NSTextField
    private var modeColor = NSColor(red: 0.39, green: 0.59, blue: 1.0, alpha: 1.0) // Blue for NOR

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        return NSSize(width: labelSize.width + 12, height: 18)
    }

    override init(frame: NSRect) {
        label = NSTextField(labelWithString: "NOR")
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.isSelectable = false

        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        modeColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        path.fill()
    }

    func update(mode: Int) {
        switch mode {
        case Int(COTTY_MODE_NORMAL):
            label.stringValue = "NOR"
            modeColor = NSColor(red: 0.39, green: 0.59, blue: 1.0, alpha: 1.0)
        case Int(COTTY_MODE_INSERT):
            label.stringValue = "INS"
            modeColor = NSColor(red: 0.39, green: 0.78, blue: 0.39, alpha: 1.0)
        case Int(COTTY_MODE_SELECT):
            label.stringValue = "SEL"
            modeColor = NSColor(red: 1.0, green: 0.59, blue: 0.39, alpha: 1.0)
        default:
            break
        }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
}
