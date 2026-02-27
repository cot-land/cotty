#ifndef COTTY_H
#define COTTY_H

#include <stdint.h>

/// Opaque handle types
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
int64_t cotty_terminal_pty_fd(cotty_surface_t surface);

// Terminal child process
int64_t cotty_terminal_child_pid(cotty_surface_t surface);

// Raw grid buffer access (avoids per-cell FFI overhead)
int64_t cotty_terminal_cells_ptr(cotty_surface_t surface);

// Terminal selection
void cotty_terminal_selection_start(cotty_surface_t surface, int64_t row, int64_t col);
void cotty_terminal_selection_update(cotty_surface_t surface, int64_t row, int64_t col);
void cotty_terminal_selection_clear(cotty_surface_t surface);
int64_t cotty_terminal_selection_active(cotty_surface_t surface);
int64_t cotty_terminal_selected_text(cotty_surface_t surface);
int64_t cotty_terminal_selected_text_len(cotty_surface_t surface);

#endif
