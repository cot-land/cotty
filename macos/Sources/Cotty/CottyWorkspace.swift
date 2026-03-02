import CCottyCore
import Foundation

/// Swift wrapper around the opaque cotty_workspace_t handle.
/// Thin bindings — all tab/workspace logic lives in Cot.
final class CottyWorkspace {
    let handle: cotty_workspace_t
    weak var app: CottyApp?

    init(app: CottyApp) {
        self.app = app
        handle = cotty_workspace_new(app.handle)
    }

    deinit {
        cotty_workspace_free(handle)
    }

    // MARK: - Tab Operations

    /// Add a terminal tab. Returns the surface handle.
    func addTerminalTab(rows: Int, cols: Int) -> cotty_surface_t {
        cotty_workspace_add_terminal_tab(handle, Int64(rows), Int64(cols))
    }

    /// Add an editor tab. Returns the surface handle.
    func addEditorTab() -> cotty_surface_t {
        cotty_workspace_add_editor_tab(handle)
    }

    /// Add a preview editor tab. Returns the surface handle.
    func addEditorTabPreview() -> cotty_surface_t {
        cotty_workspace_add_editor_tab_preview(handle)
    }

    func selectTab(at index: Int) {
        cotty_workspace_select_tab(handle, Int64(index))
    }

    /// Close a tab. Returns the surface handle for view cleanup.
    func closeTab(at index: Int) -> cotty_surface_t {
        cotty_workspace_close_tab(handle, Int64(index))
    }

    func moveTab(from oldIndex: Int, to newIndex: Int) {
        cotty_workspace_move_tab(handle, Int64(oldIndex), Int64(newIndex))
    }

    func pinTab(at index: Int) {
        cotty_workspace_pin_tab(handle, Int64(index))
    }

    func markDirty(at index: Int) {
        cotty_workspace_mark_dirty(handle, Int64(index))
    }

    // MARK: - Tab Queries

    var tabCount: Int {
        Int(cotty_workspace_tab_count(handle))
    }

    var selectedIndex: Int {
        Int(cotty_workspace_selected_index(handle))
    }

    func tabSurface(at index: Int) -> cotty_surface_t {
        cotty_workspace_tab_surface(handle, Int64(index))
    }

    func tabIsTerminal(at index: Int) -> Bool {
        cotty_workspace_tab_is_terminal(handle, Int64(index)) != 0
    }

    func tabIsPreview(at index: Int) -> Bool {
        cotty_workspace_tab_is_preview(handle, Int64(index)) != 0
    }

    func tabIsDirty(at index: Int) -> Bool {
        cotty_workspace_tab_is_dirty(handle, Int64(index)) != 0
    }

    func tabInspectorVisible(at index: Int) -> Bool {
        cotty_workspace_tab_inspector_visible(handle, Int64(index)) != 0
    }

    func setTabInspectorVisible(at index: Int, visible: Bool) {
        cotty_workspace_tab_set_inspector_visible(handle, Int64(index), visible ? 1 : 0)
    }

    func tabTitle(at index: Int) -> String {
        let ptr = cotty_workspace_tab_title(handle, Int64(index))
        let len = cotty_workspace_tab_title_len(handle, Int64(index))
        guard len > 0, ptr != 0 else { return "" }
        let data = Data(bytes: UnsafeRawPointer(bitPattern: Int(ptr))!, count: Int(len))
        return String(data: data, encoding: .utf8) ?? ""
    }

    var previewTabIndex: Int {
        Int(cotty_workspace_preview_tab_index(handle))
    }

    // MARK: - Split Panes

    func split(direction: Int, rows: Int, cols: Int) -> cotty_surface_t {
        cotty_workspace_split(handle, Int64(direction), Int64(rows), Int64(cols))
    }

    func closeSplit() -> cotty_surface_t {
        cotty_workspace_close_split(handle)
    }

    func splitMoveFocus(direction: Int) {
        cotty_workspace_split_move_focus(handle, Int64(direction))
    }

    func splitSetRatio(nodeIndex: Int, ratio: Int) {
        cotty_workspace_split_set_ratio(handle, Int64(nodeIndex), Int64(ratio))
    }

    var isSplit: Bool {
        cotty_workspace_is_split(handle) != 0
    }

    var focusedSurface: cotty_surface_t {
        cotty_workspace_focused_surface(handle)
    }

    func setFocusedSurface(_ surfaceHandle: cotty_surface_t) {
        cotty_workspace_set_focused_surface(handle, surfaceHandle)
    }

    // Split tree queries
    var splitNodeCount: Int { Int(cotty_workspace_split_node_count(handle)) }
    func splitNodeIsLeaf(_ idx: Int) -> Bool { cotty_workspace_split_node_is_leaf(handle, Int64(idx)) != 0 }
    func splitNodeSurface(_ idx: Int) -> cotty_surface_t { cotty_workspace_split_node_surface(handle, Int64(idx)) }
    func splitNodeDirection(_ idx: Int) -> Int { Int(cotty_workspace_split_node_direction(handle, Int64(idx))) }
    func splitNodeRatio(_ idx: Int) -> Int { Int(cotty_workspace_split_node_ratio(handle, Int64(idx))) }
    func splitNodeLeft(_ idx: Int) -> Int { Int(cotty_workspace_split_node_left(handle, Int64(idx))) }
    func splitNodeRight(_ idx: Int) -> Int { Int(cotty_workspace_split_node_right(handle, Int64(idx))) }
    var splitRoot: Int { Int(cotty_workspace_split_root(handle)) }
    var splitFocused: Int { Int(cotty_workspace_split_focused(handle)) }

    // MARK: - Workspace State

    var sidebarVisible: Bool {
        get { cotty_workspace_sidebar_visible(handle) != 0 }
        set { cotty_workspace_set_sidebar_visible(handle, newValue ? 1 : 0) }
    }

    var sidebarWidth: Int {
        get { Int(cotty_workspace_sidebar_width(handle)) }
        set { cotty_workspace_set_sidebar_width(handle, Int64(newValue)) }
    }

    var rootURL: URL? {
        get {
            let ptr = cotty_workspace_root_url(handle)
            let len = cotty_workspace_root_url_len(handle)
            guard len > 0, ptr != 0 else { return nil }
            let data = Data(bytes: UnsafeRawPointer(bitPattern: Int(ptr))!, count: Int(len))
            guard let str = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: str)
        }
        set {
            if let url = newValue {
                let str = url.absoluteString
                str.utf8.withContiguousStorageIfAvailable { buf in
                    cotty_workspace_set_root_url(handle, buf.baseAddress, Int64(buf.count))
                }
            } else {
                cotty_workspace_set_root_url(handle, nil, 0)
            }
        }
    }
}
