#ifndef COTTY_H
#define COTTY_H

#include <stdint.h>

/// Opaque handle types (both are pointers cast to int64_t)
typedef int64_t cotty_app_t;
typedef int64_t cotty_surface_t;

/// Action tags for the Cot→Swift action queue
#define COTTY_ACTION_NONE           0
#define COTTY_ACTION_QUIT           1
#define COTTY_ACTION_NEW_WINDOW     2
#define COTTY_ACTION_CLOSE_SURFACE  3
#define COTTY_ACTION_MARK_DIRTY     4

// App lifecycle
cotty_app_t cotty_app_new(void);
void cotty_app_free(cotty_app_t app);
void cotty_app_tick(cotty_app_t app);
int64_t cotty_app_surface_count(cotty_app_t app);
int64_t cotty_app_is_running(cotty_app_t app);

// Action queue
int64_t cotty_app_next_action(cotty_app_t app);
int64_t cotty_app_action_payload(cotty_app_t app);
int64_t cotty_app_action_surface(cotty_app_t app);

// Surface lifecycle
cotty_surface_t cotty_surface_new(cotty_app_t app);
void cotty_surface_free(cotty_surface_t surface);

// Surface input
void cotty_surface_key(cotty_surface_t surface, int64_t key, int64_t mods);
void cotty_surface_text(cotty_surface_t surface, const uint8_t *ptr, int64_t len);
void cotty_surface_load_content(cotty_surface_t surface, const uint8_t *ptr, int64_t len);

// Surface queries
int64_t cotty_surface_buffer_len(cotty_surface_t surface);
int64_t cotty_surface_buffer_line_count(cotty_surface_t surface);
int64_t cotty_surface_buffer_line_length(cotty_surface_t surface, int64_t line);
int64_t cotty_surface_buffer_line_start_offset(cotty_surface_t surface, int64_t line);
int64_t cotty_surface_buffer_char_at(cotty_surface_t surface, int64_t pos);

int64_t cotty_surface_cursor_line(cotty_surface_t surface);
int64_t cotty_surface_cursor_col(cotty_surface_t surface);
int64_t cotty_surface_cursor_offset(cotty_surface_t surface);

int64_t cotty_surface_is_dirty(cotty_surface_t surface);
void cotty_surface_set_clean(cotty_surface_t surface);

// Surface kind
#define COTTY_SURFACE_EDITOR    0
#define COTTY_SURFACE_TERMINAL  1

int64_t cotty_surface_kind(cotty_surface_t surface);

// Terminal surface lifecycle
cotty_surface_t cotty_terminal_surface_new(cotty_app_t app, int64_t rows, int64_t cols);
void cotty_terminal_surface_free(cotty_surface_t surface);

// Terminal thread synchronization
void cotty_terminal_lock(cotty_surface_t surface);
void cotty_terminal_unlock(cotty_surface_t surface);
int64_t cotty_terminal_notify_fd(cotty_surface_t surface);
int64_t cotty_terminal_check_dirty(cotty_surface_t surface);
int64_t cotty_terminal_child_exited(cotty_surface_t surface);

// Terminal input
void cotty_terminal_key(cotty_surface_t surface, int64_t key, int64_t mods);
void cotty_terminal_key_event(cotty_surface_t surface, int64_t key, int64_t mods, int64_t event_type);
int64_t cotty_terminal_kitty_keyboard(cotty_surface_t surface);

// Terminal I/O
void cotty_terminal_write(cotty_surface_t surface, const uint8_t *ptr, int64_t len);
int64_t cotty_terminal_read(cotty_surface_t surface, uint8_t *ptr, int64_t len);
void cotty_terminal_resize(cotty_surface_t surface, int64_t rows, int64_t cols);
void cotty_terminal_feed(cotty_surface_t surface, const uint8_t *ptr, int64_t len);
void cotty_terminal_feed_byte(cotty_surface_t surface, int64_t byte);

