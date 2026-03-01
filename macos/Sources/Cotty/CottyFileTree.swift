import CCottyCore
import Foundation

/// Swift wrapper around the opaque cotty_filetree_t handle.
/// Thin bindings — all tree logic lives in Cot.
final class CottyFileTree {
    let handle: cotty_filetree_t

    init(rootPath: String) {
        handle = rootPath.utf8.withContiguousStorageIfAvailable { buf in
            cotty_filetree_new(buf.baseAddress, Int64(buf.count))
        }!
    }

    deinit {
        cotty_filetree_free(handle)
    }

    func setRoot(_ path: String) {
        path.utf8.withContiguousStorageIfAvailable { buf in
            cotty_filetree_set_root(handle, buf.baseAddress, Int64(buf.count))
        }
    }

    var rowCount: Int {
        Int(cotty_filetree_row_count(handle))
    }

    func toggleExpand(at row: Int) {
        cotty_filetree_toggle_expand(handle, Int64(row))
    }

    func selectRow(_ row: Int) {
        cotty_filetree_select_row(handle, Int64(row))
    }

    var selectedRow: Int {
        Int(cotty_filetree_selected_row(handle))
    }

    func rowName(at row: Int) -> String {
        let ptr = cotty_filetree_row_name(handle, Int64(row))
        let len = cotty_filetree_row_name_len(handle, Int64(row))
        guard len > 0, ptr != 0 else { return "" }
        let data = Data(bytes: UnsafeRawPointer(bitPattern: Int(ptr))!, count: Int(len))
        return String(data: data, encoding: .utf8) ?? ""
    }

    func rowDepth(at row: Int) -> Int {
        Int(cotty_filetree_row_depth(handle, Int64(row)))
    }

    func rowIsDir(at row: Int) -> Bool {
        cotty_filetree_row_is_dir(handle, Int64(row)) != 0
    }

    func rowIsExpanded(at row: Int) -> Bool {
        cotty_filetree_row_is_expanded(handle, Int64(row)) != 0
    }

    func rowPath(at row: Int) -> String {
        let ptr = cotty_filetree_row_path(handle, Int64(row))
        let len = cotty_filetree_row_path_len(handle, Int64(row))
        guard len > 0, ptr != 0 else { return "" }
        let data = Data(bytes: UnsafeRawPointer(bitPattern: Int(ptr))!, count: Int(len))
        return String(data: data, encoding: .utf8) ?? ""
    }
}
