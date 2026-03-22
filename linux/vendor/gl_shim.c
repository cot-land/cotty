// OpenGL + Input shim for Cot on aarch64-linux.
// Cot's f32 ABI is broken on aarch64 (float values passed in integer registers
// instead of floating-point registers). This shim receives integer-encoded
// values and converts them to float for GL calls. Also provides callback shims
// for GTK gesture/motion/scroll signals (which pass gdouble coordinates).
//
// Compile with ft_shim.c:
//   cc -shared -fPIC -o libcotty_shim.so ft_shim.c gl_shim.c \
//      $(pkg-config --cflags --libs freetype2 epoxy gtk4)

#include <epoxy/gl.h>
#include <gtk/gtk.h>
#include <stdint.h>
#include <string.h>

// ============================================================================
// GL pass-through wrappers (epoxy uses function pointers, not direct symbols)
// ============================================================================

// Shader
int64_t cotty_glCreateShader(int64_t t) { return (int64_t)glCreateShader((GLenum)t); }
void cotty_glShaderSource(int64_t s, int64_t n, int64_t pp, int64_t len) { glShaderSource((GLuint)s, (GLsizei)n, (const GLchar *const *)(intptr_t)pp, (const GLint *)(intptr_t)len); }
void cotty_glCompileShader(int64_t s) { glCompileShader((GLuint)s); }
void cotty_glGetShaderiv(int64_t s, int64_t p, int64_t v) { glGetShaderiv((GLuint)s, (GLenum)p, (GLint *)(intptr_t)v); }
void cotty_glDeleteShader(int64_t s) { glDeleteShader((GLuint)s); }

// Program
int64_t cotty_glCreateProgram(void) { return (int64_t)glCreateProgram(); }
void cotty_glAttachShader(int64_t p, int64_t s) { glAttachShader((GLuint)p, (GLuint)s); }
void cotty_glLinkProgram(int64_t p) { glLinkProgram((GLuint)p); }
void cotty_glGetProgramiv(int64_t p, int64_t n, int64_t v) { glGetProgramiv((GLuint)p, (GLenum)n, (GLint *)(intptr_t)v); }
void cotty_glDeleteProgram(int64_t p) { glDeleteProgram((GLuint)p); }
void cotty_glUseProgram(int64_t p) { glUseProgram((GLuint)p); }

// Uniform
int64_t cotty_glGetUniformLocation(int64_t p, int64_t name) { return (int64_t)glGetUniformLocation((GLuint)p, (const GLchar *)(intptr_t)name); }
void cotty_glUniform1i(int64_t loc, int64_t v) { glUniform1i((GLint)loc, (GLint)v); }

// VAO/VBO
void cotty_glGenVertexArrays(int64_t n, int64_t p) { glGenVertexArrays((GLsizei)n, (GLuint *)(intptr_t)p); }
void cotty_glGenBuffers(int64_t n, int64_t p) { glGenBuffers((GLsizei)n, (GLuint *)(intptr_t)p); }
void cotty_glBindVertexArray(int64_t v) { glBindVertexArray((GLuint)v); }
void cotty_glBindBuffer(int64_t t, int64_t b) { glBindBuffer((GLenum)t, (GLuint)b); }
void cotty_glBufferData(int64_t t, int64_t sz, int64_t d, int64_t u) { glBufferData((GLenum)t, (GLsizeiptr)sz, (const void *)(intptr_t)d, (GLenum)u); }
void cotty_glEnableVertexAttribArray(int64_t i) { glEnableVertexAttribArray((GLuint)i); }
void cotty_glVertexAttribPointer(int64_t i, int64_t sz, int64_t t, int64_t n, int64_t st, int64_t off) { glVertexAttribPointer((GLuint)i, (GLint)sz, (GLenum)t, (GLboolean)n, (GLsizei)st, (const void *)(intptr_t)off); }
void cotty_glVertexAttribIPointer(int64_t i, int64_t sz, int64_t t, int64_t st, int64_t off) { glVertexAttribIPointer((GLuint)i, (GLint)sz, (GLenum)t, (GLsizei)st, (const void *)(intptr_t)off); }
void cotty_glVertexAttribDivisor(int64_t i, int64_t d) { glVertexAttribDivisor((GLuint)i, (GLuint)d); }

// Drawing
void cotty_glDrawArraysInstanced(int64_t m, int64_t f, int64_t c, int64_t n) { glDrawArraysInstanced((GLenum)m, (GLint)f, (GLsizei)c, (GLsizei)n); }
void cotty_glClear(int64_t mask) { glClear((GLbitfield)mask); }
void cotty_glEnable(int64_t cap) { glEnable((GLenum)cap); }
void cotty_glBlendFunc(int64_t s, int64_t d) { glBlendFunc((GLenum)s, (GLenum)d); }
void cotty_glPixelStorei(int64_t p, int64_t v) { glPixelStorei((GLenum)p, (GLint)v); }

