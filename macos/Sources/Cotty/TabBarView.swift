import AppKit

protocol TabBarDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, didDoubleClickTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, didMoveTabFrom oldIndex: Int, to newIndex: Int)
    func tabBarDidClickAddButton(_ tabBar: TabBarView)
}

/// Chrome-style tab bar. Pill-shaped tabs with favicons, centered text,
/// drag-to-reorder, and integrated into the titlebar area.
class TabBarView: NSView {
    static let barHeight: CGFloat = 36

    weak var delegate: TabBarDelegate?
    private var tabButtons: [TabButton] = []
    private(set) var selectedIndex: Int = -1
    private let addButton = AddTabButton()
    private var currentTabWidth: CGFloat = 0

    // Layout metrics
    private let trafficLightPad: CGFloat = 78
    private let tabVPad: CGFloat = 5       // vertical padding top+bottom within bar
    private let tabGap: CGFloat = 2
    private let tabMaxWidth: CGFloat = 240
    private let tabMinWidth: CGFloat = 50
    private let cornerRadius: CGFloat = 8

    // Drag-to-reorder state
    private struct DragState {
        let originalIndex: Int
        let grabOffset: CGFloat
        var targetIndex: Int
    }
    private var dragState: DragState?

    // MARK: - Colors

    enum Colors {
        static let barBg = NSColor(red: 0.14, green: 0.15, blue: 0.14, alpha: 1)
        static let selectedTab = NSColor(red: 0.20, green: 0.22, blue: 0.20, alpha: 1)
        static let hoverTab = NSColor(white: 0.19, alpha: 1)
        static let border = NSColor(white: 0.08, alpha: 1)
        static let separator = NSColor(white: 0.26, alpha: 0.5)
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Colors.barBg.cgColor

        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - API

    /// Tab info snapshot for display — no reference to WorkspaceTab.
    struct TabInfo {
        let title: String
        let isPreview: Bool
        let isDirty: Bool
        let isTerminal: Bool
    }

    func reloadTabs(_ tabInfos: [TabInfo], selectedIndex: Int) {
        self.selectedIndex = selectedIndex

        while tabButtons.count > tabInfos.count {
            tabButtons.removeLast().removeFromSuperview()
        }
        while tabButtons.count < tabInfos.count {
            let btn = TabButton(cornerRadius: cornerRadius)
            addSubview(btn)
            tabButtons.append(btn)
        }

        for (i, btn) in tabButtons.enumerated() {
            let info = tabInfos[i]
            btn.configure(
                title: info.title,
                isSelected: i == selectedIndex,
                isPreview: info.isPreview,
                isDirty: info.isDirty,
                isTerminal: info.isTerminal
            )
            let idx = i
            btn.onSelect = { [weak self] in
                guard let self else { return }
                self.delegate?.tabBar(self, didSelectTabAt: idx)
            }
            btn.onClose = { [weak self] in
                guard let self else { return }
                self.delegate?.tabBar(self, didCloseTabAt: idx)
            }
            btn.onDoubleClick = { [weak self] in
                guard let self else { return }
                self.delegate?.tabBar(self, didDoubleClickTabAt: idx)
            }
            btn.onDragBegan = { [weak self] event in self?.beginDrag(at: idx, event: event) }
            btn.onDragMoved = { [weak self] event in self?.updateDrag(event: event) }
            btn.onDragEnded = { [weak self] event in self?.endDrag(event: event) }
        }

        layoutTabs()
        needsDisplay = true
    }

    func updateTab(at index: Int, title: String, isDirty: Bool, isPreview: Bool) {
        guard tabButtons.indices.contains(index) else { return }
        let btn = tabButtons[index]
        btn.configure(
            title: title,
            isSelected: btn.currentlySelected,
            isPreview: isPreview,
            isDirty: isDirty,
            isTerminal: btn.currentlyTerminal
        )
    }

    // MARK: - Layout

