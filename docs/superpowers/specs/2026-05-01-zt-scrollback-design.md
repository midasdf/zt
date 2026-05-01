# zt scrollback buffer — design

- Date: 2026-05-01
- Status: design (not yet implemented)
- Targets: zt main branch (Zig 0.16+)
- Out of scope for v1: reflow on column resize, selection/copy of scrollback region (deferred to Phase 2)

## 1. Motivation

zt's `README.md` lists "**No scrollback buffer** — only the current viewport" as a known limitation. `src/main.zig:828` already carries a `// TODO: scrollback when implemented` marker on the wheel handler. Users hit this immediately on the HackberryPi (one-shot SSH session, no tmux) and on regular desktops.

The competitive constraints are:

- `Cell` is locked at 8 bytes — SIMD bulk paths (`fastCellFill`, `feedBulk`) depend on this. Comptime asserts in `src/term.zig:45-48` enforce it.
- Scroll is `O(1)` via `row_map` rotation in `src/term.zig:489-527`. Scrollback must NOT regress that fast path.
- Zero overhead when disabled: `-Dscrollback_lines=0` must compile out the entire feature so the existing render/scroll loop is unchanged.
- Must not break alt-screen behaviour for `less`/`vim`/`btop` (history pollution prevention).

## 2. Capacity & memory

| Setting | Default | Override |
|---------|---------|----------|
| `scrollback_lines` | 10000 | `-Dscrollback_lines=N` (0 disables) |

Memory at 80 cols, all dense parallel arrays:

```
per row = 80 * (8B Cell + 8B fg_rgb + 8B bg_rgb + 8B ul_rgb + 2B hyperlink) + ~4B per-row meta
        ≈ 80 * 34B + 4B ≈ 2.7 KB
10000 rows ≈ 27 MB
```

This is acceptable on HackberryPi Zero (512 MB). Sparse side arrays were considered and rejected for v1 — too much complexity for the saving on a system that already runs `cargo`. Stays open for a Phase 2 follow-up.

## 3. Architecture

```
                 ┌───────────────────────────────────────────────────┐
   PTY output → │ vt.zig                                              │
                 └───────────────────────────────────────────────────┘
                                       │
                                       ▼
                 ┌───────────────────────────────────────────────────┐
                 │ Term.scrollUp(n)                                   │
                 │   if (full_screen and !is_alt_screen and           │
                 │       scrollback_lines > 0)                        │
                 │     scrollback.pushRow(evicted_phys_row)           │
                 │   <existing row_map rotate + bceMemset>            │
                 └───────────────────────────────────────────────────┘
                                       │
                                       ▼
                 ┌───────────────────────────────────────────────────┐
                 │ Renderer (render.zig + main.zig render loop)       │
                 │   for y in 0..rows:                                │
                 │     if y < view_offset:                            │
                 │       cells = scrollback.rowAt(view_offset - 1 - y)│
                 │     else:                                          │
                 │       cells = main_grid.row(y - view_offset)       │
                 └───────────────────────────────────────────────────┘
                                       ▲
                                       │
                 ┌───────────────────────────────────────────────────┐
                 │ Input (main.zig + backend wheel events)            │
                 │   wheel ↑↓, Shift+PgUp/PgDn, Shift+Home/End        │
                 │   any key → view_offset = 0 (jump to bottom)       │
                 └───────────────────────────────────────────────────┘
```

Key invariants:

- Scrollback is owned by `Term` and lives across alt-screen switches. Alt screen does NOT push to scrollback.
- `view_offset == 0` ⇒ the renderer takes the existing fast path (no scrollback iteration), keeping zero overhead for the live-tail case.
- `view_offset > 0` is reset to 0 on:
  - any key input that produces PTY bytes
  - PTY-side cursor movement that would be unreachable otherwise — NOT implemented in v1, kept for follow-up
  - terminal resize whose new row count would invalidate `view_offset`

## 4. Data layout

