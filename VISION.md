# Cotty — Vision

## The Problem

Software engineering is shifting. The primary activity is no longer hand-crafting code line by line — it's directing AI agents and validating their output. But the tools haven't caught up. You run Claude Code in a terminal, then Alt-Tab to an editor to review what it wrote, then back to the terminal to approve or redirect. Terminal and editor are separate worlds with a context switch between them.

Ghostty proved that a terminal emulator can be a serious native application — GPU-accelerated, platform-native, written in a systems language. Zed proved that an editor can be fast enough to feel like part of the OS. Cotty combines both ideas: a terminal and editor in one process, where agent sessions and editing surfaces live side by side as tabs or split panes.

## What Cotty Is

Cotty is a terminal-editor hybrid. A Ghostty-class terminal emulator and a Zed-class text editor sharing the same window, the same rendering pipeline, and the same surfaces.

Run an AI agent in one pane. The files it modifies open automatically in adjacent editor tabs. Review diffs inline. Accept or reject changes without leaving the surface. The terminal *is* the editor. The editor *is* the terminal.

This isn't a terminal embedded in an editor (VS Code) or an editor embedded in a terminal (Neovim). It's one application where both are first-class surfaces rendered by the same GPU pipeline, managed by the same surface model, and driven by the same input system.

## Architecture

Cotty follows the Ghostty model exactly: a high-performance core in a systems language with thin native platform shells.

**Cot core** — All logic lives here: text buffers (Zed-inspired rope/gap buffer), cursor management, input dispatch, terminal state, VT parsing, surface lifecycle, and the app state machine. Compiles to `libcotty.dylib` / `libcotty.so` via `export fn`, exposing a C FFI with opaque handles.

**Platform shells** — Thin native wrappers:
- **macOS**: Swift + AppKit + Metal
- **Linux**: GTK + Vulkan (or OpenGL)

Shells handle window management, GPU rendering, and platform input capture. Nothing else. The Cot core is the source of truth for all application state.

**Rendering** — GPU-accelerated cell grid rendering. The Cot core produces cells; the shell draws them. Same pipeline for terminal cells and editor cells. Metal on macOS, Vulkan on Linux.

## Surface Model

Every tab or pane is a Surface. A surface is either a terminal (PTY-backed, VT-parsed cell grid) or an editor (buffer-backed, cursor-tracked text). Both types share the same rendering path, the same input routing, and the same lifecycle in the App's surface list.

Surfaces can be arranged in tabs (like Ghostty) or split panes (like Zed). An agent running in a terminal surface can trigger editor surfaces to open — same window, zero context switch.

## Why Cot

Cotty is a dogfooding project for the Cot language. Every real-world problem Cotty hits — missing generics, FFI gaps, codegen bugs — drives the language forward. The Cot compiler is developed in parallel, and Cotty is its most demanding consumer.

The native backend produces real 64-bit pointers with standard C ABI, which makes the Ghostty-style opaque handle pattern work directly: Cot `export fn` functions are callable from Swift or C with no bridging layer beyond a header file.

## Principles

1. **Terminal and editor are the same thing.** Different surface types, same application model.
2. **AI agents are the primary user.** The interface is optimized for agent-driven workflows, not mouse-driven ones.
3. **Port, don't invent.** Terminal from Ghostty. Editor from Zed. Architecture from both.
4. **Native on every platform.** macOS and Linux with platform-native shells. No Electron, no web views.
5. **Cot is the source of truth.** Zero logic in platform code. Swift and GTK are rendering adapters.
6. **Validate, don't write.** The editing experience is built for reviewing and approving AI output, not typing from scratch.