// Terminal grid queries
int64_t cotty_terminal_rows(cotty_surface_t surface);
int64_t cotty_terminal_cols(cotty_surface_t surface);
int64_t cotty_terminal_cell_codepoint(cotty_surface_t surface, int64_t row, int64_t col);
int64_t cotty_terminal_cell_fg(cotty_surface_t surface, int64_t row, int64_t col);
int64_t cotty_terminal_cell_bg(cotty_surface_t surface, int64_t row, int64_t col);
int64_t cotty_terminal_cell_flags(cotty_surface_t surface, int64_t row, int64_t col);

// Terminal cursor queries
int64_t cotty_terminal_cursor_row(cotty_surface_t surface);
int64_t cotty_terminal_cursor_col(cotty_surface_t surface);
int64_t cotty_terminal_cursor_visible(cotty_surface_t surface);
int64_t cotty_terminal_pty_fd(cotty_surface_t surface);

// Terminal child process
int64_t cotty_terminal_child_pid(cotty_surface_t surface);

// Raw grid buffer access (avoids per-cell FFI overhead)
// Cell layout: 8 x i64 (codepoint, fg_type, fg_val, bg_type, bg_val, flags, ul_type, ul_val)
// Stride = 64 bytes. Color types: 0=none, 1=palette, 2=rgb
int64_t cotty_terminal_cells_ptr(cotty_surface_t surface);
int64_t cotty_terminal_palette_ptr(cotty_surface_t surface);

// Terminal scrollback queries
int64_t cotty_terminal_scrollback_rows(cotty_surface_t surface);
int64_t cotty_terminal_viewport_row(cotty_surface_t surface);
void cotty_terminal_set_viewport(cotty_surface_t surface, int64_t row);

// Terminal selection
void cotty_terminal_selection_start(cotty_surface_t surface, int64_t row, int64_t col);
void cotty_terminal_selection_update(cotty_surface_t surface, int64_t row, int64_t col);
void cotty_terminal_selection_clear(cotty_surface_t surface);
void cotty_terminal_select_word(cotty_surface_t surface, int64_t row, int64_t col);
void cotty_terminal_select_line(cotty_surface_t surface, int64_t row);
int64_t cotty_terminal_selection_active(cotty_surface_t surface);
int64_t cotty_terminal_selected_text(cotty_surface_t surface);
int64_t cotty_terminal_selected_text_len(cotty_surface_t surface);

// Mouse tracking
int64_t cotty_terminal_alt_screen(cotty_surface_t surface);
int64_t cotty_terminal_mouse_mode(cotty_surface_t surface);
int64_t cotty_terminal_mouse_format(cotty_surface_t surface);
void cotty_terminal_mouse_event(cotty_surface_t surface, int64_t button, int64_t col, int64_t row, int64_t pressed, int64_t mods);
void cotty_terminal_scroll(cotty_surface_t surface, int64_t delta, int64_t precise, int64_t cell_height, int64_t col, int64_t row);

// Terminal cursor shape
int64_t cotty_terminal_cursor_shape(cotty_surface_t surface);

// Terminal title
int64_t cotty_terminal_title(cotty_surface_t surface);
int64_t cotty_terminal_title_len(cotty_surface_t surface);

// Terminal PWD (OSC 7)
int64_t cotty_terminal_pwd(cotty_surface_t surface);
int64_t cotty_terminal_pwd_len(cotty_surface_t surface);

// Terminal bell
int64_t cotty_terminal_bell(cotty_surface_t surface);

// Terminal bracketed paste and focus events
int64_t cotty_terminal_bracketed_paste_mode(cotty_surface_t surface);
int64_t cotty_terminal_focus_event_mode(cotty_surface_t surface);
int64_t cotty_terminal_reverse_video(cotty_surface_t surface);
int64_t cotty_terminal_cursor_blinking(cotty_surface_t surface);
int64_t cotty_terminal_app_keypad(cotty_surface_t surface);
void cotty_terminal_focus(cotty_surface_t surface, int64_t focused);
void cotty_terminal_paste(cotty_surface_t surface, int64_t ptr, int64_t len);

