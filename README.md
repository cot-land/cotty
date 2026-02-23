# Cotty

A purpose-built developer environment for the [Cot programming language](https://github.com/cot-land/cot).

## Philosophy

Most editors try to be everything for all languages, and each language has to conform to the plugin system. Cotty takes the opposite approach — going back to the Turbo Pascal and Visual Basic days, where the IDE is purpose-built for the language.

Cotty is to Cot what Turbo Pascal was to Pascal: a single, cohesive environment where the language and the editor are designed together.

## Goals

- **Purpose-built for Cot** — not a generic editor with a Cot plugin, but an editor that *is* a Cot tool
- **First-class integration** — build, run, test, check, lint, fmt, and LSP are not plugins — they are the editor
- **Wasm-native** — like Cot itself, Cotty targets both native (macOS, Linux) and Wasm for a browser-based experience
- **Ghostty-inspired architecture** — modeled on Ghostty's clean Zig architecture: core logic separated from platform-specific app runtimes, GPU-accelerated rendering, comptime interfaces

## Architecture

Cotty's architecture is modeled on [Ghostty](https://github.com/ghostty-org/ghostty), pivoting from terminal emulation to text editing:

```
src/
├── main.zig              # Entry point (build_config dispatches entrypoint)
├── App.zig               # Primary application state, surface management
├── Surface.zig           # A single editor surface (was: terminal surface)
├── Buffer.zig            # Text buffer / rope data structure
├── config.zig            # Configuration system
├── apprt.zig             # Application runtime abstraction
├── apprt/
│   ├── embedded.zig      # macOS AppKit (via libcotty C API)
│   ├── gtk.zig           # Linux GTK
│   └── none.zig          # Headless / CLI-only
├── renderer.zig          # Renderer abstraction
├── renderer/
│   ├── metal.zig         # Metal backend (macOS)
│   └── opengl.zig        # OpenGL backend (Linux)
├── editor/               # Core editing logic
│   ├── cursor.zig        # Cursor movement, multi-cursor
│   ├── selection.zig     # Selection model
│   ├── commands.zig      # Editor commands (insert, delete, move, etc.)
│   └── mode.zig          # Modal editing (if desired)
├── font/                 # Font loading, shaping, atlas
├── input/                # Keyboard/mouse input handling
├── cot/                  # Cot language integration
│   ├── lsp.zig           # Built-in LSP client (talks to `cot lsp`)
│   ├── build.zig         # Build system integration (`cot build`)
│   ├── diagnostics.zig   # Error/warning display
│   └── syntax.zig        # Syntax highlighting (tree-sitter or custom)
└── build_config.zig      # Comptime build configuration
```

### Key Ghostty Patterns Adopted

| Ghostty Pattern | Cotty Equivalent |
|---|---|
| `apprt` — compile-time platform abstraction | Same — swap AppKit/GTK/browser at comptime |
| `Surface.zig` — a terminal surface | `Surface.zig` — an editor surface (tab/split) |
| `terminal/` — VT parser, grid, screen | `editor/` — buffer, cursor, selection, commands |
| `renderer/` — Metal/OpenGL rendering | Same — GPU text rendering |
| `font/` — font discovery, shaping, atlas | Same — reuse font infrastructure |
| `config.zig` — configuration system | Same — editor configuration |
| `build_config.zig` — comptime dispatch | Same — target-specific builds |
| Mailbox/queue for cross-thread messaging | Same — event-driven architecture |

### Key Zed Patterns Referenced

| Zed Pattern | Cotty Consideration |
|---|---|
| Rope-based text buffer | Efficient buffer for large files |
| GPUI (custom GPU UI framework) | Inspiration for Zig-native GPU UI |
| Language server integration | Built-in, not pluggable — Cot LSP only |
| Workspace/project model | `cot.json` aware project system |

## Building

Requires [Zig](https://ziglang.org/) 0.15+.

```bash
zig build
./zig-out/bin/cotty
```

## References

The `references/` directory contains shallow submodule clones of projects that inform Cotty's design:

- **[Ghostty](https://github.com/ghostty-org/ghostty)** — Primary architectural reference. Zig-based, GPU-accelerated, clean separation of core logic from platform runtimes. Cotty pivots this architecture from terminal emulation to text editing.
- **[Zed](https://github.com/zed-industries/zed)** — Text editing reference. Rust-based, GPU-accelerated editor with rope buffers, GPUI framework, and excellent language server integration.

## Status

Early development. The project structure and architecture are being established.

## License

MIT