    private func layoutTabs() {
        let addBtnSize: CGFloat = 28
        let addPad: CGFloat = 4
        let available = max(0, bounds.width - trafficLightPad - addBtnSize - addPad * 2)
        let count = tabButtons.count
        let totalGap = CGFloat(max(0, count - 1)) * tabGap
        let tabW = count > 0
            ? min(tabMaxWidth, max(tabMinWidth, (available - totalGap) / CGFloat(count)))
            : 0
        currentTabWidth = tabW

        let tabH = bounds.height - tabVPad * 2
        var x = trafficLightPad
        for btn in tabButtons {
            btn.frame = NSRect(x: x, y: tabVPad, width: tabW, height: tabH)
            x += tabW + tabGap
        }

        addButton.frame = NSRect(
            x: x + addPad,
            y: (bounds.height - addBtnSize) / 2,
            width: addBtnSize,
            height: addBtnSize
        )
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutTabs()
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Bottom border
        Colors.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // MARK: - Drag-to-Reorder

    private func beginDrag(at index: Int, event: NSEvent) {
        let mouseX = convert(event.locationInWindow, from: nil).x
        let btn = tabButtons[index]
        dragState = DragState(
            originalIndex: index,
            grabOffset: mouseX - btn.frame.origin.x,
            targetIndex: index
        )
        // Lift the tab visually
        btn.layer?.zPosition = 100
        btn.layer?.shadowColor = NSColor.black.cgColor
        btn.layer?.shadowOpacity = 0.6
        btn.layer?.shadowRadius = 8
        btn.layer?.shadowOffset = .zero
        btn.alphaValue = 0.92
    }

    private func updateDrag(event: NSEvent) {
        guard var drag = dragState else { return }
        let mouseX = convert(event.locationInWindow, from: nil).x
        let btn = tabButtons[drag.originalIndex]
        let tabW = currentTabWidth

        // Move dragged tab to follow cursor
        let newX = mouseX - drag.grabOffset
        let minX = trafficLightPad
        let maxX = trafficLightPad + CGFloat(tabButtons.count - 1) * (tabW + tabGap)
        btn.frame.origin.x = max(minX, min(newX, maxX))

        // Calculate target slot
        let midX = btn.frame.midX
        let slot = (midX - trafficLightPad + tabGap / 2) / (tabW + tabGap)
        let newTarget = max(0, min(tabButtons.count - 1, Int(slot)))

        if newTarget != drag.targetIndex {
            drag.targetIndex = newTarget
            dragState = drag
            animateTabsForDrag()
        }
    }

    private func animateTabsForDrag() {
        guard let drag = dragState else { return }
        let tabW = currentTabWidth
        let tabH = bounds.height - tabVPad * 2

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            for (i, btn) in tabButtons.enumerated() {
                if i == drag.originalIndex { continue }

                var visualSlot = i
                if drag.targetIndex < drag.originalIndex {
                    if i >= drag.targetIndex && i < drag.originalIndex {
                        visualSlot = i + 1
                    }
                } else if drag.targetIndex > drag.originalIndex {
                    if i > drag.originalIndex && i <= drag.targetIndex {
                        visualSlot = i - 1
                    }
                }

                let slotX = trafficLightPad + CGFloat(visualSlot) * (tabW + tabGap)
                btn.animator().frame = NSRect(x: slotX, y: tabVPad, width: tabW, height: tabH)
            }
        }
    }

    private func endDrag(event: NSEvent) {
        guard let drag = dragState else { return }
        let btn = tabButtons[drag.originalIndex]
        let tabW = currentTabWidth
        let tabH = bounds.height - tabVPad * 2

        // Drop shadow
        btn.layer?.zPosition = 0
        btn.layer?.shadowOpacity = 0
        btn.alphaValue = 1.0

        // Animate to final slot
        let finalX = trafficLightPad + CGFloat(drag.targetIndex) * (tabW + tabGap)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            btn.animator().frame = NSRect(x: finalX, y: tabVPad, width: tabW, height: tabH)
        })

        if drag.originalIndex != drag.targetIndex {
            delegate?.tabBar(self, didMoveTabFrom: drag.originalIndex, to: drag.targetIndex)
        }

        dragState = nil
    }

    // MARK: - Window Dragging (empty tab bar space)

    override func mouseDown(with event: NSEvent) {
        // Only reaches here when click misses all tabs and the + button.
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }

    @objc private func addClicked() {
        delegate?.tabBarDidClickAddButton(self)
    }
}

// MARK: - Tab Button

