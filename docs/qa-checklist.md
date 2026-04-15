# zt Manual QA Checklist

Items that cannot be automated (require real display, hardware input, or visual inspection).
Check each box after manual verification. Each entry has brief steps and the expected outcome.

---

## Backend / Rendering

### B1 — X11 Basic Rendering
- [ ] Build with `-Dbackend=x11`, launch `zig-out-x11/bin/zt`.
- [ ] Run `ls --color=always` inside zt.
- **Expected**: Colors render correctly, no garbled glyphs, window opens without error.

### B2 — Wayland Basic Rendering
- [ ] Build with `-Dbackend=wayland`, launch `zig-out-wayland/bin/zt`.
- [ ] Run `ls --color=always` inside zt.
- **Expected**: Same as B1 under a Wayland compositor (e.g. sway, niri).

### B3 — fbdev TTY Rendering
- [ ] Switch to a bare TTY (`Ctrl+Alt+F2`, no X/Wayland running).
- [ ] Build with `-Dbackend=fbdev`, run `zig-out/bin/zt` from the TTY.
- [ ] Type a few commands, verify display.
- **Expected**: Framebuffer renders text correctly; evdev keyboard input works.

### B4 — Window Title via OSC 2
- [ ] Inside zt, run: `printf '\e]2;HelloZT\a'`
- **Expected**: Window title bar (X11 `_NET_WM_NAME` / Wayland `xdg-toplevel` title) updates to `HelloZT`.

### B5 — DEC Alt Screen (vim)
- [ ] Run `vim` inside zt, then quit with `:q`.
- **Expected**: On enter, alt screen activates (main screen content hidden). On quit, main screen restores exactly as before; no content corruption.

---

## Input

### I1 — Mouse Reporting (SGR 1006)
- [ ] Run: `printf '\e[?1006h\e[?1002h'` to enable SGR mouse + button tracking.
- [ ] Click and drag inside zt.
- **Expected**: `\e[<…M` / `\e[<…m` reports are printed to the terminal (visible as raw escape sequences since no app consumes them).

### I2 — Mouse in htop
- [ ] Launch `htop` inside zt.
- [ ] Click on a process row with the mouse.
- **Expected**: Row highlights on click; mouse scrolling works.

### I3 — Mouse in tmux
- [ ] Launch `tmux` inside zt, enable mouse with `set -g mouse on`.
- [ ] Click between panes, scroll in pane with mouse wheel.
- **Expected**: Pane focus changes on click; scroll works within each pane.

### I4 — IME (fcitx5 Mozc) — X11
- [ ] Ensure fcitx5 with Mozc is running, build zt with `-Dbackend=x11`.
- [ ] Launch zt, switch input to Mozc (Ctrl+Space or equivalent).
- [ ] Type Japanese (e.g. `nihongo`).
- **Expected**: Preedit text displayed inline; on Enter/Space the commit string appears; cursor follows correctly.

### I5 — PTY Signals: Ctrl-C
- [ ] Inside zt, run `sleep 100`, then press Ctrl-C.
- **Expected**: `sleep` is terminated immediately; shell prompt returns.

### I6 — PTY Signals: Ctrl-Z / bg / fg
- [ ] Run `sleep 100`, press Ctrl-Z to stop it.
- [ ] Run `bg` to resume in background, then `fg` to bring back.
- **Expected**: `sleep` stops, backgrounded, foregrounded without errors.

### I7 — PTY Signals: Shell Exit
- [ ] Type `exit` in the zt shell.
- **Expected**: zt window closes within ~250 ms of shell exit; no zombie process.

### I8 — Keyboard Layout (JP, if applicable)
- [ ] Build with `-Dkeymap=jp`, launch zt.
- [ ] Type keys that differ between US and JP layouts (e.g. `@`, `[`, `]`).
- **Expected**: Characters match JP keyboard physical labels.

---

## Clipboard

### C1 — Copy via Ctrl+Shift+C (X11)
- [ ] Select text inside zt with the mouse.
- [ ] Press Ctrl+Shift+C.
- [ ] Paste into another X11 app (e.g. `xdotool type --clearmodifiers $(xclip -o -sel clipboard)`).
- **Expected**: Selected text appears in clipboard; pastes correctly.

### C2 — Paste via Ctrl+Shift+V (X11)
- [ ] Copy some text in an external app.
- [ ] Focus zt, press Ctrl+Shift+V.
- **Expected**: Pasted text appears at cursor. If bracketed paste is enabled, it is wrapped in `\e[200~`/`\e[201~`.

### C3 — Clipboard Wayland
- [ ] Repeat C1 and C2 under Wayland using `wl-clipboard` (`wl-copy` / `wl-paste`).
- **Expected**: Same correct behavior via Wayland clipboard protocol.

---

## Display / TUI Apps

### D1 — vim TUI Correctness
- [ ] Run `vim` inside zt, open a file with syntax highlighting.
- **Expected**: Box-drawing characters, colors, and status line render correctly; no visual artifacts.

### D2 — btop Resource Monitor
- [ ] Run `btop` inside zt.
- **Expected**: All panels render; box-drawing, colors, and Unicode symbols correct; no garbling.

### D3 — Resize — Shell Sees Correct Dimensions
- [ ] Run `echo $COLUMNS $LINES` inside zt.
- [ ] Drag the window corner to resize.
- [ ] Run `echo $COLUMNS $LINES` again.
- **Expected**: Values change to match new window size; `$COLUMNS × $LINES` reflects current terminal dimensions.

### D4 — Resize — 1×1 Minimum
- [ ] Attempt to resize zt to the smallest possible window (drag corner as far as possible).
- **Expected**: zt does not crash; some minimum size is enforced gracefully.

### D5 — Resize in Alt Screen (vim)
- [ ] Open `vim`, then resize the zt window.
- **Expected**: vim redraws correctly to the new size; `:set lines?` and `:set columns?` return updated values.

---

## Stability

### S1 — Long-Running Heavy Output
- [ ] Run: `yes | head -1000000` inside zt.
- [ ] After it finishes, leave zt idle for 30 minutes.
- [ ] Check RSS: `ps -o rss= -p $(pgrep zt)` (record before and after).
- **Expected**: RSS stays below 200 MB; no leak between before and after idle.

### S2 — Repeated Resize Stability
- [ ] Rapidly resize the zt window by dragging the corner for 30 seconds.
- **Expected**: No crash, no visual corruption; zt remains responsive.

---

## Notes

- All tests assume zt built from current source (`zig build -Dbackend=<backend>`).
- fbdev tests require a real TTY or VT (no Xvfb).
- IME tests require the xcb-imdkit library and a running fcitx5 daemon.
- Clipboard Wayland tests require `wl-clipboard` package installed.