// Per-Surface Inspector
void cotty_inspector_toggle(cotty_surface_t surface);
int64_t cotty_inspector_active(cotty_surface_t surface);
int64_t cotty_inspector_rows(cotty_surface_t surface);
int64_t cotty_inspector_cols(cotty_surface_t surface);
int64_t cotty_inspector_cells_ptr(cotty_surface_t surface);
void cotty_inspector_resize(cotty_surface_t surface, int64_t rows, int64_t cols);
void cotty_inspector_set_panel(cotty_surface_t surface, int64_t panel);
void cotty_inspector_scroll(cotty_surface_t surface, int64_t delta);
int64_t cotty_inspector_content_rows(cotty_surface_t surface);
int64_t cotty_inspector_scroll_offset(cotty_surface_t surface);
void cotty_inspector_set_scroll(cotty_surface_t surface, int64_t offset);
void cotty_inspector_rebuild_terminal_state(cotty_surface_t surface);

// Semantic prompts (OSC 133)
int64_t cotty_terminal_jump_prev_prompt(cotty_surface_t surface);
int64_t cotty_terminal_jump_next_prompt(cotty_surface_t surface);
int64_t cotty_terminal_row_semantic(cotty_surface_t surface, int64_t row);

// Config accessors
int64_t cotty_config_font_name(void);
int64_t cotty_config_font_name_len(void);
int64_t cotty_config_font_size(void);
int64_t cotty_config_ui_font_name(void);
int64_t cotty_config_ui_font_name_len(void);
int64_t cotty_config_ui_font_size(void);
int64_t cotty_config_padding(void);
int64_t cotty_config_bg_r(void);
int64_t cotty_config_bg_g(void);
int64_t cotty_config_bg_b(void);
int64_t cotty_config_fg_r(void);
int64_t cotty_config_fg_g(void);
int64_t cotty_config_fg_b(void);
int64_t cotty_config_cursor_r(void);
int64_t cotty_config_cursor_g(void);
int64_t cotty_config_cursor_b(void);
int64_t cotty_config_sel_bg_r(void);
int64_t cotty_config_sel_bg_g(void);
int64_t cotty_config_sel_bg_b(void);
int64_t cotty_config_sel_fg_r(void);
int64_t cotty_config_sel_fg_g(void);
int64_t cotty_config_sel_fg_b(void);
void cotty_config_set_font_size(int64_t size);
void cotty_config_reload(void);

// Command Palette
void cotty_palette_toggle(void);
int64_t cotty_palette_active(void);
void cotty_palette_dismiss(void);
void cotty_palette_set_query(const uint8_t *ptr, int64_t len);
int64_t cotty_palette_result_count(void);
int64_t cotty_palette_result_title(int64_t index);
int64_t cotty_palette_result_title_len(int64_t index);
int64_t cotty_palette_result_tag(int64_t index);
int64_t cotty_palette_selected(void);
void cotty_palette_move_up(void);
void cotty_palette_move_down(void);

// Theme Palette
void cotty_theme_toggle(void);
int64_t cotty_theme_active(void);
void cotty_theme_dismiss(void);
void cotty_theme_set_query(const uint8_t *ptr, int64_t len);
int64_t cotty_theme_result_count(void);
int64_t cotty_theme_result_title(int64_t index);
int64_t cotty_theme_result_title_len(int64_t index);
int64_t cotty_theme_selected(void);
void cotty_theme_move_up(void);
void cotty_theme_move_down(void);
void cotty_theme_apply(int64_t index);

// Workspace
typedef int64_t cotty_workspace_t;

// Workspace lifecycle
cotty_workspace_t cotty_workspace_new(cotty_app_t app);
void cotty_workspace_free(cotty_workspace_t workspace);