private class TabButton: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let closeBtn = TabCloseButton()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private let cornerRadius: CGFloat

    private(set) var currentlySelected = false
    private var currentlyPreview = false
    private(set) var currentlyTerminal = false

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegan: ((NSEvent) -> Void)?
    var onDragMoved: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?

    private var mouseDownLocation: NSPoint?
    private var isDragging = false
    private let dragThreshold: CGFloat = 4

    // Return self for hits inside bounds (except close button).
    // Prevents NSTextField/NSImageView subviews from returning true
    // for mouseDownCanMoveWindow, which would let the titlebar drag intercept.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let closeLocal = closeBtn.convert(point, from: superview)
        if !closeBtn.isHidden && closeBtn.bounds.contains(closeLocal) {
            return closeBtn
        }
        return self
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        validateHover()
    }

    private func validateHover() {
        guard isHovering, let window else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(mouse) {
            isHovering = false
            closeBtn.isHidden = !currentlySelected
            needsDisplay = true
            needsLayout = true
        }
    }

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        // Favicon
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        // Title
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .left
        titleField.maximumNumberOfLines = 1
        titleField.cell?.isScrollable = false
        titleField.cell?.wraps = false
        addSubview(titleField)

        // Close button
        closeBtn.onClose = { [weak self] in self?.onClose?() }
        closeBtn.isHidden = true
        addSubview(closeBtn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, isSelected: Bool, isPreview: Bool, isDirty: Bool, isTerminal: Bool) {
        currentlySelected = isSelected
        currentlyPreview = isPreview
        currentlyTerminal = isTerminal

        // Title
        let displayTitle = isDirty ? "\u{25CF} \(title)" : title
        titleField.stringValue = displayTitle

        let baseFont = NSFont.systemFont(ofSize: 11.5)
        titleField.font = isPreview
            ? NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            : baseFont

        titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor

        // Favicon
        let symbolName = isTerminal ? "terminal" : "doc.text"
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = isSelected ? .labelColor : .tertiaryLabelColor

        // Close button
        closeBtn.isHidden = !(isSelected || isHovering)

        needsDisplay = true
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bgColor: NSColor
        if currentlySelected {
            bgColor = TabBarView.Colors.selectedTab
        } else if isHovering {
            bgColor = TabBarView.Colors.hoverTab
        } else {
            bgColor = .clear
        }

        if bgColor != .clear {
            bgColor.setFill()
            bounds.fill()
        }

        // Separator between non-selected, non-hovered tabs
        if !currentlySelected && !isHovering {
            TabBarView.Colors.separator.setFill()
            NSRect(x: bounds.width - 0.5, y: 5, width: 0.5, height: bounds.height - 10).fill()
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let hPad: CGFloat = 10
        let iconSize: CGFloat = 16
        let closeBtnSize: CGFloat = 16
        let gap: CGFloat = 6

        // Icon on left
        iconView.frame = NSRect(
            x: hPad,
            y: (h - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        // Close button on right
        closeBtn.frame = NSRect(
            x: bounds.width - closeBtnSize - hPad,
            y: (h - closeBtnSize) / 2,
            width: closeBtnSize,
            height: closeBtnSize
        )

        // Title between icon and close button
        let titleLeft = hPad + iconSize + gap
        let titleRight = closeBtn.isHidden ? hPad : closeBtnSize + hPad + 4
        let titleW = max(0, bounds.width - titleLeft - titleRight)
        let textH = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(
            x: titleLeft,
            y: (h - textH) / 2,
            width: titleW,
            height: textH
        )
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        closeBtn.isHidden = false
        needsDisplay = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        closeBtn.isHidden = !currentlySelected
        needsDisplay = true
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if !closeBtn.isHidden && closeBtn.frame.contains(pt) { return }
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        mouseDownLocation = event.locationInWindow
        isDragging = false
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let delta = abs(event.locationInWindow.x - start.x)
        if !isDragging && delta > dragThreshold {
            isDragging = true
            onDragBegan?(event)
        }
        if isDragging {
            onDragMoved?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnded?(event)
        }
        mouseDownLocation = nil
        isDragging = false
    }
}

// MARK: - Close Button

private class TabCloseButton: NSView {
    var onClose: (() -> Void)?
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)

        if isHovering {
            NSColor(white: 0.35, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        let color: NSColor = isHovering ? .labelColor : .tertiaryLabelColor
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.0
        path.lineCapStyle = .round
        let inset: CGFloat = 4.5
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClose?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}

// MARK: - Add Tab Button

private class AddTabButton: NSView {
    weak var target: AnyObject?
    var action: Selector?
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        validateHover()
    }

    /// Check if mouse is still inside after frame change; reset hover if not.
    private func validateHover() {
        guard isHovering, let window else { return }
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(mouse) {
            isHovering = false
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor(white: 0.22, alpha: 1).setFill()
            bounds.fill()
        }

        let color: NSColor = isHovering ? .labelColor : .tertiaryLabelColor
        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let arm: CGFloat = 5.5
        path.move(to: NSPoint(x: center.x - arm, y: center.y))
        path.line(to: NSPoint(x: center.x + arm, y: center.y))
        path.move(to: NSPoint(x: center.x, y: center.y - arm))
        path.line(to: NSPoint(x: center.x, y: center.y + arm))
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if let target, let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}
