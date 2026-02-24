# Cotty — Vision

## What is Cotty?

Cotty is a terminal-first text editor written in Cot. It follows the Ghostty model: a high-performance core written in a systems language, with thin platform shells for native UI.

## Architecture

**Cot core** — The editor engine (buffer, cursor, input, surface) is written entirely in Cot. This compiles to a shared library (`libcotty.dylib` / `libcotty.so`) via `export fn`, exposing a C FFI interface.

**Platform shells** — Thin native wrappers call into the Cot core:
- **macOS**: Swift + Metal rendering (current target)
- **Linux**: Wayland + Vulkan (future)
- **Web**: Wasm + Canvas (future)

Shells handle only what the platform requires: window creation, GPU rendering, input event capture. All editor logic lives in Cot.

## Rendering

Metal (macOS) / Vulkan (Linux) — GPU-accelerated glyph rendering. No CPU text layout in the hot path. The Cot core produces a cell grid; the shell renders it.

## Terminal

Cotty will embed a PTY-backed terminal emulator. The Cot core handles VT parsing and the cell grid. The shell renders cells via the GPU. This is the Ghostty architecture: terminal state in the systems language, rendering in the platform layer.

## Interface

AI and CLI agents are the primary interface. Cotty is designed to be driven programmatically — agent commands, structured input, piped workflows. The GUI is a viewport, not the control surface.

## Principles

1. **Cot is the source of truth.** No logic duplication in Swift/platform code.
2. **Port, don't invent.** Architecture decisions reference proven implementations (Ghostty, Zig, Helix).
3. **Thin shells.** Platform code is a rendering adapter, not an application.
4. **Terminal-first.** The editor is a terminal that happens to have text editing.