Comptime gate via `build_options.scrollback_lines`. When `== 0`, the `Scrollback` type collapses to `void` and all `Term` fields/methods that depend on it disappear via `if (scrollback_lines > 0)` branches that are `comptime` known.

```zig
pub const Scrollback = struct {
    allocator: Allocator,
    cols: u32,
    capacity: u32, // = build_options.scrollback_lines
    head: u32,     // next slot to write
    count: u32,    // valid rows, <= capacity

    // Flat arrays sized capacity * cols (rotated by head)
    cells: []Cell,
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,
    ul_color_rgb: []?[3]u8,
    hyperlink_ids: []u16,

    // Per-row metadata
    used_cols: []u16,        // capacity, for resize truncate
    has_truecolor: []bool,   // capacity, render hint

    pub fn init(allocator: Allocator, cols: u32) !Scrollback;
    pub fn deinit(self: *Scrollback) void;
    pub fn pushRow(self: *Scrollback, src_cells: []const Cell, src_fg: []const ?[3]u8,
                   src_bg: []const ?[3]u8, src_ul: []const ?[3]u8,
                   src_hl: []const u16) void;
    pub fn rowAt(self: *const Scrollback, age: u32) ScrollbackView; // age 0 = newest
    pub fn resize(self: *Scrollback, new_cols: u32) !void;
};
```

Layout reuses Term's parallel-arrays-per-cell pattern (matches `cells`/`fg_rgb`/`bg_rgb`/`ul_color_rgb`/`hyperlink_ids` in `term.zig:143-181`). `head`/`count` give us the ring; `(head - 1 - age) mod capacity` is the physical slot for a given age.

`Term` gains (all three fields gated on `comptime scrollback_lines > 0` so size delta is exactly 0 when disabled):

```zig
scrollback: if (scrollback_lines > 0) Scrollback else void,
view_offset: if (scrollback_lines > 0) u32 else void, // 0 = live tail
push_to_scrollback_disabled: if (scrollback_lines > 0) bool else void,
```

`push_to_scrollback_disabled` mirrors `is_alt_screen` for normal flow but is kept as its own field so tests can suppress pushes deterministically without faking alt-screen state.

## 5. Push semantics (`Term.scrollUp` integration)

Push happens **only** when ALL of:

1. `comptime scrollback_lines > 0`
2. `!is_alt_screen`
3. The scroll is full-screen — `scroll_top == 0 and scroll_bottom + 1 == rows`. (Partial-region scrolls inside DECSTBM regions never push, matching st/xterm.)
4. `n >= 1` (already guarded by existing `if (n == 0) return`)

For each evicted physical row (1 row in the fast path, `n` rows in the general path) we:

```zig
const phys = self.row_map[top + s];     // already known by existing loop
const start = phys * self.cols;
self.scrollback.pushRow(
    self.cells[start..][0..self.cols],
    self.fg_rgb[start..][0..self.cols],
    self.bg_rgb[start..][0..self.cols],
    self.ul_color_rgb[start..][0..self.cols],
    self.hyperlink_ids[start..][0..self.cols],
);
```

`pushRow` itself does the per-row truecolor scan (one pass over `src_fg`/`src_bg`/`src_ul` looking for non-null) and stores the result into `has_truecolor[slot]`. Cheap (~80 pointer-sized loads per evicted row) and avoids inheriting screen-wide false positives.

