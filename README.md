# Cotty

A macOS terminal emulator built with [Cot](https://github.com/cot-land) and Swift/Metal.

The terminal emulation backend lives in [libcotty](https://github.com/cot-land/libcotty) (included as a git submodule). This repo contains the macOS frontend — AppKit window management, Metal rendering, and font atlas.

## Setup

```bash
git clone --recursive https://github.com/cot-land/cotty.git
cd cotty

# Set up stdlib symlink in libcotty (one-time)
cd libcotty && ln -s ~/cotlang/cot/stdlib stdlib && cd ..
```

## Build

```bash
# Build Cot backend
cd libcotty && cot build src/ffi.cot --lib -o libcotty.dylib && cd ..

# Copy dylib and build Swift app
cp libcotty/libcotty.dylib macos/Sources/CCottyCore/lib/
cd macos && swift build

# Run
.build/debug/Cotty
```

## Architecture

Cotty is a dogfooding project for the Cot language. All application logic (terminal emulation, VT parsing, input handling, buffer management) is written in Cot. Swift serves only as a thin platform binding layer for macOS — creating windows, setting up Metal, and forwarding input events.

See [libcotty](https://github.com/cot-land/libcotty) for the Cot backend architecture and source.
