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
.mcp.json          MCP config
libcotty/          Git submodule → cot-land/libcotty (all Cot source)
macos/
  Package.swift
  Sources/
    CCottyCore/
      include/cotty.h    FFI header (Swift ↔ Cot bridge)
      lib/               Built dylib (gitignored)
      shim.c
    Cotty/
      *.swift            macOS app (AppKit, Metal rendering)
```

## Build Commands

```bash
# Build Cot dylib from submodule
cd libcotty && cot build src/ffi.cot --lib -o libcotty.dylib

# Copy to Swift project
cp libcotty/libcotty.dylib macos/Sources/CCottyCore/lib/

# Build Swift app
cd macos && swift build

# Binary at
macos/.build/debug/Cotty
```

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