The push runs BEFORE `bceMemset` clears the physical row (otherwise we'd push blanks). Order in current `scrollUp`:

- v1 fast-path edit: `pushRow(recycled_phys)` → existing copyForwards → existing bceMemset.
- v1 general-path edit: split into "for s in 0..shift: pushRow then bceMemset", then unchanged rotate.

Erase paths that are NOT scrolls do NOT push:

- `eraseDisplay 2` (`ED 2`) — clears viewport, scrollback preserved (matches st default).
- `eraseDisplay 3` (`ED 3`) — clears scrollback **only when `!is_alt_screen`**. xterm clears unconditionally; we choose the safer "do not touch scrollback from inside `less`/`vim`" behaviour for v1. Easy to relax later.
- `?1049` enter/exit — alt screen switch, no scrollback effect.

## 6. Render path

`render.zig` `renderCell` is unchanged. The orchestrating loop in `main.zig` (currently iterates `0..rows` reading from `term.cells` via `row_map`) gets a thin wrapper:

```zig
// Pseudocode
for (0..term.rows) |y| {
    const sb_age_opt: ?u32 = if (term.view_offset > y)
        term.view_offset - 1 - y
    else null;

    if (sb_age_opt) |age| {
        const view = term.scrollback.rowAt(age);
        renderRow(view.cells, view.fg_rgb, view.bg_rgb, view.ul_rgb, view.hl);
    } else {
        const live_y = y - term.view_offset;
        const phys = term.row_map[live_y];
        renderRow(/* existing physical addressing */);
    }
}
```

Performance:

- `view_offset == 0` short-circuits to the existing path. Zero overhead.
- `view_offset > 0` flips to the slow path. `all_dirty` is forced for the entire scrolled frame to keep dirty bookkeeping simple. Acceptable: scrollback browsing is interactive, not throughput-bound.
- Cursor render is suppressed when `view_offset > 0` (cursor lives in live grid; drawing it on top of scrollback is misleading). Selection box is also suppressed (v1 deferral).

## 7. Input bindings

Added to `main.zig` key/wheel dispatch. Bindings live in `config.zig` constants for end-user override.

| Action | Binding | Notes |
|--------|---------|-------|
| Scroll up 3 lines | wheel up | Only when `mouse_mode == .none` AND `!is_alt_screen`. |
| Scroll down 3 lines | wheel down | Same. |
| Scroll up 1 page | Shift+PageUp | Active in main screen only (alt screen ignores). |
| Scroll down 1 page | Shift+PageDown | Same. |
| Jump to scrollback top | Shift+Home | Saturates at `scrollback.count`. |
| Jump to live tail | Shift+End | `view_offset = 0`. |
| Jump to live tail (auto) | any keystroke that writes to PTY | Set `view_offset = 0` BEFORE the keystroke is processed. |

Wheel routing has three cases (replacing the current `main.zig:826-829` handler):

| `mouse_mode` | Screen | Wheel behaviour |
|--------------|--------|-----------------|
| `.none` | main | Scroll our scrollback. |
| `.none` | alt | Translate to arrow keys (existing behaviour, keeps `less`/`man` working). |
| non-`.none` | either | Forward as VT mouse event to the app (existing behaviour). |

In alt screen all scrollback-only bindings (Shift+PgUp/PgDn/Home/End) are inert — silently ignored. The buffer is paused there and showing "the old main" would surprise users.

## 8. Alt-screen rules

- On enter alt: `push_to_scrollback_disabled = true`, `view_offset = 0` (force live alt). Scrollback contents preserved.
- On leave alt: `push_to_scrollback_disabled = false`, `view_offset = 0`.
- During alt: `Term.scrollUp` skips the push step; existing alt-screen scrolling logic is untouched.
- `?1049` save/restore is unchanged.

## 9. Resize

v1 = **truncate / pad only**. No reflow.

On `Term.resize(new_cols, new_rows)`:

1. After main + alt buffers are reallocated (existing logic), call `scrollback.resize(new_cols)`:
   - Allocate a fresh flat blob sized `capacity * new_cols`.
   - For each existing row, copy `min(used_cols, new_cols)` cells; pad remainder with blanks.
   - Drop wide-char left half stranded at the new last column (matches existing `term.zig:633-644` boundary fix).
   - Free the old blob.
2. Clamp `view_offset = min(view_offset, scrollback.count)`. (Max meaningful offset is the row count of available scrollback — anything beyond would render phantom rows.)
3. Force `all_dirty = true` for the next frame.

Capacity (`scrollback_lines`) is comptime and never changes.

## 10. Selection / copy

v1: selection clamped to viewport. Dragging into the scrollback area is allowed but the selection's `y` is clamped to `0`. Copy operations apply to viewport-only.

Phase 2 (separate spec): extend `Selection` to use signed `y` where negative `y` indexes scrollback. This requires touching every `selection.contains` call site in `term.zig` and the render path; intentionally deferred to keep v1 blast radius small.

## 11. Build option

Append to `build.zig` next to the existing `pty_buf_kb` block:

```zig
const scrollback_lines_opt = b.option(u32, "scrollback_lines",
    "Number of scrollback rows (0 disables, default 10000)") orelse 10000;
options.addOption(u32, "scrollback_lines", scrollback_lines_opt);
```

`config.zig` gains a corresponding `pub const scrollback_lines = build_options.scrollback_lines;` alias and the input binding constants:

```zig
pub const scrollback_wheel_lines: u32 = 3;
```

## 12. Tests

Unit tests added to `src/term.zig`:

1. `scrollback: pushRow stores evicted row contents` — write `'A'`/`'B'`/`'C'` to rows 0/1/2, scroll, check `scrollback.rowAt(0..2).char` matches.
2. `scrollback: capacity overflow drops oldest` — push capacity+5 rows, verify oldest 5 are gone, newest survive.
3. `scrollback: alt screen suppresses push` — switch to alt, scroll, switch back, scrollback unchanged.
4. `scrollback: ED 3 clears scrollback` — push some rows, fire `eraseDisplay(3)`, scrollback empty.
5. `scrollback: partial-region scroll does NOT push` — set `scroll_bottom = rows - 2`, scrollUp(1), scrollback unchanged.
6. `scrollback: resize truncates rows wider than new cols` — push wide row, shrink, verify clipped + wide-char boundary fix.
7. `scrollback: resize pads rows narrower than new cols` — push narrow row, grow, verify pad with blanks.
8. `scrollback: view_offset clamps on resize` — set offset, resize smaller scrollback context, verify clamp.
9. Comptime size test: a snapshot test asserts `@sizeOf(Term)` with `scrollback_lines = 0` equals a fixed expected value (recorded once with all scrollback fields gated out). Updating the value requires explicit consent in a follow-up commit. Guards against accidental field bloat creeping into the disabled path.

Manual / smoke tests added to `docs/qa-checklist.md`:

- `seq 1 5000 | cat` then wheel-up to top, wheel-down to bottom (X11/Wayland/fbdev).
- `less /etc/services` — wheel must NOT scroll local scrollback (alt screen). Quit `less` — scrollback intact.
- `vim` — same as `less`.
- `btop` — `mouse_mode != .none`, wheel goes to app, Shift+PgUp scrolls scrollback.
- Resize (mod-key drag) while scrolled to middle of scrollback → no crash, view stays sane.
- Cross-compile aarch64 with `-Dscrollback_lines=0` and `=2000` — both link, binary size delta < 1 KB for `=0`.

## 13. Implementation phases

1. **Phase 1**: `Scrollback` type + `Term.pushRow` integration in `scrollUp` + alt-screen gating + tests 1-5.
2. **Phase 2**: render path branching (`view_offset`) + input bindings (wheel + Shift+PgUp/Dn/Home/End) + tests 8.
3. **Phase 3**: resize handling + tests 6-7 + comptime gate + test 9.
4. **Phase 4**: manual QA pass + docs update (README limitations entry, build flag).

Each phase is a separate commit / PR-ready unit. After Phase 1 the buffer is live but invisible (good intermediate verifier — the unit tests prove correctness before any rendering risk).

## 14. Non-goals (explicit deferrals)

- Reflow on column resize.
- Selection / copy of scrollback rows.
- Search inside scrollback (`Ctrl+R` style).
- Per-row sparse side-array compression.
- Disk-backed history (st-scrollback-style).
- Mouse-button drag-scroll on the scroll bar (no scroll bar exists).
