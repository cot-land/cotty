# Cotty — AI Session Instructions

## ABSOLUTE #1 RULE — NEVER WORKAROUND, NEVER SIMPLIFY

**NEVER implement workarounds for missing Cot language features.** If the Cot compiler doesn't support a pattern you need, **STOP and tell the user** so they can implement the missing feature in the Zig compiler first. Cotty must use idiomatic Cot — every workaround is tech debt that defeats the purpose of dogfooding.

- **NO** restructuring code to avoid a language limitation
- **NO** extracting logic to helper functions just because a construct doesn't compile
- **NO** falling back to if-else chains because switch doesn't support something
- **NO** simplifying data structures because generics don't work for a case
- **ALWAYS** identify the exact compiler limitation and report it to the user
- The user will fix the Zig compiler. That is the correct workflow.

## DO NOT PUT ANY LOGIC INTO SWIFT

**SWIFT IS A THIN SHELL. ALL LOGIC LIVES IN COT.**

Cotty is a dogfooding project. The ENTIRE POINT is to exercise the Cot language by writing real application logic in Cot. Swift exists ONLY as a platform binding layer — it calls Cot FFI functions and renders what Cot tells it to render. Nothing more.

- **NO** implementing features in Swift that should be in Cot
- **NO** Swift-side workarounds for Cot compiler bugs — fix the compiler instead
- **NO** duplicating logic between Swift and Cot (PTY spawning, input handling, state management)
- **NO** "temporary" Swift implementations — they become permanent tech debt
- Swift may ONLY: create windows, set up Metal layers, forward raw input events to Cot, and render from Cot's data
- If a Cot runtime function crashes in dylib mode, the fix goes in the Zig compiler, NOT in Swift
- Every line of logic in Swift is a line that ISN'T dogfooding Cot

## CRITICAL RULES

### 1. Never Invent — Copy Ghostty/Zed Patterns

Cotty's architecture is modeled on Ghostty. When implementing a component, find the Ghostty reference first, then translate to Cot. Don't invent patterns — copy them.

### 2. Cot Language Reference Is ~/cotlang/cot

The Cot compiler lives at `~/cotlang/cot` (developed in parallel). When you need syntax examples, read `~/cotlang/cot/self/*.cot` for real working code. Read `~/cotlang/cot/docs/syntax.md` for the full syntax reference. **Never use archive folders.**

### 3. @safe Mode Enabled Project-Wide

Cotty uses `"safe": true` in `cot.json`. This enables:
- **Colon struct init**: `Type { field: value }` (not `.field = value`)
- **Implicit self**: methods get `self` injected automatically (no `self: *Type` parameter)
- **Auto-ref**: pass structs without `&`
- **`static fn`** constructors (no self injection)
- `/// doc comments`
- `test "name" { }` inline tests at bottom of files

### 4. Stdlib via Symlink

The Cot stdlib is resolved via a local symlink: `stdlib -> ~/cotlang/cot/stdlib`. This keeps cot-land projects always using the latest compiler stdlib with zero friction. The symlink is gitignored.

**Setup (one-time):**
```bash
cd ~/cot-land/cotty
ln -s ~/cotlang/cot/stdlib stdlib
```

## Project Overview

**Cotty** is a purpose-built developer environment for Cot, modeled on Ghostty's architecture but pivoting from terminal emulation to text editing. This is a dogfooding project — we're writing a real application in Cot to push the language forward.

## CLI

```
cot check src/main.cot          # Type-check the full project
cot test src/buffer.cot         # Run buffer tests
cot test src/cursor.cot         # Run cursor tests
cot test src/app.cot            # Run app tests
cot run src/main.cot -- help    # Print usage
cot run src/main.cot -- version # Print version
```

## Architecture

```
src/main.cot       Entry point, CLI dispatch
src/app.cot        Application state (surfaces, config, mailbox)
src/surface.cot    Editor surface (buffer + cursor + viewport)
src/buffer.cot     Gap buffer text storage
src/cursor.cot     Cursor position tracking
src/config.cot     Configuration loading
src/input.cot      Input event handling
src/message.cot    Mailbox messages for inter-component comms
```

```
User Input → InputAction → Surface.handleInput()
                              ├── Buffer.insert/delete (text mutation)
                              ├── Cursor.move* (position update)
                              └── Message → App.drainMailbox() (cross-component)

App.tick()
  ├── drainMailbox() → process queued messages
  └── Surface.render() → output
```

## Reference File Map

| Cotty File | Ghostty/Zed Reference |
|---|---|
| `src/main.cot` | `references/ghostty/src/main_ghostty.zig` |
| `src/app.cot` | `references/ghostty/src/App.zig` |
| `src/surface.cot` | `references/ghostty/src/Surface.zig` |
| `src/buffer.cot` | `references/zed/crates/rope/` (concept), custom gap buffer |
| `src/config.cot` | `references/ghostty/src/config.zig` |
| `src/input.cot` | `references/ghostty/src/input.zig` |
| `src/message.cot` | `references/ghostty/src/App.zig` (Mailbox/Message) |

## Testing

```bash
cot test src/buffer.cot    # Core data structure — must always pass
cot test src/cursor.cot    # Cursor logic
cot test src/app.cot       # App lifecycle
cot check src/main.cot     # Full type-check
```

Every file has inline `test "name" { }` blocks. Run `cot test <file>` to execute them.

## Behavioral Guidelines

**DO:**
- Read the Ghostty reference before implementing any component
- Copy `~/cotlang/cot/self/` code patterns exactly (colon init, implicit self, static fn)
- Write inline tests for every module
- Use `cot check` and `cot test` to verify changes
- Make incremental changes, verify each one
- Report missing Cot features to the user immediately

**DO NOT:**
- Invent patterns — copy reference implementations
- Work around compiler limitations
- Skip testing
- Use period-prefix struct init (`.field = value`) — use colon syntax (`field: value`)
- Comment out failing tests or leave TODOs
- Read from archive folders — always use `~/cotlang/cot`
