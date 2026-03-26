# ⚡zt — the fastest terminal emulator. 3.9ms startup. 83 MB/s throughput. 5.9MB RSS. Pure Zig.

[![Zig](https://img.shields.io/badge/Zig-0.15+-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/Platform-Linux-yellow?logo=linux&logoColor=white)](https://kernel.org)

Minimal terminal emulator written in Zig. Renders directly to the Linux framebuffer or X11 via shared memory. No GPU required.

![Image](https://github.com/user-attachments/assets/01ab9a42-2efe-41f7-b123-e7312dc5b8d7)

Built for the [HackberryPi Zero](https://github.com/ZitaoTech/Hackberry-Pi_Zero) (RPi Zero 2W + 720x720 HyperPixel4), but runs on any Linux system.

## Features

- **Dual backend** — framebuffer direct rendering (no X11/Wayland) or XCB + SHM under X11
- **Comptime everything** — backend, font, palette, pixel scale all resolved at compile time. Zero runtime cost for unused code paths
- **Pixel scaling** — `-Dscale=2` or `-Dscale=4` for HiDPI/PC displays. Integer scaling renders each bitmap pixel as an NxN block. Same font blob, no quality loss
- **Row-map scroll** — O(1) scroll via row indirection table instead of cell copying. 60K scrolls move 44MB of pointers vs 880MB of cell data
- **Damage tracking** — per-cell dirty bitmap with O(1) flag, row-level skip, dirty region present. Scroll marks only recycled rows dirty
- **Double-buffered SHM** — tear-free X11 rendering with lazy second-buffer init (no startup cost)
- **XKB keyboard layout** — any X11 keyboard layout works automatically via libxkbcommon (US, JP, DE, FR, etc.)
- **Input method (XIM)** — Japanese/Chinese/Korean input via fcitx5, ibus, etc. Lazy-initialized on first key press
- **xterm-256color + 24-bit TrueColor** — full SGR attributes (bold, italic, underline, reverse, dim), DEC modes, alternate screen
- **CJK wide character support** — correct double-width rendering with wide-char boundary repair on erase/delete
- **59,635 glyphs** — UFO bitmap font + Nerd Fonts icons, embedded as binary blob
- **Frame rate limiter** — configurable max FPS (`-Dmax_fps=N`, default 120). Skips rendering during heavy output, parsing continues at full speed. Dynamic epoll timeout for zero-waste idle
- **Bulk ASCII fast path** — VT parser writes directly to cell array with SIMD range checking (@Vector 16-byte) and range-based dirty marking
- **UTF-8 bulk path** — ground-state multi-byte characters decoded directly, bypassing per-byte parser state machine
- **PTY drain loop** — reads all available data (256KB buffer) before rendering, reducing frame count during bulk output
- **Write buffering** — PTY writes buffered on backpressure with EPOLLOUT retry
- **ConfigureNotify coalescing** — drag-resize processes only the final size, skipping intermediate reallocation
- **No libc** (fbdev) — pure `std.posix` syscalls, single static binary
- **73 unit tests** across 7 modules

## Numbers

|  | fbdev | X11 |
|---|---|---|
| Binary (with 59K-glyph font) | 2.8 MB | 2.8 MB |
| Runtime dependencies | none | libxcb, libxcb-shm, libxcb-xkb, libxkbcommon, libxcb-imdkit |
| Build time | < 1s | < 1s |
| Source | 5,488 lines across 11 files |  |

## Benchmarks

Measured on Intel i5-12450H, 1 CPU core, Xvfb, `-Doptimize=ReleaseFast`. Pre-warmed page cache, 50 startup runs (10 warmup), 20 throughput runs (5 warmup). See [zt-bench](https://github.com/midasdf/zt-bench) for full benchmark suite and historical results.

### Startup (50 runs)

| | Time | vs zt |
|---|---|---|
| **zt** | **3.9ms** | 1.0x |
| xterm | 15.0ms | 3.8x |
| st | 41.3ms | 10.5x |
| alacritty | 105.4ms | 27x |
| kitty | 207.2ms | 53x |
| ghostty | 395.0ms | 100x |

### Throughput (4.7MB dense ASCII, 20 runs)

| | Time | MB/s | vs zt |
|---|---|---|---|
| **zt** | **56.6ms** | **83** | 1.0x |
| st | 165.0ms | 28.5 | 2.9x |
| xterm | 176.5ms | 26.6 | 3.1x |
| alacritty | 218.4ms | 21.5 | 3.9x |
| kitty | 303.8ms | 15.5 | 5.4x |
| ghostty | 587.1ms | 8.0 | 10.4x |

### Peak RSS

| | RSS |
|---|---|
| **zt** | **5.9 MB** |
| xterm | 13.3 MB |
| st | 30.3 MB |
| alacritty | 126.2 MB |
| kitty | 142.1 MB |
| ghostty | 223.1 MB |

## Build

Requires Zig 0.15+.

### Build Profiles

**PC (maximum speed):**
```sh
zig build -Dbackend=x11 -Doptimize=ReleaseFast
```

**HackberryPi (minimum size):**
```sh
zig build -Doptimize=ReleaseSmall
```

ReleaseFast enables aggressive inlining, loop unrolling, and SIMD auto-vectorization.
ReleaseSmall minimizes binary size for constrained devices (512MB RAM).

### Examples

```sh
# fbdev (default) — runs on bare Linux console
zig build -Doptimize=ReleaseSmall

# X11 — runs under window managers
zig build -Dbackend=x11 -Doptimize=ReleaseFast

# X11 with 2x pixel scaling for PC/HiDPI displays
zig build -Dbackend=x11 -Dscale=2 -Doptimize=ReleaseFast

# X11 with 4x pixel scaling for 4K displays
zig build -Dbackend=x11 -Dscale=4 -Doptimize=ReleaseFast

# X11 with 60fps cap (battery saving)
zig build -Dbackend=x11 -Dmax_fps=60 -Doptimize=ReleaseFast

# X11 with unlimited frame rate (no cap)
zig build -Dbackend=x11 -Dmax_fps=0 -Doptimize=ReleaseFast

# fbdev with JIS keyboard layout (default: us)
zig build -Dkeymap=jp -Doptimize=ReleaseSmall

# Cross-compile for aarch64 (fbdev, static binary)
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall

# Cross-compile for aarch64 (X11, needs target sysroot with XCB libs/headers)
zig build -Dtarget=aarch64-linux-gnu.2.38 -Dbackend=x11 -Doptimize=ReleaseFast \
  --search-prefix /path/to/aarch64-sysroot

# Run tests
zig build test
```

## Configuration

Edit `config.zig` and rebuild — [st](https://st.suckless.org/)-style, no runtime config files.

```zig
pub const backend: Backend = .fbdev;  // .fbdev or .x11 (set via -Dbackend)
pub const keymap: Keymap = .us;       // .us or .jp (set via -Dkeymap; fbdev only, X11 uses XKB)
pub const default_fg: u8 = 7;        // white
pub const default_bg: u8 = 0;        // black
pub const font_width: u32 = 8;       // bitmap glyph width (half-width)
pub const font_height: u32 = 16;     // bitmap glyph height
pub const scale: u32 = 1;            // pixel scale factor: 1, 2, or 4 (set via -Dscale)
pub const max_fps: u32 = 120;        // max frame rate: 0 = unlimited (set via -Dmax_fps)
pub const frame_min_ns: u64 = ...;   // computed: 1_000_000_000 / max_fps (0 if unlimited)
pub const cell_width = font_width * scale;   // screen cell width
pub const cell_height = font_height * scale; // screen cell height
pub const shell = "/bin/fish";        // login shell
```

## Font

zt embeds a pre-compiled binary font blob at compile time via `@embedFile`. The default font includes 62,595 glyphs (Japanese, Nerd Fonts icons, emoji).

```sh
# Download pre-built font (recommended)
curl -Lo src/fonts/ufo-nf.bin https://github.com/midasdf/zt-fonts/raw/main/ufo-nf.bin
```

See [zt-fonts](https://github.com/midasdf/zt-fonts) for BDF sources, build scripts, alternative fonts, and custom font creation.

## Architecture

```
epoll event loop (single-threaded, dynamic timeout)
├── PTY reader (256KB buffer, drain loop)
│   └── VT parser (byte-by-byte state machine)
│       ├── ASCII fast path: SIMD 16-byte range check + bulk write to cells[]
│       ├── UTF-8 fast path: direct decode, bypassing parser state machine
│       └── Action executor → Cell grid mutations via row_map
├── Input handler
│   ├── evdev (fbdev) — raw keyboard events, compile-time keymap (US/JP)
│   └── X11 — XKB + XIM (lazy-initialized on first key press)
├── Term grid
│   ├── row_map[logical] → physical: O(1) scroll via pointer rotation
│   ├── Dirty bitmap (logical order) with O(1) hasDirty flag
│   └── TrueColor sparse maps (physical keys, no shift on scroll)
├── Renderer (frame-rate limited, -Dmax_fps=120 default)
│   ├── hasDirty() O(1) flag check → skip if nothing changed
│   ├── Frame limiter: skip render if < frame_min_ns since last frame
│   ├── isRowDirty() → skip clean rows
│   └── Per-cell: glyph lookup → scaled pixel composition (memcpy row duplication)
├── Backend
│   ├── fbdev: shadow buffer → dirty row memcpy to /dev/fb0 mmap
│   └── X11: double-buffered SHM → dirty region xcb_shm_put_image
├── Signal handling (signalfd: SIGCHLD, SIGTERM, SIGINT, SIGHUP)
├── VT switching (fbdev: SIGUSR1/2 for console switch)
├── Cursor blink (timerfd, 500ms interval)
└── Write buffer (4KB, EPOLLOUT-driven retry on backpressure)
```

### Source files

| File | Lines | Purpose |
|------|-------|---------|
| `src/vt.zig` | 1,238 | VT parser state machine + action executor, SIMD ASCII fast path, UTF-8 bulk path |
| `src/backend/x11.zig` | 950 | XCB window, double-buffered SHM, XKB + XIM (lazy init), ConfigureNotify coalescing |
| `src/term.zig` | 822 | Cell grid with row_map indirection, O(1) dirty flag, scroll, erase, TrueColor sparse maps |
| `src/main.zig` | 559 | Event loop, frame limiter, signal/timer setup, PTY drain, write buffering, render orchestration |
| `src/input.zig` | 527 | Keymap (US/JP), evdev code translation, modifier handling |
| `src/render.zig` | 389 | Pixel rendering with comptime scaling (BGRA32/RGB565/RGB24), memcpy row duplication |
| `src/backend/fbdev.zig` | 319 | Framebuffer mmap, shadow buffer, evdev keyboard scan, VT switching |
| `src/font.zig` | 353 | Binary blob loader, comptime ASCII cache, 256-slot runtime glyph cache |
| `src/pty.zig` | 221 | PTY spawn, nonblocking I/O, resize (TIOCSWINSZ) |
| `config.zig` | 38 | Compile-time configuration (backend, keymap, font, colors, scale, max_fps) |
| `build.zig` | 72 | Build system with backend, keymap, scale, and max_fps selection |

## Supported escape sequences

### CSI sequences

| Sequence | Name | Description |
|----------|------|-------------|
| `CSI n A` | CUU | Cursor up |
| `CSI n B` | CUD | Cursor down |
| `CSI n C` | CUF | Cursor forward |
| `CSI n D` | CUB | Cursor back |
| `CSI n E` | CNL | Cursor next line |
| `CSI n F` | CPL | Cursor preceding line |
| `CSI n G` | CHA | Cursor horizontal absolute |
| `CSI n;m H/f` | CUP | Cursor position |
| `CSI n J` | ED | Erase display (0: below, 1: above, 2/3: all) |
| `CSI n K` | EL | Erase line (0: right, 1: left, 2: all) |
| `CSI n L` | IL | Insert lines |
| `CSI n M` | DL | Delete lines |
| `CSI n P` | DCH | Delete characters |
| `CSI n X` | ECH | Erase characters |
| `CSI n @` | ICH | Insert characters |
| `CSI n b` | REP | Repeat preceding graphic character |
| `CSI n S` | SU | Scroll up |
| `CSI n T` | SD | Scroll down |
| `CSI n d` | VPA | Vertical position absolute |
| `CSI t;b r` | DECSTBM | Set scroll region (resets cursor to home) |
| `CSI s` | | Save cursor position (no private marker) |
| `CSI u` | | Restore cursor position (no private marker) |
| `CSI 6 n` | DSR | Device status report (cursor position) |
| `CSI c` | DA1 | Device attributes (reports VT220) |
| `CSI ... m` | SGR | Select graphic rendition (see below) |

### SGR (Select Graphic Rendition)

| Code | Effect |
|------|--------|
| 0 | Reset all |
| 1 | Bold |
| 2 | Dim |
| 3 | Italic |
| 4 | Underline |
| 7 | Reverse video |
| 22 | Normal intensity |
| 23 | Not italic |
| 24 | Not underline |
| 27 | Not reverse |
| 30-37 | Foreground color (standard) |
| 38;5;n | Foreground 256-color |
| 38;2;r;g;b | Foreground 24-bit TrueColor |
| 39 | Default foreground |
| 40-47 | Background color (standard) |
| 48;5;n | Background 256-color |
| 48;2;r;g;b | Background 24-bit TrueColor |
| 49 | Default background |
| 90-97 | Foreground bright |
| 100-107 | Background bright |

### DEC private modes

| Mode | Name | Description |
|------|------|-------------|
| `?1` | DECCKM | Application cursor keys |
| `?7` | DECAWM | Auto-wrap mode |
| `?25` | DECTCEM | Cursor visible |
| `?47` | | Alternate screen buffer |
| `?1047` | | Alternate screen buffer |
| `?1049` | | Alternate screen + save/restore cursor |
| `?2004` | | Bracketed paste mode (flag only) |

### Escape sequences

| Sequence | Name | Description |
|----------|------|-------------|
| `ESC 7` | DECSC | Save cursor |
| `ESC 8` | DECRC | Restore cursor |
| `ESC D` | IND | Index (line feed, scrolls at bottom) |
| `ESC M` | RI | Reverse index |
| `ESC c` | RIS | Full reset |

## Tested applications

The following applications have been verified working under Xvfb integration tests:

vim, nano, micro, less, bat, top, btop, man, git (log/diff/status), eza, tree, ripgrep, python3 REPL, fish (completions, history, Ctrl+C, Ctrl+L), Claude Code

## Limitations

- No scrollback buffer — only the current viewport is kept
- No clipboard (OSC 52 parsed but not acted on)
- No mouse support
- fbdev keymap is compile-time only (US/JP); X11 uses XKB for any layout
- No inline pre-edit display — IME candidate window is handled by the input method (fcitx5 default)
- No font fallback chain — single embedded font
- No ligatures
- No sixel/image protocol support

## License

MIT
