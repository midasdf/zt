# ⚡ zt — the last terminal before the framebuffer

A minimal, fast terminal emulator written in Zig. Renders directly to the Linux framebuffer or X11 via shared memory. No GPU, no bloat, no dependencies (fbdev) or just XCB (X11).

Built for the [HackberryPi Zero](https://github.com/ZitaoTech/Hackberry-Pi_Zero) (RPi Zero 2W + 720x720 HyperPixel4), but runs on any Linux box.

## Features

- **Framebuffer direct rendering** — no X11/Wayland required (fbdev backend)
- **X11 backend** — XCB + SHM for use under window managers
- **Comptime backend selection** — zero runtime cost, only selected backend compiled
- **59,635 embedded glyphs** — UFO bitmap font + Nerd Fonts, baked into binary
- **Damage tracking** — only dirty cells redrawn
- **xterm-256color + TrueColor** — full SGR, DEC modes, alternate screen
- **evdev direct input** (fbdev) / XCB key events (X11)
- **No libc** (fbdev backend) — pure `std.posix` syscalls
- **Single binary, statically linked** (fbdev) — just copy and run

## Numbers

| | fbdev | X11 |
|---|---|---|
| Binary size | 2.7 MB | 2.7 MB |
| Dependencies | none | libxcb, libxcb-shm |
| Build time | < 1s | < 1s |

## Build

Requires Zig 0.15+.

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
pub const backend: Backend = .x11;   // .fbdev or .x11
pub const default_fg: u8 = 7;        // white
pub const default_bg: u8 = 0;        // black
pub const font_width: u32 = 8;       // half-width cell
pub const font_height: u32 = 16;     // cell height
pub const shell = "/usr/bin/fish";
```

## Font

zt embeds a pre-compiled font blob at compile time. Default: [UFO](https://github.com/akahuku/ufo) (Japanese-optimized bitmap font) merged with Nerd Fonts from PlemolJP.

To use a different font:

```sh
# 1. Convert TTF to BDF (for non-bitmap fonts)
python3 scripts/ttf2bdf.py /path/to/font.ttf fonts/myfont.bdf 16

# 2. Convert BDF to binary blob
python3 scripts/bdf2blob.py fonts/myfont.bdf src/fonts/myfont.bin

# 3. Optional: merge with another blob (e.g. for Nerd Fonts)
python3 scripts/merge_blobs.py src/fonts/myfont.bin src/fonts/nerdfonts.bin src/fonts/merged.bin

# 4. Update src/main.zig to point to new blob
# const FontType = font_mod.FontBlob(@embedFile("fonts/merged.bin"));

# 5. Rebuild
zig build -Doptimize=ReleaseSmall
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
