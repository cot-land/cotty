import AppKit
import CCottyCore
import Foundation

/// Overlay project-wide search view — Cmd+Shift+F.
/// Shows a search field and results grouped by file with line previews.
class ProjectSearchView: NSView {
    weak var workspaceController: WorkspaceWindowController?

    private let searchField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultsScroll = NSScrollView()
    private let resultsStack = NSStackView()

    private static let maxWidth: CGFloat = 620
    private static let maxHeight: CGFloat = 500
    private static let maxResults = 50

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor

        setupSearchField()
        setupStatusLabel()
        setupResultsList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupSearchField() {
        searchField.placeholderString = "Search in project..."
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

    private func setupStatusLabel() {
        statusLabel.textColor = NSColor(white: 0.5, alpha: 1)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    private func setupResultsList() {
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = 0
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        resultsScroll.drawsBackground = false
        resultsScroll.hasVerticalScroller = true
        resultsScroll.scrollerStyle = .overlay
        resultsScroll.autohidesScrollers = true
        resultsScroll.borderType = .noBorder
        resultsScroll.documentView = resultsStack
        resultsScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultsScroll)

        NSLayoutConstraint.activate([
            resultsScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            resultsScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultsScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultsScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            resultsStack.leadingAnchor.constraint(equalTo: resultsScroll.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: resultsScroll.trailingAnchor),
        ])
    }

    // MARK: - Show / Hide

    func show(rootPath: String) {
        rootPath.utf8.withContiguousStorageIfAvailable { buf in
            cotty_project_search_open(Int64(Int(bitPattern: buf.baseAddress)), Int64(buf.count))
        }
        searchField.stringValue = ""
        statusLabel.stringValue = ""
        isHidden = false
        reloadResults()
        layoutInParent()
        window?.makeFirstResponder(searchField)
    }

    func dismiss() {
        cotty_project_search_close()
        isHidden = true
        workspaceController?.projectSearchDidDismiss()
    }

    private func layoutInParent() {
        let parent = superview?.bounds ?? NSRect(x: 0, y: 0, width: 600, height: 400)
        let w = min(Self.maxWidth, parent.width - 40)
        let h = min(Self.maxHeight, parent.height - 80)
        let x = (parent.width - w) / 2
        let y = parent.height - h - 40
        frame = NSRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Results

    func reloadResults() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let totalMatches = Int(cotty_project_search_total_matches())
        let fileCount = Int(cotty_project_search_file_count())
        let flatCount = Int(cotty_project_search_flat_count())
        let selected = Int(cotty_project_search_selected())

        if totalMatches > 0 {
            statusLabel.stringValue = "\(totalMatches) results in \(fileCount) files"
        } else if searchField.stringValue.isEmpty {
            statusLabel.stringValue = ""
        } else {
            statusLabel.stringValue = "No results"
        }

        let maxShow = min(flatCount, Self.maxResults)
        var lastFileIdx: Int = -1

        for i in 0..<maxShow {
            let fileIdx = Int(cotty_project_search_flat_file_index(Int64(i)))

            // Add file header when we enter a new file
            if fileIdx != lastFileIdx {
                let relPtr = cotty_project_search_file_rel_path(Int64(fileIdx))
                let relLen = cotty_project_search_file_rel_path_len(Int64(fileIdx))
                var relPath = ""
                if relPtr != 0, relLen > 0, let ptr = UnsafeRawPointer(bitPattern: Int(relPtr)) {
                    relPath = String(data: Data(bytes: ptr, count: Int(relLen)), encoding: .utf8) ?? ""
                }
                let matchCount = Int(cotty_project_search_file_match_count(Int64(fileIdx)))
                let header = SearchFileHeaderView(path: relPath, matchCount: matchCount)
                header.translatesAutoresizingMaskIntoConstraints = false
                resultsStack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
                lastFileIdx = fileIdx
            }

            // Add match row
            let lineNum = Int(cotty_project_search_flat_line_num(Int64(i)))
            let textPtr = cotty_project_search_flat_line_text(Int64(i))
            let textLen = cotty_project_search_flat_line_text_len(Int64(i))
            var lineText = ""
            if textPtr != 0, textLen > 0, let ptr = UnsafeRawPointer(bitPattern: Int(textPtr)) {
                lineText = String(data: Data(bytes: ptr, count: Int(textLen)), encoding: .utf8) ?? ""
            }
            lineText = lineText.trimmingCharacters(in: .whitespaces)

            let row = SearchMatchRowView(
                lineNum: lineNum,
                text: lineText,
                isSelected: i == selected,
                flatIndex: i
            )
            row.target = self
            row.action = #selector(matchClicked(_:))
            row.translatesAutoresizingMaskIntoConstraints = false
            resultsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: resultsStack.widthAnchor).isActive = true
        }

        // Update scroll content size
        let contentH = resultsStack.fittingSize.height
        resultsStack.frame.size.height = contentH
    }

