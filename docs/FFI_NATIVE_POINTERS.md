# Cot AOT FFI: Native Pointer Design Options

## The Problem

Cot compiles to native ARM64/x86-64 but uses wasm as an internal IR. This means:

1. All Cot memory lives in a **linear memory region** starting at `vmctx + 0x40000`
2. Every load/store goes through `boundsCheckAndComputeAddr`:
   ```
   real_addr = heap_base + wasm_offset + static_offset
   ```
   where `heap_base = vmctx + 0x40000`
3. Cot "pointers" are 32-bit offsets into this linear memory (0 to ~256MB)

When Swift calls `cotty_insert_char(65)` — a scalar i64 — this works fine because 65 is just a number, not a memory address.

When Swift calls `cotty_load_content(ptr, len)` where `ptr` is a native Swift pointer like `0x16f800000` — the Cot code does `heap_base + 0x16f800000` = wildly invalid address. **Crash.**

Even `@intToPtr`/`@ptrToInt` in Cot operate within linear memory. There is no concept of "native address" in the current compiler.

---

## Current Architecture

```
VMContext layout (256MB virtual, pinned in x21 on ARM64):

  +0x00000  ─────────────  (reserved)
  +0x10000  ─────────────  Globals (each 16 bytes)
            heap_ptr         = 0x800000 (bump allocator position)
            freelist[0..3]   = 0 (size-class freelists)
  +0x20000  ─────────────  Heap metadata
            [0] heap_base    = vmctx + 0x40000  (written at init)
            [8] heap_bound   = 0xFFC0000         (baked into data)
  +0x30000  ─────────────  Args (argc/argv/envp, executable only)
  +0x40000  ─────────────  Linear memory starts here
            Data segments copied here at compile time
  +0x800000 ─────────────  Heap allocations start here (HEAP_START)
            ARC objects, strings, lists, etc.
  +0x10000000 ───────────  End of virtual memory (256MB)
```

Every memory access:
```
boundsCheckAndComputeAddr(heap, index, offset, size):
    effective_end = index + offset + size
    bound = load(vmctx + 0x20008)           // heap_bound
    if effective_end >= bound: trap
    base = load(vmctx + 0x20000)            // heap_base = vmctx+0x40000
    return base + index + offset
```

---

## Options

### Option 1: Scalar-Only FFI (No Pointers)

**What:** Never pass pointers across the FFI boundary. Only pass scalars (i64, f64, etc.). Host queries/mutates data one value at a time through exported getter/setter functions.

**Example (current approach):**
```swift
// Swift side — load file by inserting chars one at a time
CottyCore.initialize()
for ch in fileData.utf8 {
    CottyCore.insertChar(ch)   // cotty_insert_char(i64)
}
```

```cot
// Cot side — returns one char at a time
export fn cotty_buffer_char_at(pos: i64) i64 {
    return g_surface.buffer.charAt(pos)
}
```

**Pros:**
- Zero compiler changes
- Zero language changes
- Completely safe — no address space mismatch possible

