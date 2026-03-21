# zt — minimal terminal emulator in Zig

[![Zig](https://img.shields.io/badge/Zig-0.15+-f7a41d?logo=zig&logoColor=white)](https://ziglang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Linux](https://img.shields.io/badge/Platform-Linux-yellow?logo=linux&logoColor=white)](https://kernel.org)

A fast, minimal terminal emulator written in Zig. Renders directly to the Linux framebuffer or X11 via shared memory. No GPU required.

Built for the [HackberryPi Zero](https://github.com/ZitaoTech/Hackberry-Pi_Zero) (RPi Zero 2W + 720x720 HyperPixel4), but runs on any Linux system.

## Features

- **Dual backend** — framebuffer direct rendering (no X11/Wayland) or XCB + SHM under X11
- **Comptime everything** — backend, font, palette all resolved at compile time. Zero runtime cost for unused code paths
- **Damage tracking** — per-cell dirty bitmap, row-level skip, dirty region present (X11 sends only changed rows)
- **xterm-256color + 24-bit TrueColor** — full SGR attributes (bold, italic, underline, reverse, dim), DEC modes, alternate screen
- **CJK wide character support** — correct double-width rendering for Japanese, Chinese, Korean
- **59,635 glyphs** — UFO bitmap font + Nerd Fonts icons, embedded as binary blob
- **PTY drain loop** — reads all available data before rendering, reducing frame count during bulk output
- **Write buffering** — PTY writes buffered on backpressure with EPOLLOUT retry
- **No libc** (fbdev) — pure `std.posix` syscalls, single static binary
- **74 unit tests** across 7 modules

## Numbers

|  | fbdev | X11 |
|---|---|---|
| Code size | ~56 KB | ~61 KB |
| Binary (with 59K-glyph font) | 2.7 MB | 2.7 MB |
| Runtime dependencies | none | libxcb, libxcb-shm, libxcb-xkb |
| Build time | < 1s | < 1s |
| Source | 4,312 lines across 11 files |  |

## Build

Requires Zig 0.15+.

```sh
# fbdev (default) — runs on bare Linux console
zig build -Doptimize=ReleaseSmall

# X11 — runs under window managers
zig build -Dbackend=x11 -Doptimize=ReleaseSmall

# Cross-compile for aarch64 (fbdev, static binary)
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall

# Run tests
zig build test
```

## Configuration

Edit `config.zig` and rebuild — [st](https://st.suckless.org/)-style, no runtime config files.

```zig
pub const backend: Backend = .fbdev;  // .fbdev or .x11
pub const default_fg: u8 = 7;        // white
pub const default_bg: u8 = 0;        // black
pub const font_width: u32 = 8;       // cell width (half-width)
pub const font_height: u32 = 16;     // cell height
pub const shell = "/bin/fish";        // login shell
```

## Font

zt embeds a pre-compiled binary font blob at compile time via `@embedFile`. Any BDF font can be used.

### Using UFO (recommended for Japanese)

[UFO](https://github.com/akahuku/ufo) is a bitmap font optimized for Japanese text.

```sh
git clone --depth 1 https://github.com/akahuku/ufo.git /tmp/ufo
python3 scripts/bdf2blob.py /tmp/ufo/build/ufo.bdf src/fonts/ufo.bin
```

### Using TTF fonts

```sh
# Convert TTF to BDF at desired pixel size
python3 scripts/ttf2bdf.py /path/to/font.ttf fonts/myfont.bdf 16

# Convert BDF to binary blob
python3 scripts/bdf2blob.py fonts/myfont.bdf src/fonts/myfont.bin

# Merge multiple blobs (e.g. base font + Nerd Fonts icons)
python3 scripts/merge_blobs.py src/fonts/base.bin src/fonts/icons.bin src/fonts/merged.bin
```

Update `src/main.zig` to point to the desired blob:
```zig
const FontType = font_mod.FontBlob(@embedFile("fonts/your-font.bin"));
```

### Font blob format

8-byte header + glyph table + bitmap data. Each glyph entry is 16 bytes: codepoint (u32), width (u16), height (u16), bitmap offset (u32), bitmap length (u16), padding (u16). Glyphs sorted by codepoint for binary search. ASCII 0-127 are additionally cached at comptime for O(1) lookup.

## Architecture

```
epoll event loop (single-threaded)
├── PTY reader (64KB buffer, drain loop)
│   └── VT parser (byte-by-byte state machine)
│       └── Action executor → Cell grid mutations
├── Input handler
│   ├── evdev (fbdev) — raw keyboard events
│   └── XCB key events (X11) — with modifier tracking
├── Renderer
│   ├── hasDirty() bitmask check → skip if nothing changed
│   ├── isRowDirty() → skip clean rows
│   └── Per-cell: glyph lookup → pixel composition
├── Backend
│   ├── fbdev: shadow buffer → dirty row memcpy to /dev/fb0 mmap
│   └── X11: SHM buffer → dirty region xcb_shm_put_image
├── Signal handling (signalfd: SIGCHLD, SIGTERM, SIGINT, SIGHUP)
├── VT switching (fbdev: SIGUSR1/2 for console switch)
├── Cursor blink (timerfd, 500ms interval)
└── Write buffer (4KB, EPOLLOUT-driven retry on backpressure)
```

### Source files

| File | Lines | Purpose |
|------|-------|---------|
| `src/vt.zig` | 1,008 | VT parser state machine + action executor (CSI, SGR, DEC modes, OSC) |
| `src/term.zig` | 809 | Cell grid, dirty bitmap, scroll, erase, TrueColor sparse maps |
| `src/input.zig` | 488 | US QWERTY keymap, evdev code translation, modifier handling |
| `src/main.zig` | 475 | Event loop, signal/timer setup, PTY drain, write buffering, render orchestration |
| `src/backend/x11.zig` | 373 | XCB window, SHM setup/resize, dirty region present, event polling |
| `src/font.zig` | 318 | BDF parser (comptime), binary blob loader, ASCII glyph cache |
| `src/backend/fbdev.zig` | 316 | Framebuffer mmap, shadow buffer, evdev keyboard scan, VT switching |
| `src/render.zig` | 262 | Pixel rendering (BGRA32/RGB565/RGB24), palette, glyph blit, cursor |
| `src/pty.zig` | 188 | PTY spawn, nonblocking I/O, resize (TIOCSWINSZ) |
| `config.zig` | 16 | Compile-time configuration |
| `build.zig` | 59 | Build system with backend selection |

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
| `CSI n;m H` | CUP | Cursor position |
| `CSI n J` | ED | Erase display (0: below, 1: above, 2/3: all) |
| `CSI n K` | EL | Erase line (0: right, 1: left, 2: all) |
| `CSI n L` | IL | Insert lines |
| `CSI n M` | DL | Delete lines |
| `CSI n P` | DCH | Delete characters |
| `CSI n X` | ECH | Erase characters |
| `CSI n @` | ICH | Insert characters |
| `CSI n S` | SU | Scroll up |
| `CSI n T` | SD | Scroll down |
| `CSI n d` | VPA | Vertical position absolute |
| `CSI t;b r` | DECSTBM | Set scroll region |
| `CSI s` | | Save cursor position |
| `CSI u` | | Restore cursor position |
| `CSI 6 n` | DSR | Device status report (cursor position) |
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

vim, nano, micro, less, bat, top, btop, man, git (log/diff/status), eza, tree, ripgrep, python3 REPL, fish (completions, history, Ctrl+C, Ctrl+L)

## Limitations

- No scrollback buffer — only the current viewport is kept
- No clipboard (OSC 52 parsed but not acted on)
- No mouse support
- US QWERTY keymap hardcoded (evdev codes mapped at compile time)
- No font fallback chain — single embedded font
- No ligatures
- No sixel/image protocol support

## License

MIT
