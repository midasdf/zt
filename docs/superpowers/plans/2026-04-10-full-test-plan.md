# zt Full Test Plan

**Goal:** Cover the full user-visible feature set of `zt` with a repeatable test plan, using existing unit tests and X11/Xvfb integration suites as the primary automation path.

**Scope date:** 2026-04-10

## Coverage Strategy

`zt` has four broad verification layers:

1. **Core unit tests** for parser, terminal state, renderer, input mapping, PTY, and Wayland helper modules.
2. **X11/Xvfb integration tests** for process lifecycle, window creation, keyboard input, escape-sequence handling, resize, and clipboard-related behavior.
3. **Real application tests** for common TUI/CLI workloads (`vim`, `nano`, `less`, `man`, `git`, `python3`, `fish`, etc.).
4. **Manual or environment-specific checks** for backends and behaviors that cannot be fully asserted in this Linux/X11 environment.

## Functional Inventory

### 1. Core terminal engine

- VT parser: ASCII, UTF-8, CSI, OSC, DEC private modes
- Terminal state: cursor, scroll regions, alternate screen, dirty tracking, row-map scrolling
- Text attributes: SGR, 256-color, TrueColor, underline styles/colors, hyperlinks
- Character handling: tabs, wide CJK cells, overwrite repair

### 2. Input and PTY

- Keyboard translation: printable keys, modifiers, function keys, cursor keys, DECCKM
- PTY spawn/read/write behavior
- Bracketed paste mode tracking

### 3. Rendering

- Palette mapping
- Pixel writes and scaling
- Cell rendering with glyph/no-glyph paths

### 4. Platform/backend behavior

- X11 window lifecycle and input loop
- Resize handling
- Clipboard paste path on X11
- Wayland protocol helper logic
- fbdev / macOS backend build or manual smoke coverage

### 5. Application compatibility

- Editors: `vim`, `nano`, `micro`
- Pagers: `less`, `man`
- Shell / REPL: `fish`, `python3`
- Monitoring / rich TUI: `top`, `btop`
- Colored output: `bat`, `git`, `eza`, `tree`, `rg`

## Automated Test Matrix

### Unit tests

- Command: `zig build test`
- Current source coverage by test count:
- `src/vt.zig`: 35
- `src/input.zig`: 26
- `src/term.zig`: 14
- `src/render.zig`: 8
- `src/font.zig`: 9
- `src/pty.zig`: 1
- `src/backend/wayland/*`: 28 total
- Success criteria: all tests pass, no panic, no linker/runtime regressions

### X11/Xvfb integration suite

- Command: `./test-xvfb-local.sh`
- Verifies:
- Unit test invocation from clean script path
- Debug/release binary launch
- Window creation
- Keyboard input survival
- Bulk output
- Rapid input
- TrueColor and 256-color stress
- Alternate screen
- Cursor movement stress
- CJK wide text
- Scroll region
- Erase/insert/delete sequences
- Graceful shutdown on `SIGTERM` and WM close
- Success criteria: all sections pass, no unexpected process death

### Real application suite

- Command: `ZT=/tmp/zt-release ./test-apps.sh`
- Verifies:
- Editor workflows
- Paging/search/navigation
- Colored and TrueColor output
- Shell completion/history/interrupt
- Resize stress under X11
- Mixed I/O and Unicode content
- Alternate screen and SGR combinations
- Success criteria: all mandatory apps pass; optional apps may report `SKIP`

## Environment-Specific Checks

These are part of the full feature plan, but are not guaranteed to be runnable in this environment:

- `zig build -Dbackend=wayland`
- Wayland manual smoke test: launch, keyboard, IME, clipboard, resize
- `zig build -Dbackend=fbdev`
- fbdev manual smoke test on Linux console device
- `zig build -Dbackend=macos -Dtarget=<mac target>`
- macOS launch/manual smoke test on real hardware

## Gaps That Need Manual Verification

- Visual fidelity of rendering, glyph shapes, underline styles, and cursor shapes
- Clipboard interoperability beyond “does not crash”
- OSC 8 hyperlink UX because click-to-open is not implemented
- IME candidate/preedit UX on Wayland/X11
- Frame pacing and benchmark regression checks

## Execution Order

1. Run `zig build test`
2. Build X11 release/debug binaries used by integration tests
3. Run `./test-xvfb-local.sh`
4. Run `ZT=/tmp/zt-release ./test-apps.sh`
5. Record pass/fail/skip and list any gaps

## Result Template

- `zig build test -Dbackend=x11 --cache-dir /tmp/zt-cache --global-cache-dir /tmp/zt-global-cache`: PASS
- `zig build test -Dbackend=wayland --cache-dir /tmp/zt-cache-test-wayland --global-cache-dir /tmp/zt-global-cache`: PASS
- `zig build test -Dbackend=fbdev --cache-dir /tmp/zt-cache-test-fbdev --global-cache-dir /tmp/zt-global-cache`: PASS
- `zig build -Dbackend=x11 -Doptimize=Debug/ReleaseFast`: PASS
- `zig build -Dbackend=wayland -Doptimize=Debug`: PASS
- `zig build -Dbackend=fbdev -Doptimize=Debug`: PASS
- `./test-xvfb-local.sh`: PASS (`22 passed, 0 failed`)
- `ZT=/tmp/zt-release ./test-apps.sh`: PASS (`51 passed, 0 failed`)
- Deferred manual checks:
- Wayland runtime smoke test on a real Wayland session
- fbdev runtime smoke test on a Linux framebuffer console
- macOS compile/run verification on real macOS hardware
- Visual fidelity checks for cursor shapes, underline styles, and IME UX
