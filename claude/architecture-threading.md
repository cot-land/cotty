# Cotty Architecture: Threading Model vs Ghostty

## Source
Mitchell Hashimoto interview (Feb 2025) describing Ghostty's architecture.

## Ghostty's 3-Thread Model

1. **UI thread** — draws windows, handles keyboard/mouse input
2. **IO thread** — reads/writes PTY bytes to/from the shell process
3. **Renderer thread** — runs on VSync clock (30/60/120 Hz), samples terminal state and draws

Key insight from Mitchell: "The best way to think about it is it's on a VSync clock... it's just sampling what the terminal state is and then drawing it."

## Cotty's Current Model: Single-Threaded (Main Queue)

Everything runs sequentially on the main thread:

| Component | Thread | Trigger |
|-----------|--------|---------|
| PTY read | Main | `DispatchSource.makeReadSource(fd, queue: .main)` |
| VT parsing | Main | Called inline after read, byte-by-byte via `cotty_terminal_feed_byte()` |
| Terminal state mutation | Main | `VtParser.feed()` -> `TerminalState.putChar()` etc. |
| Metal rendering | Main | Called after PTY read burst via `renderFrame()` |
| Cursor blink | Main | `Timer.scheduledTimer()` |
| Keyboard/mouse input | Main | `NSView.keyDown()` / `mouseDown()` |

### Why It Works (But Shouldn't Stay This Way)
- Non-blocking I/O (`O_NONBLOCK` on PTY fd)
- DispatchSource delivers events to main queue — FIFO, no races
- No locks, no atomics, no synchronization needed

**Note:** Cot now has full threading support — Thread, Mutex, Condition, Atomics, Channel(T). The IO thread separation should be implemented in Cot, not Swift.

### Where It Diverges from Ghostty

#### 1. No IO Thread
Ghostty reads PTY on a dedicated thread and queues parsed state for the UI thread. Cotty reads on main — if the shell dumps heavy output, it blocks input handling and rendering until the read loop drains.

#### 2. No VSync Rendering
Ghostty's renderer samples terminal state on a CVDisplayLink clock. Cotty renders on-demand after every PTY read burst. No throttle — fast shell output (e.g. `cat large_file`) causes excessive render calls. No unnecessary renders during idle.

#### 3. No Render/State Separation
Ghostty's renderer thread can safely sample grid state while the IO thread updates it (using thread-safe queues/locks). Cotty reads the cell buffer directly via raw pointer (`cotty_terminal_cells_ptr`). Safe only because everything is on main.

## Path to Ghostty-Like Architecture

### Threading Primitives Available in Cot
- `Thread.spawn(func, arg)`, `.join()`, `.detach()` (wraps pthreads)
- `Mutex.init()`, `.lock()`, `.unlock()`, `.tryLock()`, `.destroy()`
- `Condition.init()`, `.wait(mutex)`, `.signal()`, `.broadcast()`, `.destroy()`
- `@atomicLoad`, `@atomicStore`, `@atomicAdd`, `@atomicCAS`, `@atomicExchange`
- `Channel(T)` — SPSC ring buffer with send/recv/close

### Phase 1: IO Reader Thread (NEXT)
Following Ghostty's architecture: the **IO reader thread** is the hot path.
- Spawn a dedicated Cot thread that reads PTY bytes in a blocking loop
- Feed bytes through VT parser on the IO thread (under mutex)
- Protect TerminalState with a Mutex
- Set an atomic dirty flag after state changes
- Swift polls the dirty flag on render (or gets notified via a pipe/eventfd)
- Swift only holds the mutex briefly during `renderFrame()` to read cell data
- **All logic in Cot** — Swift just starts the thread and checks the flag

### Phase 2: VSync Rendering
- Add `CVDisplayLink` or `CADisplayLink` to drive rendering at display refresh rate
- Renderer only draws when dirty + VSync fires
- Eliminates excessive renders during fast output

### Phase 3: Render Thread (Optional)
- Separate Metal rendering from the UI thread
- Sample grid state, build CellData array, submit GPU work on render thread
- Most complex — requires careful synchronization

## Mitchell's Key Quotes

- "It's like a browser but for text content"
- "30% terminal, 70% font renderer"
- "The hardest part is actually maintaining the terminal state"
- "That terminal screen you see is like you're drawing on a canvas"
- Renderer submission: ~9 microseconds per frame (down from 800)
- "A 120 Hz frame is 8,333 microseconds. So if you have nine... you're leaving a lot of options"

## Performance Note

Mitchell benchmarks `cat` of large files as the obvious speed test. Modern terminals (Ghostty, Kitty, Alacritty) all significantly outperform Terminal.app. Cotty's single-threaded model will bottleneck here because PTY read + VT parse + render all compete for main thread time.
