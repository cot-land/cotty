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

#endif
