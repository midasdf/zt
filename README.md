# ⚡ zt — the last terminal before the framebuffer

A minimal, fast terminal emulator written in Zig. Renders directly to the Linux framebuffer or X11 via shared memory. No GPU, no bloat, no dependencies (fbdev) or just XCB (X11).

Built for the [HackberryPi Zero](https://github.com/ZitaoTech/Hackberry-Pi_Zero) (RPi Zero 2W + 720x720 HyperPixel4), but runs on any Linux box.

## Features

- **Framebuffer direct rendering** — no X11/Wayland required (fbdev backend)
- **X11 backend** — XCB + SHM for use under window managers
- **Comptime backend selection** — zero runtime cost, only selected backend compiled
- **Comptime font embedding** — any BDF font baked into binary as blob
- **Damage tracking** — only dirty cells redrawn
- **xterm-256color + TrueColor** — full SGR, DEC modes, alternate screen
- **evdev direct input** (fbdev) / XCB key events (X11)
- **No libc** (fbdev backend) — pure `std.posix` syscalls
- **Single binary, statically linked** (fbdev) — just copy and run

## Numbers

| | fbdev | X11 |
|---|---|---|
| Binary size | ~50 KB + font | ~50 KB + font |
| Dependencies | none | libxcb, libxcb-shm, libxcb-xkb |
| Build time | < 1s | < 1s |

Binary size depends on embedded font. UFO + Nerd Fonts (59K glyphs) adds ~2.6 MB.

## Build

Requires Zig 0.15+ and a font blob (see [Font](#font) section).

```sh
# fbdev (default) — runs on bare console, no X11 needed
zig build -Doptimize=ReleaseSmall

# X11 — runs under i3/sway/etc
zig build -Dbackend=x11 -Doptimize=ReleaseSmall
```

Cross-compile for aarch64 (fbdev only, static):
```sh
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSmall
```

## Configuration

Edit `config.zig` and rebuild. st-style, no runtime config.

```zig
pub const backend: Backend = .fbdev;  // .fbdev or .x11
pub const default_fg: u8 = 7;        // white
pub const default_bg: u8 = 0;        // black
pub const font_width: u32 = 8;       // half-width cell
pub const font_height: u32 = 16;     // cell height
pub const shell = "/bin/sh";
```

## Font

zt embeds a pre-compiled font blob at compile time. You need to generate one before building. Recommended: [UFO](https://github.com/akahuku/ufo) (Japanese-optimized bitmap font, BDF).

### Quick start with UFO font

```sh
# Get UFO font
git clone --depth 1 https://github.com/akahuku/ufo.git /tmp/ufo

# Convert BDF to binary blob
python3 scripts/bdf2blob.py /tmp/ufo/build/ufo.bdf src/fonts/ufo.bin

# Update src/main.zig to point to blob
# const FontType = font_mod.FontBlob(@embedFile("fonts/ufo.bin"));

# Build
zig build -Doptimize=ReleaseSmall
```

### Using TTF fonts

```sh
# 1. Convert TTF to BDF
python3 scripts/ttf2bdf.py /path/to/font.ttf fonts/myfont.bdf 16

# 2. Convert BDF to binary blob
python3 scripts/bdf2blob.py fonts/myfont.bdf src/fonts/myfont.bin

# 3. Optional: merge blobs (e.g. base font + Nerd Fonts icons)
python3 scripts/merge_blobs.py src/fonts/base.bin src/fonts/icons.bin src/fonts/merged.bin
```

## Architecture

```
epoll event loop (single-threaded)
├── PTY reader → VT parser → Cell Grid (dirty tracking)
├── Input (evdev / XCB) → keymap → PTY writer
├── Renderer (dirty cells only → pixel buffer)
└── Backend (fbdev mmap / XCB SHM) → present
```

~3,800 lines of Zig across 9 source files.

## License

MIT
