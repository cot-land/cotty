import AppKit
import CCottyCore
import Foundation

/// Overlay file finder view — Cmd+P fuzzy file search.
/// Follows the same pattern as CommandPaletteView.
/// All filtering and scoring lives in Cot; Swift just renders.
class FileFinderView: NSView {
    weak var workspaceController: WorkspaceWindowController?

    private let searchField = NSTextField()
    private let resultsContainer = NSScrollView()
    private let resultsStack = NSStackView()

    private static let maxWidth: CGFloat = 560
    private static let maxResults = 15

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
        searchField.placeholderString = "Go to file..."
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

    func show(rootPath: String) {
        rootPath.utf8.withContiguousStorageIfAvailable { buf in
            cotty_file_finder_open(Int64(Int(bitPattern: buf.baseAddress)), Int64(buf.count))
        }
        searchField.stringValue = ""
        isHidden = false
        reloadResults()
        window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        cotty_file_finder_close()
        isHidden = true
        workspaceController?.fileFinderDidDismiss()
    }

    // MARK: - Results

    func reloadResults() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let count = Int(cotty_file_finder_result_count())
        let selected = Int(cotty_file_finder_selected())
        let maxShow = min(count, Self.maxResults)

        for i in 0..<maxShow {
            let namePtr = cotty_file_finder_result_name(Int64(i))
            let nameLen = cotty_file_finder_result_name_len(Int64(i))
            var name = ""
            if namePtr != 0 && nameLen > 0,
               let ptr = UnsafeRawPointer(bitPattern: Int(namePtr)) {
                let data = Data(bytes: ptr, count: Int(nameLen))
                name = String(data: data, encoding: .utf8) ?? ""
            }

            let row = FileFinderRowView(title: name, isSelected: i == selected, index: i)
            row.target = self
            row.action = #selector(rowClicked(_:))
            row.translatesAutoresizingMaskIntoConstraints = false
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        }

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
            cotty_file_finder_set_query(buf.baseAddress, Int64(buf.count))
        }
        reloadResults()
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let row = sender as? FileFinderRowView else { return }
        openSelected(at: row.index)
    }

    func openSelected(at index: Int? = nil) {
        let idx = index ?? Int(cotty_file_finder_selected())
        let pathPtr = cotty_file_finder_result_path(Int64(idx))
        let pathLen = cotty_file_finder_result_path_len(Int64(idx))
        guard pathPtr != 0, pathLen > 0,
              let ptr = UnsafeRawPointer(bitPattern: Int(pathPtr)) else {
            dismiss()
            return
        }
        let data = Data(bytes: ptr, count: Int(pathLen))
        guard let path = String(data: data, encoding: .utf8) else {
            dismiss()
            return
        }
        dismiss()
        let url = URL(fileURLWithPath: path)
        workspaceController?.openFileFromFinder(url)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss()
        case 125: cotty_file_finder_move_down(); reloadResults()
        case 126: cotty_file_finder_move_up(); reloadResults()
        case 36: openSelected()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { dismiss(); return true }
        if event.keyCode == 125 || event.keyCode == 126 { keyDown(with: event); return true }
        if event.keyCode == 36 { openSelected(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NSTextFieldDelegate

extension FileFinderView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchFieldChanged(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            cotty_file_finder_move_down(); reloadResults(); return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            cotty_file_finder_move_up(); reloadResults(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            openSelected(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(); return true
        }
        return false
    }
}

// MARK: - Row View

private class FileFinderRowView: NSView {
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
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle
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
