import AppKit
import CCottyCore

/// Overlay command palette view — positioned at top-center of window.
/// Dark semi-transparent background, search field, scrolling results list.
/// All filtering and action registry lives in Cot; Swift just renders.
class CommandPaletteView: NSView {
    weak var workspaceController: WorkspaceWindowController?

    private let searchField = NSTextField()
    private let resultsContainer = NSScrollView()
    private let resultsStack = NSStackView()

    private static let maxWidth: CGFloat = 500
    private static let maxResults = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor

        setupSearchField()
        setupResultsList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupSearchField() {
        searchField.placeholderString = "Type a command..."
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.textColor = .white
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func setupResultsList() {
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 0
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        resultsContainer.drawsBackground = false
        resultsContainer.hasVerticalScroller = false
        resultsContainer.borderType = .noBorder
        resultsContainer.documentView = resultsStack
        resultsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultsContainer)

        NSLayoutConstraint.activate([
            resultsContainer.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            resultsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            resultsStack.leadingAnchor.constraint(equalTo: resultsContainer.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: resultsContainer.trailingAnchor),
        ])
    }

    // MARK: - Show / Hide

    func show() {
        cotty_palette_toggle()
        searchField.stringValue = ""
        isHidden = false
        reloadResults()
        window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        cotty_palette_dismiss()
        isHidden = true
        workspaceController?.paletteDidDismiss()
    }

    // MARK: - Results

    func reloadResults() {
        // Clear old results
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let count = Int(cotty_palette_result_count())
        let selected = Int(cotty_palette_selected())
        let maxShow = min(count, Self.maxResults)

        for i in 0..<maxShow {
            let titlePtr = cotty_palette_result_title(Int64(i))
            let titleLen = cotty_palette_result_title_len(Int64(i))
            var title = ""
            if titlePtr != 0 && titleLen > 0,
               let ptr = UnsafeRawPointer(bitPattern: Int(titlePtr)) {
                let data = Data(bytes: ptr, count: Int(titleLen))
                title = String(data: data, encoding: .utf8) ?? ""
            }

            let row = PaletteRowView(title: title, isSelected: i == selected, index: i)
            row.target = self
            row.action = #selector(rowClicked(_:))
            row.translatesAutoresizingMaskIntoConstraints = false
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        }

        // Resize height based on content
        let rowHeight: CGFloat = 28
        let contentHeight = 8 + 28 + 4 + CGFloat(maxShow) * rowHeight + 4
        let parent = superview?.bounds ?? NSRect(x: 0, y: 0, width: 600, height: 400)
        let w = min(Self.maxWidth, parent.width - 40)
        let x = (parent.width - w) / 2
        let y = parent.height - contentHeight - 40
        frame = NSRect(x: x, y: y, width: w, height: contentHeight)
    }

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: Any?) {
        let query = searchField.stringValue
        query.utf8.withContiguousStorageIfAvailable { buf in
            cotty_palette_set_query(buf.baseAddress, Int64(buf.count))
        }
        reloadResults()
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let row = sender as? PaletteRowView else { return }
        executeSelected(at: row.index)
    }

    func executeSelected(at index: Int? = nil) {
        let idx = index ?? Int(cotty_palette_selected())
        let tag = Int(cotty_palette_result_tag(Int64(idx)))
        dismiss()
        workspaceController?.executePaletteAction(tag: tag)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            dismiss()
        case 125: // Down arrow
            cotty_palette_move_down()
            reloadResults()
        case 126: // Up arrow
            cotty_palette_move_up()
            reloadResults()
        case 36: // Return
            executeSelected()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Escape
            dismiss()
            return true
        }
        if event.keyCode == 125 || event.keyCode == 126 { // Arrow keys
            keyDown(with: event)
            return true
        }
        if event.keyCode == 36 { // Return
            executeSelected()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NSTextFieldDelegate for live filtering

extension CommandPaletteView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchFieldChanged(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            cotty_palette_move_down()
            reloadResults()
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            cotty_palette_move_up()
            reloadResults()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            executeSelected()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }
}

// MARK: - Palette Row View

private class PaletteRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    var target: AnyObject?
    var action: Selector?
    let isSelected: Bool
    let index: Int

    init(title: String, isSelected: Bool, index: Int) {
        self.isSelected = isSelected
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        if isSelected {
            layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        }
        titleLabel.stringValue = title
        titleLabel.textColor = isSelected ? .white : NSColor(white: 0.85, alpha: 1)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if let target = target as? NSObject, let action {
            target.perform(action, with: self)
        }
    }
}
