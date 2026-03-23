# Cotty macOS — AI Session Instructions

## Project Overview

**Cotty** is the macOS frontend for the Cot terminal emulator. All application logic lives in the [libcotty](https://github.com/cot-land/libcotty) submodule (written in Cot). This repo is the Swift/Metal shell that renders what Cot tells it to render.

## ABSOLUTE #1 RULE — NO LOGIC IN SWIFT

**Swift is a thin shell. ALL logic lives in Cot (libcotty).**

Cotty is a dogfooding project for the Cot language. Swift exists ONLY as a platform binding layer — it calls Cot FFI functions and renders what Cot tells it to render. Nothing more.

- **NO** implementing features in Swift that should be in Cot
- **NO** Swift-side workarounds for Cot compiler bugs — fix the compiler instead
- **NO** duplicating logic between Swift and Cot
- Swift may ONLY: create windows, set up Metal layers, forward raw input events to Cot, and render from Cot's data
- Every line of logic in Swift is a line that ISN'T dogfooding Cot

## NEVER WORKAROUND COT LIMITATIONS

If the Cot compiler doesn't support a pattern you need, **STOP and tell the user** so they can implement the missing feature in the Zig compiler first. Never restructure code, extract helpers, or simplify patterns just to avoid a compiler limitation.

## Repo Structure

```
CLAUDE.md          This file
.gitmodules        libcotty submodule reference
libcotty/          Git submodule → cot-land/libcotty (all Cot source)
                   Terminal emulation, editor, VT parser, workspace — ALL platforms
macos/             macOS native shell (Swift + Metal rendering)
  Package.swift
  Sources/
    CCottyCore/
      include/cotty.h    FFI header (Swift ↔ Cot bridge)
      shim.c
    Cotty/
      *.swift            macOS app (AppKit, Metal rendering)
linux/             Linux native shell (GTK4 + OpenGL rendering)
  src/
    main.cot             Linux entry point
    renderer.cot         OpenGL cell renderer
    glyph_atlas.cot      Font atlas
    gtk.cot              GTK4 bindings
web/               Browser shell (Wasm + WebGPU/Canvas) — runs on ALL platforms
  src/
    main.cot             Web entry point (compiles to Wasm)
    render.cot           WebGPU extern fns + cell buffer
    ws_terminal.cot      WebSocket terminal data channel
    fs.cot               File System Access API
  bridge.js              JS host (~200 lines: Canvas, input, WebSocket)
  shaders/
    cell.wgsl            WebGPU vertex/fragment shaders
  dist/
    index.html           HTML shell
    cotty.wasm           Built output
    cotty.js             Generated JS glue
```

### Architecture

```
ONE codebase (libcotty — shared Cot logic):
  Terminal emulation, VT parser, editor, workspace, themes

THREE delivery modes:
  1. macos/    → Swift/Metal (current, native performance)
  2. linux/    → GTK4/OpenGL (current, native)
  3. web/      → Wasm/WebGPU (NEW — runs in browser + native webview)

web/ is platform-independent:
  Same cotty.wasm runs in Chrome, Firefox, Safari, WKWebView, WebKitGTK

Hybrid data model:
  Editor:    local files via WASI / File System Access API
  Terminal:  WebSocket to `cot serve` backend (PTY + shell)
```

## Build Commands

```bash
# === macOS (Swift + Metal) ===
cd libcotty && cot build src/ffi.cot --lib -o libcotty.dylib && cd ..
ln -sf libcotty/libcotty.dylib libcotty.dylib  # one-time setup
cd macos && swift build
macos/.build/debug/Cotty

# === Linux (GTK4 + OpenGL) ===
cd linux && cot build src/main.cot -o cotty
./linux/cotty

# === Web (Wasm + WebGPU/Canvas) ===
cd web && cot build src/main.cot --target=js -o dist/cotty.wasm
python3 -m http.server 8080 -d dist/   # serve locally
open http://localhost:8080              # open in browser
```

The root `libcotty.dylib` symlink is needed because the Cot compiler emits bare install names. The Swift linker (`-L..`) and dyld rpath both resolve to the cotty root. The symlink is gitignored.

## Cot Backend (libcotty submodule)

All Cot source, tests, and architecture docs live in `libcotty/`. See `libcotty/CLAUDE.md` for Cot-specific instructions.

```bash
# Run Cot tests (from repo root)
cd libcotty && cot test src/app.cot
cd libcotty && cot test src/buffer.cot
cd libcotty && cot check src/main.cot

# Or from within the submodule
cd libcotty
cot build src/ffi.cot --lib -o libcotty.dylib
cot test src/app.cot
```

## Reference Architecture

The Cot backend references Ghostty and Zed — those submodules live inside `libcotty/references/`.

## Key Files

| File | Purpose |
|---|---|
| `macos/Sources/Cotty/main.swift` | App entry point |
| `macos/Sources/Cotty/AppDelegate.swift` | NSApplication delegate |
| `macos/Sources/Cotty/TerminalView.swift` | Terminal NSView |
| `macos/Sources/Cotty/MetalRenderer.swift` | Metal rendering pipeline |
| `macos/Sources/Cotty/GlyphAtlas.swift` | Font glyph atlas |
| `macos/Sources/Cotty/InspectorView.swift` | Key inspector overlay |
| `macos/Sources/CCottyCore/include/cotty.h` | FFI C header |
| `libcotty/src/ffi.cot` | FFI export layer |

## Behavioral Guidelines

**DO:**
- Keep Swift as thin as possible — just platform bindings
- Read libcotty/CLAUDE.md before modifying Cot code
- Test after every change (`cot test`, `swift build`)
- Report Cot compiler limitations to the user

**DO NOT:**
- Put application logic in Swift
- Work around Cot compiler bugs in Swift
- Modify Cot source without reading the Ghostty reference first
- Skip testing
