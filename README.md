# ⚡zt — the fastest terminal emulator. 73 MB/s throughput. 5.6ms startup. 2MB memory. Pure Zig.

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
- **Adaptive frame limiter** — 4-tier adaptive FPS (120→60→15→5) based on output volume. During extreme output, drops to 5fps for maximum parse throughput. Dynamic epoll timeout for zero-waste idle
- **Bulk ASCII fast path** — VT parser writes directly to cell array with SIMD range checking (@Vector 16-byte) and range-based dirty marking
- **UTF-8 bulk path** — ground-state multi-byte characters decoded directly, bypassing per-byte parser state machine
- **Scroll pixel memmove** — on scroll, shift pixel buffer via memmove and re-render only recycled rows. Saturated scrolls fall back to full re-render with global background fill
- **PTY drain loop** — reads all available data (configurable buffer, `-Dpty_buf_kb`, default 1MB) before rendering, reducing frame count during bulk output
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
| Source | 6,113 lines across 11 files |  |

## Benchmarks

Measured on Intel i5-12450H, 1 CPU core, real display (:0, hardware GPU), `-Doptimize=ReleaseFast`. See [zt-bench](https://github.com/midasdf/zt-bench) for full benchmark suite and methodology.

### Startup (hyperfine, 30 runs)

| | Time | vs zt |
|---|---|---|
| **zt** | **5.6ms** | 1.0x |
| xterm | 26ms | 4.6x |
| st | 52ms | 9.3x |
| alacritty | 136ms | 24x |
| ghostty | 492ms | 87x |

### Throughput: dense ASCII (4.7MB, 5 runs)

| | Time | MB/s | vs zt |
|---|---|---|---|
| **zt** | **64ms** | **73** | 1.0x |
| foot | 134ms | 35 | 2.1x |
| st | 174ms | 27 | 2.7x |
| xterm | 196ms | 24 | 3.1x |
| alacritty | 252ms | 19 | 3.9x |
| kitty | 354ms | 13 | 5.5x |
| ghostty | 704ms | 7 | 11x |

### Throughput: TrueColor (292KB, 5 runs)

| | Time | MB/s | vs zt |
|---|---|---|---|
| **zt** | **2ms** | **95** | 1.0x |
| xterm | 32ms | 6 | 16x |
| st | 52ms | 4 | 26x |
| foot | 60ms | 3 | 30x |
| alacritty | 140ms | 1 | 70x |
| kitty | 250ms | <1 | 125x |
| ghostty | 496ms | <1 | 248x |

### Throughput: Unicode/CJK (300KB, 5 runs)

| | Time | MB/s | vs zt |
|---|---|---|---|
| **zt** | **4ms** | **49** | 1.0x |
| xterm | 30ms | 7 | 7.5x |
| st | 58ms | 3 | 15x |
| foot | 62ms | 3 | 16x |
| alacritty | 144ms | 1 | 36x |
| kitty | 250ms | <1 | 63x |
| ghostty | 490ms | <1 | 123x |

### Idle memory (PSS)

| | RSS | PSS | vs zt |
|---|---|---|---|
| **zt** | **4.9 MB** | **2.2 MB** | 1.0x |
| xterm | 11 MB | 4.5 MB | 2.1x |
| foot | 24 MB | 11 MB | 5.0x |
| st | 29 MB | 15 MB | 6.8x |
| alacritty | 110 MB | 35 MB | 16x |
| kitty | 139 MB | 53 MB | 24x |
| ghostty | 221 MB | 96 MB | 44x |

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

# X11 with smaller PTY buffer (conserve memory on RPi)
zig build -Dbackend=x11 -Dpty_buf_kb=256 -Doptimize=ReleaseSmall

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
pub const pty_buf_size: u32 = ...;   // PTY read buffer in bytes (set via -Dpty_buf_kb, default 1024)
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
├── PTY reader (1MB buffer, drain loop)
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
| `src/vt.zig` | 1,621 | VT parser state machine + action executor, SIMD ASCII fast path, UTF-8 bulk path |
| `src/backend/x11.zig` | 950 | XCB window, double-buffered SHM, XKB + XIM (lazy init), ConfigureNotify coalescing |
| `src/term.zig` | 989 | Cell grid with row_map indirection, O(1) dirty flag, scroll, erase, BCE, TrueColor sparse maps |
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
| `CSI n B/e` | CUD/VPR | Cursor down |
| `CSI n C/a` | CUF/HPR | Cursor forward |
| `CSI n D` | CUB | Cursor back |
| `CSI n E` | CNL | Cursor next line |
| `CSI n F` | CPL | Cursor preceding line |
| `CSI n G/`` | CHA/HPA | Cursor horizontal absolute |
| `CSI n;m H/f` | CUP | Cursor position |
| `CSI n I` | CHT | Cursor forward tabulation |
| `CSI n J` | ED | Erase display (0: below, 1: above, 2/3: all) |
| `CSI n K` | EL | Erase line (0: right, 1: left, 2: all) |
| `CSI n L` | IL | Insert lines |
| `CSI n M` | DL | Delete lines |
| `CSI n P` | DCH | Delete characters |
| `CSI n X` | ECH | Erase characters |
| `CSI n @` | ICH | Insert characters |
| `CSI n Z` | CBT | Cursor backward tabulation |
| `CSI n b` | REP | Repeat preceding graphic character |
| `CSI n S` | SU | Scroll up |
| `CSI n T` | SD | Scroll down |
| `CSI n d` | VPA | Vertical position absolute |
| `CSI n g` | TBC | Tab clear (0: current, 3: all) |
| `CSI t;b r` | DECSTBM | Set scroll region (resets cursor to home) |
| `CSI s` | | Save cursor position |
| `CSI u` | | Restore cursor position |
| `CSI 5 n` | DSR | Device status report (OK) |
| `CSI 6 n` | DSR | Device status report (cursor position) |
| `CSI c` | DA1 | Device attributes (reports VT220) |
| `CSI > c` | DA2 | Secondary device attributes |
| `CSI ! p` | DECSTR | Soft terminal reset |
| `CSI Ps SP q` | DECSCUSR | Set cursor style |
| `CSI Ps t` | XTWINOPS | Window operations (silently accepted) |
| `CSI 4 h/l` | IRM | Insert/replace mode |
| `CSI 20 h/l` | LNM | Linefeed/newline mode |
| `CSI ... m` | SGR | Select graphic rendition (see below) |

All CSI private markers (`?`, `>`, `<`, `=`) are correctly parsed. Unknown private-marker sequences are silently ignored.

### SGR (Select Graphic Rendition)

| Code | Effect |
|------|--------|
| 0 | Reset all |
| 1 | Bold |
| 2 | Dim |
| 3 | Italic |
| 4 | Underline |
| 5, 6 | Blink |
| 7 | Reverse video |
| 8 | Invisible |
| 9 | Strikethrough |
| 22 | Normal intensity |
| 23 | Not italic |
| 24 | Not underline |
| 25 | Not blink |
| 27 | Not reverse |
| 28 | Not invisible |
| 29 | Not strikethrough |
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
| `?6` | DECOM | Origin mode |
| `?7` | DECAWM | Auto-wrap mode |
| `?25` | DECTCEM | Cursor visible |
| `?47` | | Alternate screen buffer |
| `?1047` | | Alternate screen buffer |
| `?1048` | | Save/restore cursor |
| `?1049` | | Alternate screen + save/restore cursor |
| `?2004` | | Bracketed paste mode |
| `?2026` | | Synchronized update |
| `?1000-1006` | | Mouse tracking modes (silently accepted) |
| `?1004` | | Focus events (silently accepted) |

### Escape sequences

| Sequence | Name | Description |
|----------|------|-------------|
| `ESC 7` | DECSC | Save cursor + attributes + charset |
| `ESC 8` | DECRC | Restore cursor + attributes + charset |
| `ESC D` | IND | Index (line feed, scrolls at bottom) |
| `ESC E` | NEL | Next line |
| `ESC H` | HTS | Horizontal tab stop |
| `ESC M` | RI | Reverse index |
| `ESC Z` | DECID | Identify terminal |
| `ESC c` | RIS | Full reset |
| `ESC =` | DECKPAM | Application keypad mode |
| `ESC >` | DECKPNM | Normal keypad mode |
| `ESC ( 0` | | G0 charset = DEC Special Graphics (line drawing) |
| `ESC ( B` | | G0 charset = US ASCII |
| `ESC # 8` | DECALN | Screen alignment test |

## Tested applications

The following applications have been verified working under Xvfb integration tests:

vim, nano, micro, less, bat, top, btop, man, git (log/diff/status), eza, tree, ripgrep, python3 REPL, fish (completions, history, Ctrl+C, Ctrl+L), Claude Code (Anthropic CLI)

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
