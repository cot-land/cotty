# Cotty Linux → macOS Parity Plan

## Current State

Linux has: single GtkGLArea terminal with OpenGL cell rendering, keyboard/mouse input, shell integration, Ghostty IO drain pattern. ~1500 lines of Cot + C shim.

macOS has: full IDE — tabs, splits, sidebar, editor, command palette, theme selector, file finder, project search, inspector, status bar, auto-save. ~8000 lines of Swift.

## Architecture Decision: GTK4 Widgets vs OpenGL-Only

**Recommended: Hybrid approach** — use GTK4 native widgets for chrome (tabs, sidebar, status bar, overlays) and OpenGL for cell grids (terminal + editor). This matches how Ghostty uses GTK4 widgets for window chrome and OpenGL for the terminal surface.

- **GTK4 widgets for**: tab bar, sidebar file tree, status bar, command palette, theme selector, file finder, project search, window management
- **OpenGL (GtkGLArea) for**: terminal grid, editor grid, inspector grid

This avoids reimplementing text layout, scrolling, click handling, accessibility etc. in OpenGL. GTK4 does all of that natively.

## Implementation Phases

### Phase 1: Window Layout Foundation
**Goal**: Tab bar + content area + status bar layout

Build the GtkBox vertical stack that holds all UI components:
```
┌─────────────────────────────┐
│ Tab Bar (GtkBox horizontal) │
├─────────┬───────────────────┤
│ Sidebar │ Content Area      │
│ (tree)  │ (GtkGLArea)       │
├─────────┴───────────────────┤
│ Status Bar (GtkBox)         │
└─────────────────────────────┘
```

**Files to create/modify**:
- `src/layout.cot` — window layout construction (vertical GtkBox with tab bar, content, status bar)
- `src/main.cot` — replace single GtkGLArea with layout container

**GTK4 widgets**: GtkBox (vertical for main, horizontal for content+sidebar), GtkPaned (sidebar split)

**FFI needed**: `cotty_workspace_new()`, `cotty_workspace_add_terminal_tab()`

**GTK extern declarations needed** (add to `gtk.cot`):
- `gtk_box_new`, `gtk_box_append`
- `gtk_paned_new`, `gtk_paned_set_start_child`, `gtk_paned_set_end_child`, `gtk_paned_set_position`
- `gtk_separator_new`
- `gtk_label_new`, `gtk_label_set_text`
- `gtk_button_new_with_label`, `gtk_button_new`
- `gtk_drawing_area_new`, `gtk_drawing_area_set_draw_func`
- `gtk_scrolled_window_new`

---

### Phase 2: Tab Bar
**Goal**: Clickable tabs with add/close, keyboard shortcuts

Simple horizontal GtkBox with GtkButton per tab. No drag-reorder yet.

**Files**:
- `src/tabbar.cot` — tab bar widget construction, click handlers, active tab styling

**FFI**: `cotty_workspace_tab_count()`, `cotty_workspace_selected_index()`, `cotty_workspace_select_tab()`, `cotty_workspace_close_tab()`, `cotty_workspace_tab_title()`, `cotty_workspace_tab_is_terminal()`, `cotty_workspace_tab_is_dirty()`

**Behavior**:
- Render tab buttons from workspace tab list
- Highlight active tab
- Close button per tab (with dirty indicator)
- "+" button to add terminal tab
- Keyboard: Ctrl+Tab next, Ctrl+Shift+Tab prev, Ctrl+1-9 direct

---

### Phase 3: Status Bar
**Goal**: Mode indicator + cursor position

GtkBox with labels at the bottom of the window.

**Files**:
- `src/statusbar.cot` — status bar widget, update from surface state

**FFI**: `cotty_surface_mode()`, `cotty_surface_cursor_line()`, `cotty_surface_cursor_col()`, `cotty_workspace_tab_title()`

**Content**:
- Left: sidebar toggle button, mode label (Normal/Insert/Select)
- Right: cursor position (Ln X, Col Y), surface title

---

### Phase 4: Sidebar / File Tree
**Goal**: Expandable file tree with click-to-open

GtkTreeView or custom GtkListBox with indentation.

**Files**:
- `src/filetree.cot` — file tree widget, row rendering, click handlers
- `src/cotty_ffi.cot` — add filetree FFI externs

**FFI**: All `cotty_filetree_*()` functions (new, set_root, row_count, toggle_expand, select_row, row_name, row_depth, row_is_dir, row_is_expanded, row_path)

**Behavior**:
- Toggle with Ctrl+B
- Expand/collapse directories on click
- Double-click file → open in editor tab
- File/dir icons (text-based: 📁/📄 or simple indicators)
- Track workspace root URL

---

### Phase 5: Editor Surface
**Goal**: Cell-based editor rendering in GtkGLArea