**Cons:**
- Slow for bulk data (O(n) FFI calls to load a file)
- Awkward API design (can't pass strings, buffers, structs)
- **Currently crashing** for unknown reasons during bulk operations — the lib mode vmctx setup may have bugs independent of pointer issues

**Status:** Partially working. Single calls work (typing works). Bulk calls crash (file loading). The crash needs debugging before any option is viable.

---

### Option 2: Copy Into Linear Memory

**What:** Export functions that let the host write bytes directly into the Cot linear memory, then pass the wasm offset to Cot functions.

**Requires:**
1. Export a function that returns the base address of linear memory
2. Host writes data at a known offset within linear memory
3. Pass the wasm offset (not native pointer) to Cot functions

**New exports:**
```cot
/// Return native address of linear memory base (for host memcpy)
export fn cotty_linear_memory_base() i64 {
    // Need new builtin: @linearMemoryBase() or access vmctx+0x40000
    return @linearMemoryBase()
}

/// Allocate N bytes in linear memory, return wasm offset
export fn cotty_alloc(size: i64) i64 {
    // Use the existing bump allocator
    return @alloc(size)
}
```

```swift
// Swift side
let wasmBase = UnsafeMutableRawPointer(bitPattern: CottyCore.linearMemoryBase())!
let wasmOffset = CottyCore.alloc(Int64(data.count))
let dest = wasmBase.advanced(by: Int(wasmOffset))
data.withUnsafeBytes { src in
    dest.copyMemory(from: src.baseAddress!, byteCount: src.count)
}
CottyCore.loadFromOffset(wasmOffset, Int64(data.count))
```

**Compiler changes:**
- New builtin `@linearMemoryBase()` → emits `load(vmctx + 0x20000)` without bounds check
- Or: just bake it as `cotty_linear_memory_base` returning the runtime heap_base value

**Pros:**
- Single memcpy for bulk data — fast
- Cot code sees normal wasm offsets — no codegen changes to load/store
- Safe — data lives within bounds-checked linear memory

**Cons:**
- Host must understand wasm memory layout
- Data is limited to 256MB linear memory
- Requires a `@linearMemoryBase` builtin or equivalent
- Host and Cot must coordinate on memory lifetime (who frees?)
- Two-step API: allocate in wasm memory, then copy, then call

---

### Option 3: `extern ptr` Type (Bypass Linear Memory)

**What:** Add a new pointer type that represents a native address. Loads/stores through `extern ptr` emit direct memory access without `heap_base +` translation or bounds checking.

**Language change:**
```cot
/// An extern pointer — holds a native address, not a wasm offset.
/// Dereferencing does NOT go through linear memory translation.
export fn cotty_load_content(ptr: extern *u8, len: i64) void {
    var i: i64 = 0
    while (i < len) {
        const ch = ptr[i]  // direct native load, no heap_base addition
        g_surface.handleInput(InputAction.insert_char, ch)
        i += 1
    }
}
```

**Compiler changes:**
1. New type: `extern *T` (or `native *T` or `host *T`)
2. In wasm IR: represented as i64 (same as any pointer)
3. In `translateLoad`/`translateStore`: when the base pointer is typed as extern, emit a direct load/store instead of going through `boundsCheckAndComputeAddr`
4. Extern pointers cannot be stored in Cot data structures (they're transient)
5. `@ptrToInt` on extern ptr returns the native address directly
6. Cannot cast between `*T` (wasm) and `extern *T` (native)

**Codegen diff:**
```
// Normal wasm pointer load:
base = load(vmctx + 0x20000)     // heap_base
addr = base + index + offset
bounds_check(addr)
value = load(addr)

// Extern pointer load:
value = load(index + offset)      // direct native address, no translation
```

**Pros:**
- Clean, explicit type system distinction
- No data copying — zero overhead
- Works for any size data
- Host passes native pointers naturally
- Compiler enforces you can't accidentally mix pointer types

**Cons:**
- Language change (new type keyword)
- Codegen change in translator.zig (needs to detect extern ptr and skip bounds check)
- No bounds checking on extern pointers — unsafe by nature
- Cannot dereference extern pointers after the FFI call returns (dangling risk)
- Needs SSA builder changes to track the type through IR

**Complexity:** Medium — ~200 lines in frontend, ~50 lines in codegen

---

### Option 4: Host Function Callbacks (Wasmtime Pattern)

**What:** Instead of Cot reading host memory, the host provides callback functions that Cot calls to get data.

**New Cot pattern:**
```cot
/// Declare an imported host function
import fn host_read_byte(handle: i64, offset: i64) i64

export fn cotty_load_content(handle: i64, len: i64) void {
    var i: i64 = 0
    while (i < len) {
        const ch = host_read_byte(handle, i)
        g_surface.handleInput(InputAction.insert_char, ch)
        i += 1
    }
}
```

```swift
// Swift side — register callback, then call load
// The dylib imports host_read_byte which Swift provides
@_cdecl("host_read_byte")
func hostReadByte(handle: Int64, offset: Int64) -> Int64 {
    let data = loadedFiles[handle]!
    return Int64(data[Int(offset)])
}
CottyCore.loadContent(fileHandle, Int64(data.count))
```

**Pros:**
- No pointer passing at all — pure scalar FFI
- Clean separation of concerns
- Works with any host language
- Safe — no address space confusion

**Cons:**
- Per-byte callback overhead (similar to Option 1 but with indirection)
- Requires dylib to import symbols from the host (linker complexity)
- More complex API contract
- Batch callbacks (e.g., `host_read_chunk`) still need a buffer somewhere

---

### Option 5: Eliminate Wasm IR for Native Targets

**What:** Compile `Cot → native IR` directly, bypassing the wasm intermediate representation. All pointers become native pointers. No linear memory, no vmctx, no bounds checking indirection.

**How Ghostty avoids this problem:** Zig compiles to native LLVM IR directly. There is no wasm layer. Pointers are native pointers. `*u8` in Zig FFI is a real native address. This is why Ghostty's `libghostty.a` can pass `*u8` to/from Swift without any translation.

**What would change:**
- New native backend that doesn't use wasm opcodes as IR
- Pointers are 64-bit native addresses
- Memory allocation uses system malloc/mmap
- No vmctx, no linear memory region
- ARC runtime uses native pointers

**Pros:**
- Eliminates the entire impedance mismatch
- FFI becomes completely natural — `*u8` means a native pointer
- Better performance (no bounds check overhead, no heap_base addition)
- Simpler mental model for programmers

**Cons:**
- **Massive compiler refactor** — the entire codegen pipeline goes through wasm IR today
- Loses wasm-compatible bounds checking (memory safety story changes)
- Loses ability to target actual wasm runtimes (or would need two backends)
- Months of work, high risk

---

## Recommendation

**Short term: Fix Option 1 (scalar-only FFI)**

The current crash during bulk scalar operations is a bug in the lib mode vmctx setup or codegen — NOT a pointer problem. Even if we implement Option 3 (extern ptr), we'd still crash on the same underlying issue. **Debug and fix the lib mode crash first.**

**Medium term: Option 2 (copy into linear memory)**

Least compiler work for a working pointer-passing API. Add a `cotty_linear_memory_base()` export and let the host copy data in. The host treats Cot's linear memory as a shared buffer.

**Long term: Option 3 (extern ptr) or Option 5 (eliminate wasm IR)**

Option 3 if you want to keep wasm as IR (adds a new type, ~250 lines of compiler work).
Option 5 if you want a clean native story long-term (major refactor, but eliminates the root cause).

---

## Appendix: Debugging the Lib Mode Crash

The scalar-only FFI crashes when calling `cotty_insert_char` many times (file loading). The crash address is ~1.6GB past the vmctx region, suggesting corrupted address computation during allocation.

Possible causes:
1. **BSS not mapped**: The 255MB BSS region after the 1MB initialized vmctx_data may not be properly mapped by the Mach-O loader for dylibs. The executable gets BSS mapped by the kernel at exec time, but dylibs may handle BSS differently.
2. **Global initialization**: The allocator's `heap_ptr` global (at vmctx + 0x10000 + N*16) may not be properly initialized in the lib vmctx_data, causing the bump allocator to start at offset 0 instead of 0x800000.
3. **Missing heap_base at vmctx+0x20000**: The wrapper writes heap_base every call, but if an inner function clobbers x0 before the callee saves it to x21, the vmctx is lost.
4. **Stack pointer global**: The wasm SP global may not be initialized, causing stack corruption in functions that use wasm stack frames.