    // MARK: - Actions

    @objc private func searchFieldChanged(_ sender: Any?) {
        let query = searchField.stringValue
        query.utf8.withContiguousStorageIfAvailable { buf in
            cotty_project_search_set_query(buf.baseAddress, Int64(buf.count))
        }
        reloadResults()
    }

    @objc private func matchClicked(_ sender: Any?) {
        guard let row = sender as? SearchMatchRowView else { return }
        openMatch(at: row.flatIndex)
    }

    func openMatch(at flatIndex: Int? = nil) {
        let idx = flatIndex ?? Int(cotty_project_search_selected())
        let fileIdx = Int(cotty_project_search_flat_file_index(Int64(idx)))
        let lineNum = Int(cotty_project_search_flat_line_num(Int64(idx)))

        let pathPtr = cotty_project_search_file_full_path(Int64(fileIdx))
        let pathLen = cotty_project_search_file_full_path_len(Int64(fileIdx))
        guard pathPtr != 0, pathLen > 0,
              let ptr = UnsafeRawPointer(bitPattern: Int(pathPtr)),
              let path = String(data: Data(bytes: ptr, count: Int(pathLen)), encoding: .utf8)
        else { return }

        dismiss()
        let url = URL(fileURLWithPath: path)
        workspaceController?.openFileFromSearch(url, lineNum: lineNum)
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss()
        case 125: cotty_project_search_move_down(); reloadResults()
        case 126: cotty_project_search_move_up(); reloadResults()
        case 36: openMatch()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { dismiss(); return true }
        if event.keyCode == 125 || event.keyCode == 126 { keyDown(with: event); return true }
        if event.keyCode == 36 { openMatch(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - NSTextFieldDelegate

extension ProjectSearchView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchFieldChanged(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            cotty_project_search_move_down(); reloadResults(); return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            cotty_project_search_move_up(); reloadResults(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            openMatch(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(); return true
        }
        return false
    }
}

// MARK: - File Header View

private class SearchFileHeaderView: NSView {
    init(path: String, matchCount: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor

        let label = NSTextField(labelWithString: "\(path)  (\(matchCount))")
        label.textColor = NSColor(red: 0.6, green: 0.75, blue: 1.0, alpha: 1)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Match Row View

private class SearchMatchRowView: NSView {
    var target: AnyObject?
    var action: Selector?
    let flatIndex: Int

    init(lineNum: Int, text: String, isSelected: Bool, flatIndex: Int) {
        self.flatIndex = flatIndex
        super.init(frame: .zero)
        wantsLayer = true
        if isSelected {
            layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        }

        let numLabel = NSTextField(labelWithString: "\(lineNum)")
        numLabel.textColor = NSColor(white: 0.4, alpha: 1)
        numLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        numLabel.alignment = .right
        numLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(numLabel)

        let textLabel = NSTextField(labelWithString: text)
        textLabel.textColor = isSelected ? .white : NSColor(white: 0.8, alpha: 1)
        textLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textLabel)

        NSLayoutConstraint.activate([
            numLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            numLabel.widthAnchor.constraint(equalToConstant: 40),
            numLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: numLabel.trailingAnchor, constant: 8),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
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