Reuse the existing OpenGL renderer for editor cell grids. The renderer already supports the cell data format — just needs to read from `cotty_editor_cells_ptr()`.

**Files**:
- `src/renderer.cot` — already has `render_editor` function (was removed, re-add from reference)
- `src/main.cot` — route editor surfaces to `render_editor`
- `src/cotty_ffi.cot` — add editor FFI externs

**FFI**: `cotty_editor_cells_ptr()`, `cotty_editor_rows()`, `cotty_editor_cols()`, `cotty_editor_resize()`, `cotty_editor_scroll()`, `cotty_editor_click()`, `cotty_editor_drag()`, `cotty_editor_copy()`, `cotty_editor_cut()`, `cotty_editor_paste()`, `cotty_surface_key()`

**Key decisions**:
- One GtkGLArea per surface (terminal or editor), or shared?
- Shared is simpler — switch which cells_ptr to render based on active tab

---

### Phase 6: Split Panes
**Goal**: Horizontal/vertical split with draggable divider

GtkPaned widgets, recursively constructed from the Cot split tree.

**Files**:
- `src/splits.cot` — build GtkPaned tree from `cotty_workspace_split_*` queries

**FFI**: `cotty_workspace_split()`, `cotty_workspace_close_split()`, `cotty_workspace_split_move_focus()`, `cotty_workspace_is_split()`, `cotty_workspace_split_node_*()` (tree query functions)

**Behavior**:
- Ctrl+D: split right, Ctrl+Shift+D: split down
- Each leaf gets its own GtkGLArea
- Focus tracking between splits
- Unfocused split dimming (opacity overlay)

---

### Phase 7: Command Palette
**Goal**: Fuzzy command search overlay (Ctrl+Shift+P)

GtkPopover or custom overlay with GtkEntry + GtkListBox.

**Files**:
- `src/palette.cot` — palette overlay, search input, results list

**FFI**: All `cotty_palette_*()` functions

**Behavior**:
- Ctrl+Shift+P: toggle
- Text entry filters results (logic in Cot)
- Arrow keys navigate, Enter executes
- Esc dismisses

---

### Phase 8: Theme Selector
**Goal**: Theme picker overlay

Same pattern as command palette.

**Files**:
- `src/theme_selector.cot`

**FFI**: All `cotty_theme_*()` functions

---

### Phase 9: File Finder
**Goal**: Fuzzy file search (Ctrl+P)

Same overlay pattern. Opens file in editor tab on selection.

**Files**:
- `src/file_finder.cot`

**FFI**: All `cotty_file_finder_*()` functions

---

### Phase 10: Project Search
**Goal**: Project-wide text search (Ctrl+Shift+F)

More complex overlay — results grouped by file with line previews.

**Files**:
- `src/project_search.cot`

**FFI**: All `cotty_project_search_*()` functions

---

### Phase 11: Inspector Panel
**Goal**: Debug inspector for terminal/editor state

GtkGLArea below the main content area, renders inspector cell grid.

**Files**:
- `src/inspector.cot`

**FFI**: All `cotty_inspector_*()` functions

---

### Phase 12: Menu & Keyboard Shortcuts
**Goal**: Application menu bar + global shortcuts

GMenu integration for GTK4.

**Files**:
- `src/main.cot` — register GActions and accelerators

**Shortcuts**:
- Ctrl+N: new window
- Ctrl+T: new terminal tab
- Ctrl+E: new editor tab
- Ctrl+W: close tab
- Ctrl+1-9: tab switching
- Ctrl+Shift+P: command palette
- Ctrl+P: file finder
- Ctrl+Shift+F: project search
- Ctrl+B: toggle sidebar
- Ctrl+I: toggle inspector
- Ctrl+D: split right
- Ctrl+S: save editor
- Ctrl+/: toggle comment

---

### Phase 13: Polish
**Goal**: Visual parity and UX refinement

- Auto-save timer (5 second interval for dirty editor tabs)
- Window title from active tab
- Window cascading for multiple windows
- Unfocused split dimming
- Padding extend (edge bg colors into padding)
- Min contrast for text accessibility
- Drag-to-reorder tabs
- Tab preview mode
- Copy-on-select for terminal
- Context menus (right-click)
- Clipboard integration (Ctrl+C/V in terminal with selection awareness)
- OSC 7 working directory → sidebar auto-populate
- Terminal title from OSC sequences
- Bell handling

---

## Priority Order

Phases 1-5 are the core — after those, Cotty Linux is a usable terminal+editor IDE.
Phases 6-10 add the power-user features.
Phases 11-13 are polish.

## Key Principle

ALL logic lives in libcotty (Cot). The Linux shell is a thin GTK4 binding layer — it creates widgets, forwards events to Cot via FFI, and renders what Cot tells it to render. No application logic in the shell.
