# Cotty — AI Session Instructions

## What is Cotty?

Cotty is a purpose-built developer environment for the Cot programming language. Think Turbo Pascal or Visual Basic — the IDE is designed for the language, not the other way around.

## Architecture

Cotty's architecture is modeled on Ghostty (see `references/ghostty/`), pivoting from terminal emulation to text editing. The core design principles:

1. **Copy, don't invent** — follow the same approach as the Cot compiler. Reference implementations are in `references/`. Copy patterns from Ghostty (Zig architecture, rendering, platform abstraction) and Zed (text editing, buffers, editor UX).

2. **Comptime platform abstraction** — Ghostty's `apprt` pattern: a single `apprt.zig` that uses `build_config` to select the platform implementation at compile time (AppKit on macOS, GTK on Linux, browser via Wasm).

3. **Core/Surface separation** — `App.zig` owns application state and surface management. `Surface.zig` is a single editor view. Core editing logic is platform-independent.

4. **GPU-accelerated rendering** — Metal on macOS, OpenGL on Linux. Text rendering via font atlas, same approach as Ghostty.

## Key References

- `references/ghostty/src/App.zig` — Application state, surface management
- `references/ghostty/src/Surface.zig` — Surface abstraction
- `references/ghostty/src/apprt.zig` — Platform runtime abstraction
- `references/ghostty/src/apprt/` — Platform implementations
- `references/ghostty/src/renderer/` — GPU rendering backends
- `references/ghostty/src/font/` — Font loading, shaping, atlas
- `references/ghostty/src/config.zig` — Configuration system
- `references/ghostty/build.zig` — Build system
- `references/zed/crates/editor/` — Text editing core
- `references/zed/crates/rope/` — Rope data structure for text buffers
- `references/zed/crates/gpui/` — GPU UI framework

## Cot Language Integration

Cotty has first-class Cot support — not via plugins but built directly in:

- **LSP**: Talks to `cot lsp` for completions, diagnostics, hover, go-to-definition
- **Build**: Runs `cot build`, `cot run`, `cot test` directly
- **Diagnostics**: Inline error/warning display from `cot check`
- **Formatting**: `cot fmt` on save
- **Project awareness**: Reads `cot.json` for project configuration

## Build

```bash
zig build              # Build cotty
zig build test         # Run tests
```

## Rules

- Zig 0.15+ required
- Follow Ghostty's Zig style and patterns
- Keep platform-specific code behind `apprt` abstraction
- Core editor logic must be platform-independent
- Test on both native and Wasm targets
