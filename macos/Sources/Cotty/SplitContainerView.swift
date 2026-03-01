import AppKit
import CCottyCore

/// Recursive NSSplitView builder that reads the split tree from Cot via FFI.
/// Leaf nodes place TerminalViews; split nodes create NSSplitViews with children.
class SplitContainerView: NSView {
    weak var workspaceController: WorkspaceWindowController?
    private var splitViews: [NSSplitView] = []
    private let dividerDelegate = SplitDividerDelegate()

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild the entire split view hierarchy from the Cot tree.
    func rebuild(workspace: CottyWorkspace, viewForSurface: (cotty_surface_t) -> NSView?) {
        // Remove old subviews
        for sub in subviews { sub.removeFromSuperview() }
        splitViews.removeAll()
        dividerDelegate.workspace = workspace
        dividerDelegate.controller = workspaceController

        let rootIdx = workspace.splitRoot
        guard let rootView = buildNode(idx: rootIdx, workspace: workspace, viewForSurface: viewForSurface) else { return }
        rootView.frame = bounds
        rootView.autoresizingMask = [.width, .height]
        addSubview(rootView)
    }

    private func buildNode(idx: Int, workspace: CottyWorkspace, viewForSurface: (cotty_surface_t) -> NSView?) -> NSView? {
        guard idx >= 0 && idx < workspace.splitNodeCount else { return nil }

        if workspace.splitNodeIsLeaf(idx) {
            let handle = workspace.splitNodeSurface(idx)
            guard let view = viewForSurface(handle) else { return nil }
            view.autoresizingMask = [.width, .height]
            return view
        }

        // Split node — create NSSplitView
        let direction = workspace.splitNodeDirection(idx)
        let ratio = workspace.splitNodeRatio(idx)
        let leftIdx = workspace.splitNodeLeft(idx)
        let rightIdx = workspace.splitNodeRight(idx)

        let sv = NSSplitView()
        sv.isVertical = (direction == 1) // SPLIT_HORIZONTAL = left/right = vertical divider
        sv.dividerStyle = .thin
        sv.delegate = dividerDelegate
        dividerDelegate.addMapping(splitView: sv, nodeIndex: idx)

        if let leftView = buildNode(idx: leftIdx, workspace: workspace, viewForSurface: viewForSurface) {
            sv.addArrangedSubview(leftView)
        }
        if let rightView = buildNode(idx: rightIdx, workspace: workspace, viewForSurface: viewForSurface) {
            sv.addArrangedSubview(rightView)
        }

        splitViews.append(sv)

        // Apply ratio after a layout cycle
        let ratioFraction = CGFloat(ratio) / 1000.0
        DispatchQueue.main.async { [weak sv] in
            guard let sv else { return }
            let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
            if total > 0 {
                sv.setPosition(total * ratioFraction, ofDividerAt: 0)
            }
        }

        return sv
    }
}

/// Delegate that reports divider drags back to Cot.
private class SplitDividerDelegate: NSObject, NSSplitViewDelegate {
    weak var workspace: CottyWorkspace?
    weak var controller: WorkspaceWindowController?
    private var nodeIndices: [ObjectIdentifier: Int] = [:]

    func addMapping(splitView: NSSplitView, nodeIndex: Int) {
        nodeIndices[ObjectIdentifier(splitView)] = nodeIndex
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sv = notification.object as? NSSplitView,
              let workspace,
              let nodeIdx = nodeIndices[ObjectIdentifier(sv)] else { return }

        let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
        guard total > 0, sv.subviews.count >= 2 else { return }
        let first = sv.isVertical ? sv.subviews[0].frame.width : sv.subviews[0].frame.height
        let ratio = Int(first / total * 1000)
        workspace.splitSetRatio(nodeIndex: nodeIdx, ratio: ratio)

        // Trigger grid resize on terminal views within the split
        controller?.resizeTerminalViewsInSplits()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 50
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return total - 50
    }
}