// Texture
void cotty_glGenTextures(int64_t n, int64_t p) { glGenTextures((GLsizei)n, (GLuint *)(intptr_t)p); }
void cotty_glBindTexture(int64_t t, int64_t tex) { glBindTexture((GLenum)t, (GLuint)tex); }
void cotty_glTexParameteri(int64_t t, int64_t p, int64_t v) { glTexParameteri((GLenum)t, (GLenum)p, (GLint)v); }
void cotty_glTexImage2D(int64_t t, int64_t lv, int64_t i, int64_t w, int64_t h, int64_t b, int64_t f, int64_t tp, int64_t d) { glTexImage2D((GLenum)t, (GLint)lv, (GLint)i, (GLsizei)w, (GLsizei)h, (GLint)b, (GLenum)f, (GLenum)tp, (const void *)(intptr_t)d); }
void cotty_glTexSubImage2D(int64_t t, int64_t lv, int64_t x, int64_t y, int64_t w, int64_t h, int64_t f, int64_t tp, int64_t d) { glTexSubImage2D((GLenum)t, (GLint)lv, (GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h, (GLenum)f, (GLenum)tp, (const void *)(intptr_t)d); }
void cotty_glActiveTexture(int64_t t) { glActiveTexture((GLenum)t); }

// GL info query
int64_t cotty_gl_get_string(int64_t name) { return (int64_t)(intptr_t)glGetString((GLenum)name); }

// ============================================================================
// GL float-parameter wrappers
// ============================================================================

// Takes 0-255 integer color components, converts to 0.0-1.0
void cotty_gl_clear_color(int64_t r, int64_t g, int64_t b, int64_t a) {
    glClearColor((float)r / 255.0f, (float)g / 255.0f,
                 (float)b / 255.0f, (float)a / 255.0f);
}

// Takes integer pixel values, converts to float for glUniform2f
void cotty_gl_uniform2f(int64_t loc, int64_t v0, int64_t v1) {
    glUniform2f((GLint)loc, (float)v0, (float)v1);
}

// Builds top-left-origin orthographic projection matrix from pixel dimensions
void cotty_gl_set_projection(int64_t loc, int64_t draw_w, int64_t draw_h) {
    float m[16];
    memset(m, 0, sizeof(m));
    m[0]  =  2.0f / (float)draw_w;   // X scale
    m[5]  = -2.0f / (float)draw_h;   // Y scale (flip Y for top-left origin)
    m[10] =  1.0f;                     // Z scale
    m[12] = -1.0f;                     // X translate
    m[13] =  1.0f;                     // Y translate
    m[15] =  1.0f;                     // W
    glUniformMatrix4fv((GLint)loc, 1, GL_FALSE, m);
}

// Pass-through viewport (glViewport takes GLint, no float issue)
void cotty_gl_viewport(int64_t x, int64_t y, int64_t w, int64_t h) {
    glViewport((GLint)x, (GLint)y, (GLsizei)w, (GLsizei)h);
}

// ============================================================================
// Embedded shader sources (avoids multi-line string issues in Cot)
// ============================================================================

static const char cell_vert_src[] =
    "#version 330 core\n"
    "uniform mat4 u_projection;\n"
    "uniform vec2 u_cell_size;\n"
    "uniform vec2 u_atlas_size;\n"
    "uniform vec2 u_padding;\n"
    "layout(location = 0) in uvec2 a_grid_pos;\n"
    "layout(location = 1) in uvec2 a_atlas_pos;\n"
    "layout(location = 2) in uvec2 a_glyph_size;\n"
    "layout(location = 3) in ivec2 a_offset;\n"
    "layout(location = 4) in vec4  a_color;\n"
    "out vec2 v_tex_coord;\n"
    "out vec4 v_color;\n"
    "void main() {\n"
    "    vec2 corner = vec2(gl_VertexID & 1, (gl_VertexID >> 1) & 1);\n"
    "    vec2 origin = u_padding + u_cell_size * vec2(a_grid_pos);\n"
    "    vec2 sz = vec2(a_glyph_size);\n"
    "    vec2 off = vec2(a_offset);\n"
    "    vec2 pos = origin + off + sz * corner;\n"
    "    gl_Position = u_projection * vec4(pos, 0.0, 1.0);\n"
    "    v_tex_coord = (vec2(a_atlas_pos) + sz * corner) / u_atlas_size;\n"
    "    v_color = a_color;\n"
    "}\n";

static const char cell_frag_src[] =
    "#version 330 core\n"
    "uniform sampler2D u_atlas;\n"
    "in vec2 v_tex_coord;\n"
    "in vec4 v_color;\n"
    "out vec4 frag_color;\n"
    "void main() {\n"
    "    float a = texture(u_atlas, v_tex_coord).r;\n"
    "    frag_color = vec4(v_color.rgb * a, v_color.a * a);\n"
    "}\n";

int64_t cotty_gl_vert_shader_src(void) { return (int64_t)(intptr_t)cell_vert_src; }
int64_t cotty_gl_vert_shader_len(void) { return (int64_t)(sizeof(cell_vert_src) - 1); }
int64_t cotty_gl_frag_shader_src(void) { return (int64_t)(intptr_t)cell_frag_src; }
int64_t cotty_gl_frag_shader_len(void) { return (int64_t)(sizeof(cell_frag_src) - 1); }

// ============================================================================
// GTK input callback shim (f64 ABI workaround for gesture coordinates)
// ============================================================================

// Function pointer types — Cot callbacks receive all-i64 params
typedef void (*cotty_press_fn)(int64_t n_press, int64_t x_milli, int64_t y_milli);
typedef void (*cotty_motion_fn)(int64_t x_milli, int64_t y_milli);
typedef void (*cotty_scroll_fn)(int64_t dx_milli, int64_t dy_milli);

static cotty_press_fn  s_on_press   = NULL;
static cotty_press_fn  s_on_release = NULL;
static cotty_motion_fn s_on_motion  = NULL;
static cotty_scroll_fn s_on_scroll  = NULL;

// Register Cot callback function pointers
void cotty_input_set_callbacks(int64_t on_press, int64_t on_release,
                                int64_t on_motion, int64_t on_scroll) {
    s_on_press   = (cotty_press_fn)(intptr_t)on_press;
    s_on_release = (cotty_press_fn)(intptr_t)on_release;
    s_on_motion  = (cotty_motion_fn)(intptr_t)on_motion;
    s_on_scroll  = (cotty_scroll_fn)(intptr_t)on_scroll;
}

// GTK signal handlers — receive gdouble, convert to milli-pixel i64 for Cot
static void shim_gesture_pressed(GtkGestureClick *gesture, gint n_press,
                                  gdouble x, gdouble y, gpointer data) {
    (void)gesture; (void)data;
    if (s_on_press) s_on_press((int64_t)n_press, (int64_t)(x * 1000), (int64_t)(y * 1000));
}

static void shim_gesture_released(GtkGestureClick *gesture, gint n_press,
                                   gdouble x, gdouble y, gpointer data) {
    (void)gesture; (void)data;
    if (s_on_release) s_on_release((int64_t)n_press, (int64_t)(x * 1000), (int64_t)(y * 1000));
}

static void shim_motion(GtkEventControllerMotion *ctrl,
                         gdouble x, gdouble y, gpointer data) {
    (void)ctrl; (void)data;
    if (s_on_motion) s_on_motion((int64_t)(x * 1000), (int64_t)(y * 1000));
}

static gboolean shim_scroll(GtkEventControllerScroll *ctrl,
                              gdouble dx, gdouble dy, gpointer data) {
    (void)ctrl; (void)data;
    if (s_on_scroll) s_on_scroll((int64_t)(dx * 1000), (int64_t)(dy * 1000));
    return TRUE;
}

// Install gesture/motion/scroll controllers on a GtkWidget.
// Called from Cot after setting callbacks via cotty_input_set_callbacks.
void cotty_setup_input(int64_t widget_ptr) {
    GtkWidget *w = (GtkWidget *)(intptr_t)widget_ptr;

    // Click gesture (all buttons)
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(shim_gesture_pressed), NULL);
    g_signal_connect(click, "released", G_CALLBACK(shim_gesture_released), NULL);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(click));

    // Motion controller
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(shim_motion), NULL);
    gtk_widget_add_controller(w, motion);

    // Scroll controller (both axes)
    GtkEventController *scroll = gtk_event_controller_scroll_new(
        GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(shim_scroll), NULL);
    gtk_widget_add_controller(w, scroll);
}

// ============================================================================
// String formatting helper for GTK label updates
// ============================================================================

static char g_fmt_buf[256];

int64_t cotty_format_pos(int64_t row, int64_t col) {
    snprintf(g_fmt_buf, sizeof(g_fmt_buf), "Ln %ld, Col %ld  ", (long)(row + 1), (long)col);
    return (int64_t)(intptr_t)g_fmt_buf;
}
