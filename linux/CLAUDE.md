# Cotty Linux — AI Session Instructions

## ABSOLUTE RULE: THIN SHELL IN COT

This is the Linux platform shell for Cotty. Same rules as macOS:
**ALL logic lives in libcotty (Cot core).** This shell ONLY:

- Sets up GTK4 window + GtkGLArea
- Initializes OpenGL renderer + FreeType glyph atlas
- Forwards GDK key/mouse events to Cot via FFI
- Reads cell grid from Cot and renders via OpenGL
- Monitors terminal notify pipe for IO thread signals

## Architecture

```
linux/
  cot.json              Build config (links gtk-4, epoxy, freetype, cotty)
  src/
    main.cot            Entry point, GTK app, window, GtkGLArea setup
    gtk.cot             GTK4/GLib/GDK extern declarations
    gl.cot              OpenGL extern declarations (via libepoxy)
    freetype.cot        FreeType2 + fontconfig extern declarations
    input.cot           GDK keyval → Cot KEY_* translation
    renderer.cot        OpenGL cell renderer (port of MetalRenderer.swift)
    glyph_atlas.cot     FreeType glyph atlas (port of GlyphAtlas.swift)
    shaders/
      cell.vert         GLSL vertex shader (instanced cells)
      cell.frag         GLSL fragment shader (atlas sampling)
    theme.cot           Config/theme value loading from libcotty FFI
  vendor/
    ft_shim.c           FreeType struct field access shim
    gl_shim.c           OpenGL float ABI + GTK input callback shim
```

## Reference Architecture

- **Ghostty GTK**: `libcotty/references/ghostty/src/apprt/gtk/` (Zig)
- **Ghostty OpenGL**: `libcotty/references/ghostty/src/renderer/opengl.zig`
- **macOS shell**: `macos/Sources/Cotty/` (Swift — same patterns, different APIs)

## Build

```bash
# Build libcotty first
cd ../libcotty && cot build src/ffi.cot --lib -o libcotty.so

# Build C shims (FreeType + GL + input — combined into one .so)
cc -shared -fPIC -o vendor/libcotty_shim.so vendor/ft_shim.c vendor/gl_shim.c \
    $(pkg-config --cflags --libs freetype2 epoxy gtk4)

# Build Linux app
cot build src/main.cot -o cotty

# Run
LD_LIBRARY_PATH=../libcotty:vendor ./cotty
```

## Key ABI Note

Cot's f32 ABI is broken on aarch64-linux (float values passed in integer registers
instead of floating-point registers). All GL functions taking `float`/`GLfloat` params
and all GTK gesture callbacks with `gdouble` coordinates must go through the C shim
(`vendor/gl_shim.c`) which receives i64 args and converts internally.

## Key Patterns (Ghostty → Cotty)

| Ghostty (Zig) | Cotty Linux (Cot) |
|---|---|
| `@import("gtk")` | `extern fn gtk_*()` in gtk.cot |
| `GtkGLArea` signals | `g_signal_connect_data()` |
| `Surface.render` callback | `onRender()` in main.cot |
| `key.translateMods()` | `translateMods()` in input.cot |
| `renderer/opengl.zig` | `renderer.cot` |
| `font/freetype.zig` | `glyph_atlas.cot` + `ft_shim.c` |