// Workspace tab operations
int64_t cotty_workspace_add_terminal_tab(cotty_workspace_t ws, int64_t rows, int64_t cols);
int64_t cotty_workspace_add_editor_tab(cotty_workspace_t ws);
int64_t cotty_workspace_add_editor_tab_preview(cotty_workspace_t ws);
void cotty_workspace_select_tab(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_close_tab(cotty_workspace_t ws, int64_t index);
void cotty_workspace_move_tab(cotty_workspace_t ws, int64_t from, int64_t to);
void cotty_workspace_pin_tab(cotty_workspace_t ws, int64_t index);
void cotty_workspace_mark_dirty(cotty_workspace_t ws, int64_t index);

// Workspace tab queries
int64_t cotty_workspace_tab_count(cotty_workspace_t ws);
int64_t cotty_workspace_selected_index(cotty_workspace_t ws);
int64_t cotty_workspace_tab_surface(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_tab_is_terminal(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_tab_is_preview(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_tab_is_dirty(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_tab_inspector_visible(cotty_workspace_t ws, int64_t index);
void cotty_workspace_tab_set_inspector_visible(cotty_workspace_t ws, int64_t index, int64_t visible);
int64_t cotty_workspace_tab_title(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_tab_title_len(cotty_workspace_t ws, int64_t index);
int64_t cotty_workspace_preview_tab_index(cotty_workspace_t ws);

// Split panes
int64_t cotty_workspace_split(cotty_workspace_t ws, int64_t direction, int64_t rows, int64_t cols);
int64_t cotty_workspace_close_split(cotty_workspace_t ws);
void cotty_workspace_split_move_focus(cotty_workspace_t ws, int64_t direction);
void cotty_workspace_split_set_ratio(cotty_workspace_t ws, int64_t node_idx, int64_t ratio);
int64_t cotty_workspace_is_split(cotty_workspace_t ws);
int64_t cotty_workspace_focused_surface(cotty_workspace_t ws);

// Split tree queries
int64_t cotty_workspace_split_node_count(cotty_workspace_t ws);
int64_t cotty_workspace_split_node_is_leaf(cotty_workspace_t ws, int64_t idx);
int64_t cotty_workspace_split_node_surface(cotty_workspace_t ws, int64_t idx);
int64_t cotty_workspace_split_node_direction(cotty_workspace_t ws, int64_t idx);
int64_t cotty_workspace_split_node_ratio(cotty_workspace_t ws, int64_t idx);
int64_t cotty_workspace_split_node_left(cotty_workspace_t ws, int64_t idx);
int64_t cotty_workspace_split_node_right(cotty_workspace_t ws, int64_t idx);
int64_t cotty_workspace_split_root(cotty_workspace_t ws);
int64_t cotty_workspace_split_focused(cotty_workspace_t ws);

// Workspace state
int64_t cotty_workspace_sidebar_visible(cotty_workspace_t ws);
void cotty_workspace_set_sidebar_visible(cotty_workspace_t ws, int64_t visible);
int64_t cotty_workspace_sidebar_width(cotty_workspace_t ws);
void cotty_workspace_set_sidebar_width(cotty_workspace_t ws, int64_t width);
int64_t cotty_workspace_root_url(cotty_workspace_t ws);
int64_t cotty_workspace_root_url_len(cotty_workspace_t ws);
void cotty_workspace_set_root_url(cotty_workspace_t ws, const uint8_t *ptr, int64_t len);

// File tree
typedef int64_t cotty_filetree_t;

cotty_filetree_t cotty_filetree_new(const uint8_t *root_ptr, int64_t root_len);
void cotty_filetree_free(cotty_filetree_t tree);
void cotty_filetree_set_root(cotty_filetree_t tree, const uint8_t *ptr, int64_t len);
int64_t cotty_filetree_row_count(cotty_filetree_t tree);
void cotty_filetree_toggle_expand(cotty_filetree_t tree, int64_t row);
void cotty_filetree_select_row(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_selected_row(cotty_filetree_t tree);
int64_t cotty_filetree_row_name(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_row_name_len(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_row_depth(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_row_is_dir(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_row_is_expanded(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_row_path(cotty_filetree_t tree, int64_t row);
int64_t cotty_filetree_row_path_len(cotty_filetree_t tree, int64_t row);

#endif
