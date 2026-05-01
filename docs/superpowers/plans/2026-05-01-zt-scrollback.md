# zt Scrollback Buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fixed-capacity scrollback buffer to zt's main screen, browseable with mouse wheel and Shift+PgUp/PgDn/Home/End, with `-Dscrollback_lines=0` zero-overhead opt-out.

**Architecture:** New `Scrollback` type owned by `Term`. `scrollUp` pushes evicted full-screen rows into a rotated ring of flat parallel arrays (cells + fg_rgb + bg_rgb + ul_color_rgb + hyperlink_ids), matching the existing per-cell side-array pattern. Render loop in `main.zig` branches on `term.view_offset` to read scrollback rows when scrolled back. Alt screen suppresses pushes. Resize uses truncate/pad (no reflow in v1).

**Tech Stack:** Zig 0.16+, existing zt build system (`build.zig` options), unit tests inline in `term.zig` (existing convention).

**Spec:** `docs/superpowers/specs/2026-05-01-zt-scrollback-design.md`

**Branch:** Work on `feat/scrollback` branched from `main`. Each task = one commit. Final merge after manual QA.

---

## File Structure

| File | Role | Phase |
|------|------|-------|
| `build.zig` | Add `-Dscrollback_lines` option, expose to `build_options` | 1 |
| `config.zig` | Re-export `scrollback_lines` + add `scrollback_wheel_lines` constant | 1 |
| `src/scrollback.zig` (NEW) | `Scrollback` type, `pushRow`, `rowAt`, `resize`, `clear` | 1 |
| `src/term.zig` | Hold `scrollback`/`view_offset`/push gates; integrate into `scrollUp`, `eraseDisplay`, `switchScreen`, `resize` | 1, 2, 3 |
| `src/main.zig` | Render loop branching on `view_offset`, wheel routing, Shift+key bindings, auto-jump-to-bottom | 2 |
| `src/input.zig` | (no change in v1; handled at main.zig dispatch level) | — |
| `docs/qa-checklist.md` | Add scrollback manual test cases | 4 |
| `README.md` | Remove the "No scrollback buffer" limitation, add `-Dscrollback_lines` to build options | 4 |

`src/scrollback.zig` is a NEW file. It is `pub usingnamespace` imported by `term.zig` (or, equivalently, `term.zig` does `const scrollback = @import("scrollback.zig");`). Tests for `Scrollback` live inside `scrollback.zig`. Tests that verify `Term`-level behaviour (push integration, alt-screen gating, ED 3, resize wiring) live inside `term.zig` next to existing `scrollUp` tests.

---

## Phase 1 — Buffer + push integration (no UI yet)

After Phase 1, scrollback is being populated correctly but not yet visible. Phase 1 is verifiable purely via unit tests.

### Task 1: Add `-Dscrollback_lines` build option

**Files:**
- Modify: `build.zig`
- Modify: `config.zig`

- [ ] **Step 1: Read current `build.zig` option block**

Open `build.zig` and locate the `pty_buf_kb_opt` block near line 43-52. The new option will be appended in the same style.

- [ ] **Step 2: Add the option declaration in `build.zig`**

Insert after the `pty_buf_kb_opt` line:

```zig
    const scrollback_lines_opt = b.option(u32, "scrollback_lines",
        "Scrollback rows for main screen (0 disables, default 10000)") orelse 10000;
    options.addOption(u32, "scrollback_lines", scrollback_lines_opt);
```

- [ ] **Step 3: Add `scrollback_lines` to `config.zig`**

Open `config.zig`. Locate the existing `pub const pty_buf_kb` line. Add immediately after:

```zig
pub const scrollback_lines: u32 = build_options.scrollback_lines;
pub const scrollback_wheel_lines: u32 = 3;
```

(`build_options` is the comptime-imported options module — already used by `pty_buf_kb`. Match the import line if present; otherwise add `const build_options = @import("build_options");` at the top of the file.)

- [ ] **Step 4: Verify build still passes for default and 0**

```sh
cd /home/midasdf/zt
zig build -Dbackend=x11
zig build -Dbackend=x11 -Dscrollback_lines=0
zig build -Dbackend=x11 -Dscrollback_lines=2000
```

Expected: All three succeed with no warnings.

- [ ] **Step 5: Commit**

```sh
git checkout -b feat/scrollback
git add build.zig config.zig
git commit -m "$(cat <<'EOF'
build(scrollback): add -Dscrollback_lines option

Adds the build-time configuration knob for the upcoming scrollback
buffer. Default 10000, set to 0 to compile out the feature entirely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Create `Scrollback` type skeleton

**Files:**
- Create: `src/scrollback.zig`
- Test: `src/scrollback.zig` (inline)

- [ ] **Step 1: Write the failing test**

Create `/home/midasdf/zt/src/scrollback.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const term_mod = @import("term.zig");
const Cell = term_mod.Cell;

pub const ScrollbackView = struct {
    cells: []const Cell,
    fg_rgb: []const ?[3]u8,
    bg_rgb: []const ?[3]u8,
    ul_color_rgb: []const ?[3]u8,
    hyperlink_ids: []const u16,
    used_cols: u16,
    has_truecolor: bool,
};

pub const Scrollback = struct {
    allocator: Allocator,
    cols: u32,
    capacity: u32,
    head: u32 = 0,
    count: u32 = 0,

    cells: []Cell,
    fg_rgb: []?[3]u8,
    bg_rgb: []?[3]u8,
    ul_color_rgb: []?[3]u8,
    hyperlink_ids: []u16,
    used_cols: []u16,
    has_truecolor: []bool,

    const Self = @This();

    pub fn init(allocator: Allocator, capacity: u32, cols: u32) !Self {
        const total: usize = @as(usize, capacity) * @as(usize, cols);
        const cells = try allocator.alloc(Cell, total);
        errdefer allocator.free(cells);
        const fg = try allocator.alloc(?[3]u8, total);
        errdefer allocator.free(fg);
        const bg = try allocator.alloc(?[3]u8, total);
        errdefer allocator.free(bg);
        const ul = try allocator.alloc(?[3]u8, total);
        errdefer allocator.free(ul);
        const hl = try allocator.alloc(u16, total);
        errdefer allocator.free(hl);
        const uc = try allocator.alloc(u16, capacity);
        errdefer allocator.free(uc);
        const tc = try allocator.alloc(bool, capacity);

        @memset(cells, Cell{});
        @memset(fg, null);
        @memset(bg, null);
        @memset(ul, null);
        @memset(hl, 0);
        @memset(uc, 0);
        @memset(tc, false);

        return .{
            .allocator = allocator,
            .cols = cols,
            .capacity = capacity,
            .cells = cells,
            .fg_rgb = fg,
            .bg_rgb = bg,
            .ul_color_rgb = ul,
            .hyperlink_ids = hl,
            .used_cols = uc,
            .has_truecolor = tc,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        self.allocator.free(self.ul_color_rgb);
        self.allocator.free(self.hyperlink_ids);
        self.allocator.free(self.used_cols);
        self.allocator.free(self.has_truecolor);
    }

    pub fn clear(self: *Self) void {
        self.head = 0;
        self.count = 0;
    }
};

test "Scrollback: init+deinit round-trip" {
    var sb = try Scrollback.init(testing.allocator, 100, 80);
    defer sb.deinit();
    try testing.expectEqual(@as(u32, 100), sb.capacity);
    try testing.expectEqual(@as(u32, 80), sb.cols);
    try testing.expectEqual(@as(u32, 0), sb.count);
    try testing.expectEqual(@as(u32, 0), sb.head);
}

test "Scrollback: clear resets head and count" {
    var sb = try Scrollback.init(testing.allocator, 10, 5);
    defer sb.deinit();
    sb.head = 3;
    sb.count = 5;
    sb.clear();
    try testing.expectEqual(@as(u32, 0), sb.head);
    try testing.expectEqual(@as(u32, 0), sb.count);
}
```

- [ ] **Step 2: Wire the new file into the test set in `main.zig`**

Open `/home/midasdf/zt/src/main.zig` and find the bottom `test {}` block (line 1580+):

```zig
test {
    _ = @import("font.zig");
    _ = @import("term.zig");
    _ = @import("vt.zig");
    _ = @import("pty.zig");
    _ = @import("input.zig");
    _ = @import("render.zig");
}
```

Add `_ = @import("scrollback.zig");` to the list.

- [ ] **Step 3: Run tests; expect them to pass**

```sh
cd /home/midasdf/zt
zig build test 2>&1 | tail -20
```

Expected: All tests pass. Both `Scrollback: init+deinit round-trip` and `Scrollback: clear resets head and count` show as passing.

- [ ] **Step 4: Commit**

```sh
git add src/scrollback.zig src/main.zig
git commit -m "$(cat <<'EOF'
feat(scrollback): add Scrollback type with init/deinit/clear

Skeleton type holding the parallel arrays for cells + fg_rgb + bg_rgb +
ul_color_rgb + hyperlink_ids + per-row used_cols + has_truecolor.
pushRow/rowAt come in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Implement `pushRow` and `rowAt`

**Files:**
- Modify: `src/scrollback.zig`

- [ ] **Step 1: Write the failing tests**

Append to `/home/midasdf/zt/src/scrollback.zig` (after existing tests):

```zig
test "Scrollback: pushRow stores cells and rowAt(0) returns newest" {
    var sb = try Scrollback.init(testing.allocator, 10, 5);
    defer sb.deinit();

    const cells = [_]Cell{
        .{ .char = 'A' }, .{ .char = 'B' }, .{ .char = 'C' },
        .{ .char = 'D' }, .{ .char = 'E' },
    };
    const fg = [_]?[3]u8{null} ** 5;
    const bg = [_]?[3]u8{null} ** 5;
    const ul = [_]?[3]u8{null} ** 5;
    const hl = [_]u16{0} ** 5;

    sb.pushRow(&cells, &fg, &bg, &ul, &hl);

    try testing.expectEqual(@as(u32, 1), sb.count);
    const view = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), view.cells[0].char);
    try testing.expectEqual(@as(u21, 'E'), view.cells[4].char);
    try testing.expectEqual(@as(u16, 5), view.used_cols);
    try testing.expectEqual(false, view.has_truecolor);
}

test "Scrollback: pushRow detects truecolor in fg/bg/ul" {
    var sb = try Scrollback.init(testing.allocator, 10, 3);
    defer sb.deinit();

    const cells = [_]Cell{ .{ .char = 'X' }, .{ .char = 'Y' }, .{ .char = 'Z' } };
    const empty_rgb = [_]?[3]u8{null} ** 3;
    var fg = [_]?[3]u8{null} ** 3;
    fg[1] = .{ 200, 100, 50 };
    const empty_hl = [_]u16{0} ** 3;

    sb.pushRow(&cells, &fg, &empty_rgb, &empty_rgb, &empty_hl);
    try testing.expectEqual(true, sb.rowAt(0).has_truecolor);

    sb.clear();
    var bg = [_]?[3]u8{null} ** 3;
    bg[2] = .{ 0, 0, 1 };
    sb.pushRow(&cells, &empty_rgb, &bg, &empty_rgb, &empty_hl);
    try testing.expectEqual(true, sb.rowAt(0).has_truecolor);

    sb.clear();
    var u = [_]?[3]u8{null} ** 3;
    u[0] = .{ 9, 9, 9 };
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &u, &empty_hl);
    try testing.expectEqual(true, sb.rowAt(0).has_truecolor);
}

test "Scrollback: capacity overflow drops oldest" {
    var sb = try Scrollback.init(testing.allocator, 3, 1);
    defer sb.deinit();

    const empty_rgb = [_]?[3]u8{null};
    const empty_hl = [_]u16{0};
    inline for (0..5) |i| {
        const cells = [_]Cell{.{ .char = 'A' + i }};
        sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl);
    }

    try testing.expectEqual(@as(u32, 3), sb.count);
    // Newest = 'E', then 'D', then 'C'. 'A' and 'B' fell off.
    try testing.expectEqual(@as(u21, 'E'), sb.rowAt(0).cells[0].char);
    try testing.expectEqual(@as(u21, 'D'), sb.rowAt(1).cells[0].char);
    try testing.expectEqual(@as(u21, 'C'), sb.rowAt(2).cells[0].char);
}

test "Scrollback: rowAt clamps age to count-1" {
    var sb = try Scrollback.init(testing.allocator, 10, 1);
    defer sb.deinit();
    const cells = [_]Cell{.{ .char = 'A' }};
    const empty_rgb = [_]?[3]u8{null};
    const empty_hl = [_]u16{0};
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl);

    // Asking for an age beyond count returns the oldest available row
    // rather than panicking — a defensive contract for callers.
    const view = sb.rowAt(99);
    try testing.expectEqual(@as(u21, 'A'), view.cells[0].char);
}
```

- [ ] **Step 2: Run tests, expect compile error (`pushRow`/`rowAt` undefined)**

```sh
cd /home/midasdf/zt
zig build test 2>&1 | tail -10
```

Expected: Build fails with errors about missing `pushRow` and `rowAt` decls on `Scrollback`.

- [ ] **Step 3: Implement `pushRow` and `rowAt`**

Add inside the `Scrollback` struct, between `clear` and the closing `};`:

```zig
    pub fn pushRow(
        self: *Self,
        src_cells: []const Cell,
        src_fg: []const ?[3]u8,
        src_bg: []const ?[3]u8,
        src_ul: []const ?[3]u8,
        src_hl: []const u16,
    ) void {
        std.debug.assert(src_cells.len == self.cols);
        std.debug.assert(src_fg.len == self.cols);
        std.debug.assert(src_bg.len == self.cols);
        std.debug.assert(src_ul.len == self.cols);
        std.debug.assert(src_hl.len == self.cols);

        const slot = self.head;
        const start: usize = @as(usize, slot) * @as(usize, self.cols);
        @memcpy(self.cells[start .. start + self.cols], src_cells);
        @memcpy(self.fg_rgb[start .. start + self.cols], src_fg);
        @memcpy(self.bg_rgb[start .. start + self.cols], src_bg);
        @memcpy(self.ul_color_rgb[start .. start + self.cols], src_ul);
        @memcpy(self.hyperlink_ids[start .. start + self.cols], src_hl);

        // Per-row truecolor scan
        var has_tc = false;
        for (src_fg) |v| if (v != null) { has_tc = true; break; };
        if (!has_tc) for (src_bg) |v| if (v != null) { has_tc = true; break; };
        if (!has_tc) for (src_ul) |v| if (v != null) { has_tc = true; break; };
        self.has_truecolor[slot] = has_tc;

        // Compute used_cols: trim trailing default blanks for resize accuracy
        var uc: u16 = @intCast(self.cols);
        while (uc > 0) {
            const i = uc - 1;
            const c = src_cells[i];
            if (c.char != ' ' or src_fg[i] != null or src_bg[i] != null or
                src_ul[i] != null or src_hl[i] != 0) break;
            uc -= 1;
        }
        self.used_cols[slot] = uc;

        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
    }

    pub fn rowAt(self: *const Self, age: u32) ScrollbackView {
        std.debug.assert(self.count > 0);
        const a = if (age >= self.count) self.count - 1 else age;
        // newest is at (head - 1) mod capacity, age 0
        // age k is at (head - 1 - k) mod capacity
        const slot: u32 = @intCast(@mod(@as(i64, self.head) - 1 - @as(i64, a),
                                        @as(i64, self.capacity)));
        const start: usize = @as(usize, slot) * @as(usize, self.cols);
        const end = start + self.cols;
        return .{
            .cells = self.cells[start..end],
            .fg_rgb = self.fg_rgb[start..end],
            .bg_rgb = self.bg_rgb[start..end],
            .ul_color_rgb = self.ul_color_rgb[start..end],
            .hyperlink_ids = self.hyperlink_ids[start..end],
            .used_cols = self.used_cols[slot],
            .has_truecolor = self.has_truecolor[slot],
        };
    }
```

- [ ] **Step 4: Run tests, expect all to pass**

```sh
cd /home/midasdf/zt
zig build test 2>&1 | tail -10
```

Expected: All four new tests pass. No regressions.

- [ ] **Step 5: Commit**

```sh
git add src/scrollback.zig
git commit -m "$(cat <<'EOF'
feat(scrollback): implement pushRow + rowAt with capacity rollover

pushRow copies a full row into the ring slot, scans for truecolor
overrides, and trims trailing default blanks to record used_cols for
later resize handling. rowAt(age) returns a const view; age 0 is the
newest pushed row. Capacity overflow silently drops the oldest row.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add `scrollback` field to `Term` and wire init/deinit

**Files:**
- Modify: `src/term.zig`

- [ ] **Step 1: Add the import + comptime alias near the top of `term.zig`**

Open `/home/midasdf/zt/src/term.zig`. After the existing imports (line 1-3), add:

```zig
const config = @import("config.zig");
const scrollback_mod = @import("scrollback.zig");
const Scrollback = scrollback_mod.Scrollback;
const ScrollbackView = scrollback_mod.ScrollbackView;
```

- [ ] **Step 2: Add fields to the `Term` struct**

Locate the `Term` struct (line 136). Find a clean insertion point near the existing alt-screen fields (line 157, `is_alt_screen: bool = false,`). Add immediately after:

```zig
    // Scrollback (main screen only). Comptime-gated: when scrollback_lines == 0
    // these fields collapse to zero-sized `void` and pay no memory cost.
    scrollback: if (config.scrollback_lines > 0) Scrollback else void =
        if (config.scrollback_lines > 0) undefined else {},
    view_offset: if (config.scrollback_lines > 0) u32 else void =
        if (config.scrollback_lines > 0) 0 else {},
```

- [ ] **Step 3: Wire init in `Term.init`**

Locate `pub fn init` (line 264) and the existing `return` statement that sets struct fields. After `.alt_saved_cursor = ...` (or wherever the last field is initialised), add — INSIDE the same returned struct literal:

```zig
            .scrollback = if (config.scrollback_lines > 0)
                try Scrollback.init(allocator, config.scrollback_lines, cols)
            else {},
            .view_offset = if (config.scrollback_lines > 0) @as(u32, 0) else {},
```

The `try` will trigger an OOM rollback. Existing allocations earlier in `init` already use `errdefer` — verify the new `try Scrollback.init` is the LAST allocation in the function so prior errdefers run on its failure. If not, add an `errdefer` for each prior allocation (or refactor: alloc scrollback FIRST and errdefer it, keeping consistent with existing pattern). Inspect `init` and adjust to the existing pattern.

- [ ] **Step 4: Wire deinit in `Term.deinit`**

Locate `pub fn deinit` (line 305). Add after the existing `self.dirty.deinit();` line and before the alt-screen deallocations:

```zig
    if (config.scrollback_lines > 0) self.scrollback.deinit();
```

- [ ] **Step 5: Write a test that verifies `Term` allocates and frees the scrollback**

Append to `/home/midasdf/zt/src/term.zig` near the existing init test (around line 1358):

```zig
test "Term: scrollback allocated when scrollback_lines > 0" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 10, 5);
    defer term.deinit();
    // Just deinit cleanly — leak detector in testing.allocator catches mismatches.
    try testing.expectEqual(@as(u32, config.scrollback_lines), term.scrollback.capacity);
    try testing.expectEqual(@as(u32, 10), term.scrollback.cols);
    try testing.expectEqual(@as(u32, 0), term.scrollback.count);
    try testing.expectEqual(@as(u32, 0), term.view_offset);
}
```

- [ ] **Step 6: Run tests, expect pass**

```sh
cd /home/midasdf/zt
zig build test 2>&1 | tail -10
```

Expected: New test passes; all existing tests still pass; no leaks.

- [ ] **Step 7: Commit**

```sh
git add src/term.zig
git commit -m "$(cat <<'EOF'
feat(term): own a Scrollback instance behind a comptime gate

Term gains scrollback / view_offset / push_to_scrollback_disabled,
allocated in init and freed in deinit. With -Dscrollback_lines=0 all
three fields collapse to void (zero-sized) and the alloc is skipped.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire `pushRow` into `Term.scrollUp`

**Files:**
- Modify: `src/term.zig` (`scrollUp` function, line 489-527)

- [ ] **Step 1: Write the failing test**

Append to `term.zig` near the existing `Term: scrollUp moves rows via row_map` test:

```zig
test "Term: scrollUp(1) full-screen pushes evicted row to scrollback" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 5, 4);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(1, 0, .{ .char = 'B' });
    term.setCell(2, 0, .{ .char = 'C' });
    term.scroll_bottom = 3;

    term.scrollUp(1);

    try testing.expectEqual(@as(u32, 1), term.scrollback.count);
    const v = term.scrollback.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'B'), v.cells[1].char);
    try testing.expectEqual(@as(u21, 'C'), v.cells[2].char);
}
```

- [ ] **Step 2: Run test, expect failure (count stays 0)**

```sh
zig build test 2>&1 | grep -A3 "scrollUp(1) full-screen pushes"
```

Expected: Test fails because nothing pushes to scrollback yet.

- [ ] **Step 3: Add a private helper for pushing the current physical row**

In `term.zig`, just above `pub fn scrollUp` (line 489), add:

```zig
    inline fn shouldPushScrollback(self: *const Self) bool {
        if (config.scrollback_lines == 0) return false;
        if (self.is_alt_screen) return false;
        const top: usize = self.scroll_top;
        const bot: usize = self.scroll_bottom;
        return top == 0 and bot + 1 == self.rows;
    }

    inline fn pushPhysRowToScrollback(self: *Self, phys_row: u32) void {
        if (config.scrollback_lines == 0) return;
        const start: usize = @as(usize, phys_row) * @as(usize, self.cols);
        self.scrollback.pushRow(
            self.cells[start..][0..self.cols],
            self.fg_rgb[start..][0..self.cols],
            self.bg_rgb[start..][0..self.cols],
            self.ul_color_rgb[start..][0..self.cols],
            self.hyperlink_ids[start..][0..self.cols],
        );
    }
```

- [ ] **Step 4: Modify `scrollUp` fast path (`shift == 1`)**

Inside `scrollUp` at line 500-507, change:

```zig
        if (shift == 1) {
            const recycled_phys = self.row_map[top];
            // Shift row_map entries left by 1
            const region = self.row_map[top .. bot + 1];
            std.mem.copyForwards(u32, region[0 .. region.len - 1], region[1..]);
            region[region.len - 1] = recycled_phys;
            // Clear recycled row
            self.bceMemset(recycled_phys * cols, (recycled_phys + 1) * cols);
        }
```

to:

```zig
        if (shift == 1) {
            const recycled_phys = self.row_map[top];
            // Push the row that's about to be evicted from the top
            if (self.shouldPushScrollback()) self.pushPhysRowToScrollback(recycled_phys);
            // Shift row_map entries left by 1
            const region = self.row_map[top .. bot + 1];
            std.mem.copyForwards(u32, region[0 .. region.len - 1], region[1..]);
            region[region.len - 1] = recycled_phys;
            // Clear recycled row
            self.bceMemset(recycled_phys * cols, (recycled_phys + 1) * cols);
        }
```

- [ ] **Step 5: Run test, expect pass**

```sh
zig build test 2>&1 | tail -10
```

Expected: New test + all existing tests pass.

- [ ] **Step 6: Commit**

```sh
git add src/term.zig
git commit -m "$(cat <<'EOF'
feat(term): push evicted row to scrollback in scrollUp(1) fast path

Adds shouldPushScrollback / pushPhysRowToScrollback helpers and uses
them on the n=1 full-screen scroll path. shouldPushScrollback gates on
comptime-disabled, alt screen, partial scroll regions. Push runs before
bceMemset clears the row.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Extend push to `scrollUp(n)` general path

**Files:**
- Modify: `src/term.zig` (`scrollUp` general path, line 508-516)

- [ ] **Step 1: Write the failing test**

```zig
test "Term: scrollUp(n) full-screen pushes n rows oldest first" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 3, 4);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.scroll_bottom = 3;

    term.scrollUp(3);

    try testing.expectEqual(@as(u32, 3), term.scrollback.count);
    // Newest scrollback row (age 0) is the LAST evicted = 'C'.
    try testing.expectEqual(@as(u21, 'C'), term.scrollback.rowAt(0).cells[0].char);
    try testing.expectEqual(@as(u21, 'B'), term.scrollback.rowAt(1).cells[0].char);
    try testing.expectEqual(@as(u21, 'A'), term.scrollback.rowAt(2).cells[0].char);
}
```

- [ ] **Step 2: Run, expect fail (only fast path pushes; n>1 path doesn't)**

```sh
zig build test 2>&1 | grep -A3 "scrollUp(n) full-screen"
```

- [ ] **Step 3: Modify the general path branch**

In `term.zig` `scrollUp` (line 508-516), change:

```zig
        } else {
            // Clear recycled rows with BCE
            for (0..shift) |s| {
                const phys = self.row_map[top + s];
                self.bceMemset(phys * cols, (phys + 1) * cols);
            }
            // General case: rotate row_map
            std.mem.rotate(u32, self.row_map[top .. bot + 1], shift);
        }
```

to:

```zig
        } else {
            // Push then clear each evicted row, oldest first.
            const push = self.shouldPushScrollback();
            for (0..shift) |s| {
                const phys = self.row_map[top + s];
                if (push) self.pushPhysRowToScrollback(phys);
                self.bceMemset(phys * cols, (phys + 1) * cols);
            }
            // General case: rotate row_map
            std.mem.rotate(u32, self.row_map[top .. bot + 1], shift);
        }
```

- [ ] **Step 4: Run test, expect pass**

```sh
zig build test 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```sh
git add src/term.zig
git commit -m "$(cat <<'EOF'
feat(term): push evicted rows on scrollUp(n) general path

Mirrors the fast-path change for n>1 scrolls. Rows are pushed in
top-to-bottom order so the newest evicted row ends up as scrollback
age 0.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Alt-screen / partial-region gating + view_offset reset on screen switch

**Files:**
- Modify: `src/term.zig` (`switchScreen` line 756 + tests)

- [ ] **Step 1: Write the gating tests**

```zig
test "Term: scrollUp on alt screen does NOT push" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    try term.switchScreen(true);
    term.setCell(0, 0, .{ .char = 'A' });
    term.scroll_bottom = 2;
    term.scrollUp(1);
    try testing.expectEqual(@as(u32, 0), term.scrollback.count);
}

test "Term: scrollUp partial region (DECSTBM) does NOT push" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 5, 5);
    defer term.deinit();
    term.setCell(0, 1, .{ .char = 'A' });
    term.scroll_top = 1;
    term.scroll_bottom = 3;
    term.scrollUp(1);
    try testing.expectEqual(@as(u32, 0), term.scrollback.count);
}

test "Term: switchScreen resets view_offset on enter and leave alt" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 5, 3);
    defer term.deinit();
    // Stage: pretend we have scrolled back into history.
    term.scroll_bottom = 2;
    term.scrollUp(1);
    term.view_offset = 1;

    try term.switchScreen(true);
    try testing.expectEqual(@as(u32, 0), term.view_offset);

    try term.switchScreen(false);
    try testing.expectEqual(@as(u32, 0), term.view_offset);
}
```

- [ ] **Step 2: Run, expect first two pass and the third fail**

```sh
zig build test 2>&1 | tail -20
```

The first two pass because `shouldPushScrollback` already gates. The third fails because `switchScreen` doesn't reset `view_offset`.

- [ ] **Step 3: Reset `view_offset` in `switchScreen`**

In `term.zig` `switchScreen` (line 756-834), at the very top of the function — before the `if (alt == self.is_alt_screen) return;` guard or right after — add:

```zig
        if (config.scrollback_lines > 0) self.view_offset = 0;
```

(Place it AFTER the `if (alt == self.is_alt_screen) return;` early exit, so a no-op switchScreen call stays a no-op.)

- [ ] **Step 4: Run, expect all three pass**

```sh
zig build test 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```sh
git add src/term.zig
git commit -m "$(cat <<'EOF'
feat(term): reset view_offset on screen switch + cover gating in tests

switchScreen sets view_offset = 0 on both enter and leave so a user
who scrolled back, then triggered an alt-screen app like less, snaps
back to live. Also adds tests confirming alt-screen and partial-region
scrolls skip scrollback.push (already gated by shouldPushScrollback).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: ED 3 clears scrollback (when not alt)

**Files:**
- Modify: `src/term.zig` (`eraseDisplay` function — locate via grep)

- [ ] **Step 1: Locate the existing `eraseDisplay` function**

```sh
grep -n "fn eraseDisplay" /home/midasdf/zt/src/term.zig
```

Read enough of the function to see how mode `3` is currently handled (or not).

- [ ] **Step 2: Write the failing test**

```zig
test "Term: eraseDisplay 3 clears scrollback when not alt" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 3, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.scroll_bottom = 2;
    term.scrollUp(1);
    try testing.expectEqual(@as(u32, 1), term.scrollback.count);

    term.eraseDisplay(3);
    try testing.expectEqual(@as(u32, 0), term.scrollback.count);
}

test "Term: eraseDisplay 3 in alt screen leaves main scrollback intact" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 3, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.scroll_bottom = 2;
    term.scrollUp(1);
    try testing.expectEqual(@as(u32, 1), term.scrollback.count);

    try term.switchScreen(true);
    term.eraseDisplay(3);
    try testing.expectEqual(@as(u32, 1), term.scrollback.count);
}
```

- [ ] **Step 3: Run, expect failure**

- [ ] **Step 4: Modify `eraseDisplay`**

In the `eraseDisplay` function, locate the branch that handles `mode == 3` (or add it if missing — check what xterm-style ED 3 does for the viewport currently in zt). The required addition is, at the top of the `mode == 3` arm:

```zig
        if (config.scrollback_lines > 0 and !self.is_alt_screen) {
            self.scrollback.clear();
        }
```

(If `mode == 3` does NOT exist as a branch, add it. The viewport-clear behaviour for ED 3 should match ED 2 in zt's existing semantics — preserve any current behaviour and just add the scrollback clear.)

- [ ] **Step 5: Run, expect pass**

- [ ] **Step 6: Commit**

```sh
git add src/term.zig
git commit -m "$(cat <<'EOF'
feat(term): clear scrollback on ED 3 when not in alt screen

Implements the xterm \\e[3J semantic for our scrollback: clears the
ring when the user (or 'clear' command) requests "erase saved lines".
Skipped when in alt screen so 'less' / 'vim' cannot wipe history.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2 — Render path + input bindings

After Phase 2, the user can scroll the buffer with wheel and Shift+keys.

### Task 9: Add view-offset helpers to `Term`

**Files:**
- Modify: `src/term.zig`

- [ ] **Step 1: Write the failing tests**

```zig
test "Term: scrollViewportUp clamps to scrollback.count" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 3, 3);
    defer term.deinit();
    term.scroll_bottom = 2;
    term.scrollUp(1);
    term.scrollUp(1);
    // count = 2

    term.scrollViewportUp(5); // clamp to 2
    try testing.expectEqual(@as(u32, 2), term.view_offset);

    term.scrollViewportDown(1);
    try testing.expectEqual(@as(u32, 1), term.view_offset);

    term.scrollViewportToBottom();
    try testing.expectEqual(@as(u32, 0), term.view_offset);
}
```

- [ ] **Step 2: Run, expect compile error (functions undefined)**

- [ ] **Step 3: Add helpers in `Term`**

Inside the `Term` struct (near `scrollUp`/`scrollDown`), add:

```zig
    inline fn scrollMarkDirty(self: *Self) void {
        // Selection coordinates are viewport-relative and assume live grid;
        // when view_offset changes those coordinates point at scrollback rows
        // we are NOT prepared to copy correctly. Clearing avoids stale
        // selections rendering as garbage.
        self.selection = null;
        self.markDirtyRange(.{ .start = 0, .end = self.cols * self.rows });
        self.all_dirty = true;
        self.dirty_flag = true;
    }

    pub fn scrollViewportUp(self: *Self, n: u32) void {
        if (config.scrollback_lines == 0) return;
        const max: u32 = self.scrollback.count;
        const new_off = self.view_offset +| n;
        const clamped: u32 = if (new_off > max) max else new_off;
        if (clamped == self.view_offset) return;
        self.view_offset = clamped;
        self.scrollMarkDirty();
    }

    pub fn scrollViewportDown(self: *Self, n: u32) void {
        if (config.scrollback_lines == 0) return;
        if (self.view_offset == 0) return;
        self.view_offset = if (n >= self.view_offset) 0 else self.view_offset - n;
        self.scrollMarkDirty();
    }

    pub fn scrollViewportToTop(self: *Self) void {
        if (config.scrollback_lines == 0) return;
        if (self.view_offset == self.scrollback.count) return;
        self.view_offset = self.scrollback.count;
        self.scrollMarkDirty();
    }

    pub fn scrollViewportToBottom(self: *Self) void {
        if (config.scrollback_lines == 0) return;
        if (self.view_offset == 0) return;
        self.view_offset = 0;
        self.scrollMarkDirty();
    }
```

- [ ] **Step 4: Run, expect pass**

- [ ] **Step 5: Commit**

```sh
git commit -am "$(cat <<'EOF'
feat(term): scrollViewportUp/Down/ToTop/ToBottom helpers

view_offset manipulation with saturating arithmetic + full repaint
flag flipping. Used by main.zig wheel + Shift+key handlers next.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Render loop reads from scrollback when `view_offset > 0`

**Files:**
- Modify: `src/main.zig` (render loop, lines 1489-1562)

- [ ] **Step 1: Read the existing render loop**

Re-open `main.zig:1489-1562`. Note the per-row resolution at line 1495-1502:

```zig
const phys_row = term.row_map[y];
const row_base = @as(usize, phys_row) * @as(usize, term.cols);
const row_cells = term.cells[row_base..][0..term.cols];
const row_fg = term.fg_rgb[row_base..][0..term.cols];
const row_bg = term.bg_rgb[row_base..][0..term.cols];
const row_ul = term.ul_color_rgb[row_base..][0..term.cols];
const row_hl = term.hyperlink_ids[row_base..][0..term.cols];
```

The render loop is `while (y < term.rows) : (y += 1)`. We need to substitute the source slices with scrollback views when `y < view_offset`.

- [ ] **Step 2: Modify the render loop body**

Replace lines 1495-1502 with:

```zig
            const sb_age: ?u32 = if (config.scrollback_lines > 0 and y < term.view_offset)
                term.view_offset - 1 - y
            else
                null;

            var row_cells: []const Cell = undefined;
            var row_fg: []const ?[3]u8 = undefined;
            var row_bg: []const ?[3]u8 = undefined;
            var row_ul: []const ?[3]u8 = undefined;
            var row_hl: []const u16 = undefined;

            if (sb_age) |age| {
                const v = term.scrollback.rowAt(age);
                row_cells = v.cells;
                row_fg = v.fg_rgb;
                row_bg = v.bg_rgb;
                row_ul = v.ul_color_rgb;
                row_hl = v.hyperlink_ids;
            } else {
                const live_y: u32 = if (config.scrollback_lines > 0) y - term.view_offset else y;
                const phys_row = term.row_map[live_y];
                const row_base = @as(usize, phys_row) * @as(usize, term.cols);
                row_cells = term.cells[row_base..][0..term.cols];
                row_fg = term.fg_rgb[row_base..][0..term.cols];
                row_bg = term.bg_rgb[row_base..][0..term.cols];
                row_ul = term.ul_color_rgb[row_base..][0..term.cols];
                row_hl = term.hyperlink_ids[row_base..][0..term.cols];
            }
```

Also update the cursor + selection logic in the same loop body. Locate the `is_cursor` line (line 1517) and gate it:

```zig
                const is_cursor = vis and sb_age == null and term.cursor_y == y - term.view_offset and (term.cursor_x == x or
                    (cell.attrs.wide and x + 1 < term.cols and term.cursor_x == x + 1));
```

(When `sb_age != null` we are rendering a scrollback row — no cursor on it.)

For the selection, line 1525-1528:

```zig
                const in_selection = if (sb_age == null) blk: {
                    if (sel_opt) |sel| break :blk sel.coversWideLeftCell(x, y - term.view_offset, cell.attrs.wide, term.cols);
                    break :blk false;
                } else false;
```

When `scrollback_lines == 0`, `term.view_offset` is `void`. Both branches in the comptime-known `if (config.scrollback_lines > 0 and y < term.view_offset)` collapse to the existing behaviour, so the comptime gate keeps the disabled-build behaviour identical.

Important: this requires `Cell` type to be in scope at the top of `main.zig`. Confirm via grep — if `term.Cell` is what's used currently, change the new `var row_cells: []const Cell` to `var row_cells: []const term.Cell` (or whatever the file's existing alias is).

- [ ] **Step 3: Build the binary**

```sh
cd /home/midasdf/zt
zig build -Dbackend=x11 2>&1 | tail -10
```

Expected: builds clean.

- [ ] **Step 4: Manual smoke test**

```sh
./zig-out/bin/zt &
# Inside zt: run `seq 1 1000`, then mouse-wheel up. (Wheel hookup is the next task —
# for now manually test that view_offset!=0 renders scrollback by adding a temp keybind.)
```

For now, just verify the binary launches and basic rendering still works (no scrollback yet visible because input not wired). You can also write a unit test that calls `scrollViewportUp` and inspects backend buffer contents — but the rendering is in `main.zig` not `term.zig`, so a unit test is awkward; defer to the integration test in Task 12.

- [ ] **Step 5: Commit**

```sh
git commit -am "$(cat <<'EOF'
feat(render): branch render loop on view_offset for scrollback

When y < term.view_offset the row source slices come from
term.scrollback.rowAt(age) instead of term.cells; cursor and selection
overlays are suppressed for those rows. With -Dscrollback_lines=0 the
comptime gate makes the entire branch dead code.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Wheel routing (3-case)

**Files:**
- Modify: `src/main.zig` (`handleTerminalSelection`, lines 826-829)

- [ ] **Step 1: Locate and read the current handler**

`main.zig:826-829`:

```zig
            .wheel_up, .wheel_down => {
                // When no app captures mouse and in alt screen,
                // translate wheel to arrow keys for less/man etc.
                // TODO: scrollback when implemented
            },
```

- [ ] **Step 2: Find where the wheel translation actually happens for the alt-screen case**

```sh
grep -n "wheel_up.*wheel_down\|arrow\|.up.*\\\\x1b\\[" /home/midasdf/zt/src/main.zig | head -10
```

If translation is currently a no-op (the existing comment suggests it's just dropped, with the TODO), then we add new behaviour for the main-screen case and add the alt-screen translation as part of this task.

- [ ] **Step 3: Replace the handler**

Change `main.zig:826-829` to:

```zig
            .wheel_up, .wheel_down => {
                if (config.scrollback_lines > 0 and !term.is_alt_screen) {
                    if (ev.button == .wheel_up) {
                        term.scrollViewportUp(config.scrollback_wheel_lines);
                    } else {
                        term.scrollViewportDown(config.scrollback_wheel_lines);
                    }
                } else if (term.is_alt_screen) {
                    // Translate to arrow keys so less/man/vim still scroll.
                    const seq: []const u8 = if (ev.button == .wheel_up)
                        (if (term.decckm) "\x1bOA" else "\x1b[A")
                    else
                        (if (term.decckm) "\x1bOB" else "\x1b[B");
                    // Send the sequence config.scrollback_wheel_lines times so a
                    // single wheel notch advances multiple lines, matching the
                    // main-screen scroll feel.
                    var i: u32 = 0;
                    while (i < config.scrollback_wheel_lines) : (i += 1) {
                        _ = ptyBufferedWrite(pty_ptr, seq, write_queue, evloop_fd);
                    }
                }
                // mouse_mode != .none case: this handler is only invoked when
                // mouse capture is OFF; when ON, the dispatcher above routes
                // wheel events through `encodeMouseEvent` / writes them as
                // VT mouse reports (existing behaviour, untouched).
            },
```

NOTE: The wheel-to-arrow-keys block needs `pty_ptr`, `write_queue`, `evloop_fd` in scope. Inspect `handleTerminalSelection`'s signature — if those aren't passed in, add them as arguments and update the call sites. (The function currently takes `term`, `ev`, `cx`, `cy`. Adding three more args means updating one call site.)

If passing extra args feels invasive, an alternative is to return an enum from the handler indicating "send wheel-up" / "send wheel-down" / "noop" and let the caller perform the write. Pick whichever fits the existing dispatch pattern. Document the choice in the commit message.

- [ ] **Step 4: Build and smoke-test**

```sh
zig build -Dbackend=x11
./zig-out/bin/zt &
# Run `seq 1 5000`. Wheel-up should reveal earlier output.
# Wheel-down returns to live tail.
# Run `less /etc/services`. Wheel inside less should still scroll less.
```

- [ ] **Step 5: Commit**

```sh
git commit -am "$(cat <<'EOF'
feat(input): wheel scrolls scrollback on main; arrow-key fallback in alt

Wheel-up/down on main screen now scrolls our scrollback by
config.scrollback_wheel_lines (default 3). On alt screen the wheel is
translated to arrow keys so less/man/vim continue to behave naturally.
Apps with mouse capture (mouse_mode != .none) keep receiving raw VT
mouse reports unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Shift+PgUp / Shift+PgDn / Shift+Home / Shift+End bindings

**Files:**
- Modify: `src/main.zig` (`handleBackendEvent` `.key` arm, line 522-533)

- [ ] **Step 1: Read the existing `.key` arm**

`main.zig:522-533`:

```zig
        .key => |key_ev| {
            refreshCursorBlinkOnUserInput(...);
            if (key_ev.pressed) {
                const bytes = input.translateKey(key_ev.keycode, key_ev.modifiers, term.decckm, term.decbkm);
                if (bytes.len > 0) {
                    if (!ptyBufferedWrite(pty_ptr, bytes, write_queue, evloop_fd)) {
                        return false;
                    }
                }
            }
        },
```

We add a scrollback-key intercept before `input.translateKey`.

- [ ] **Step 2: Add the import for KEY codes if not already present**

Confirm `main.zig` already imports `input.zig`. The KEY namespace is in `input.zig:78-..` (`pub const HOME = 102;` etc). Reach via `input.KEY.PAGEUP` etc.

- [ ] **Step 3: Replace the `.key` arm**

```zig
        .key => |key_ev| {
            refreshCursorBlinkOnUserInput(cursor_visible_blink, cursor_blink_active, last_input_ns);
            if (!key_ev.pressed) return true;

            // Scrollback shortcuts — main screen only, scrollback enabled.
            if (config.scrollback_lines > 0 and !term.is_alt_screen and key_ev.modifiers.shift) {
                const handled = switch (key_ev.keycode) {
                    input.KEY.PAGEUP => blk: {
                        // page = rows - 1 so one line of context is preserved
                        const page = if (term.rows > 1) term.rows - 1 else 1;
                        term.scrollViewportUp(page);
                        break :blk true;
                    },
                    input.KEY.PAGEDOWN => blk: {
                        const page = if (term.rows > 1) term.rows - 1 else 1;
                        term.scrollViewportDown(page);
                        break :blk true;
                    },
                    input.KEY.HOME => blk: {
                        term.scrollViewportToTop();
                        break :blk true;
                    },
                    input.KEY.END => blk: {
                        term.scrollViewportToBottom();
                        break :blk true;
                    },
                    else => false,
                };
                if (handled) return true;
            }

            // Normal key path (also auto-jumps to live tail if scrolled back).
            if (config.scrollback_lines > 0 and term.view_offset > 0) {
                term.scrollViewportToBottom();
            }
            const bytes = input.translateKey(key_ev.keycode, key_ev.modifiers, term.decckm, term.decbkm);
            if (bytes.len > 0) {
                if (!ptyBufferedWrite(pty_ptr, bytes, write_queue, evloop_fd)) {
                    return false;
                }
            }
        },
```

Apply the same auto-jump to `.text` and `.paste` arms — locate them in `main.zig:534-573`. At the top of each arm (right after the `refreshCursorBlinkOnUserInput` call), insert:

```zig
            if (config.scrollback_lines > 0 and term.view_offset > 0) {
                term.scrollViewportToBottom();
            }
```

- [ ] **Step 4: Build and smoke test**

```sh
zig build -Dbackend=x11
./zig-out/bin/zt &
# Inside: seq 1 5000, Shift+PgUp scrolls up a page, Shift+PgDn back, Shift+Home top, Shift+End bottom.
# Type any letter while scrolled — view jumps to live tail before the letter is sent.
# Open less, Shift+PgUp scrolls less itself (alt screen, shortcut inactive).
```

- [ ] **Step 5: Commit**

```sh
git commit -am "$(cat <<'EOF'
feat(input): Shift+PgUp/PgDn/Home/End for scrollback navigation

Page = rows-1 to preserve one line of context. All four keys are inert
on alt screen (so less/vim still get the unmodified sequences). Any
ordinary key/text/paste arms also auto-jump to live tail before
forwarding to the PTY.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3 — Resize handling

### Task 13: `Scrollback.resize(new_cols)`

**Files:**
- Modify: `src/scrollback.zig`

- [ ] **Step 1: Write the failing tests**

```zig
test "Scrollback: resize shrinks rows and preserves content" {
    var sb = try Scrollback.init(testing.allocator, 5, 5);
    defer sb.deinit();

    const cells = [_]Cell{
        .{ .char = 'A' }, .{ .char = 'B' }, .{ .char = 'C' },
        .{ .char = 'D' }, .{ .char = 'E' },
    };
    const empty_rgb = [_]?[3]u8{null} ** 5;
    const empty_hl = [_]u16{0} ** 5;
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl);

    try sb.resize(3);
    try testing.expectEqual(@as(u32, 3), sb.cols);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'B'), v.cells[1].char);
    try testing.expectEqual(@as(u21, 'C'), v.cells[2].char);
    try testing.expectEqual(@as(u16, 3), v.used_cols);
}

test "Scrollback: resize grows rows and pads with blanks" {
    var sb = try Scrollback.init(testing.allocator, 5, 3);
    defer sb.deinit();

    const cells = [_]Cell{ .{ .char = 'X' }, .{ .char = 'Y' }, .{ .char = 'Z' } };
    const empty_rgb = [_]?[3]u8{null} ** 3;
    const empty_hl = [_]u16{0} ** 3;
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl);

    try sb.resize(6);
    try testing.expectEqual(@as(u32, 6), sb.cols);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'X'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'Y'), v.cells[1].char);
    try testing.expectEqual(@as(u21, 'Z'), v.cells[2].char);
    try testing.expectEqual(@as(u21, ' '), v.cells[3].char);
    try testing.expectEqual(@as(u21, ' '), v.cells[5].char);
}

test "Scrollback: resize fixes wide-char left-half stranded at new last column" {
    var sb = try Scrollback.init(testing.allocator, 5, 4);
    defer sb.deinit();

    var cells = [_]Cell{
        .{ .char = 'A' },
        .{ .char = '日', .attrs = .{ .wide = true } },
        .{ .char = ' ', .attrs = .{ .wide_dummy = true } },
        .{ .char = 'B' },
    };
    const empty_rgb = [_]?[3]u8{null} ** 4;
    const empty_hl = [_]u16{0} ** 4;
    sb.pushRow(&cells, &empty_rgb, &empty_rgb, &empty_rgb, &empty_hl);

    // Shrink to 2 cols — the wide char's right half (col 2) is dropped, so
    // the wide left half at col 1 must be replaced with blank to avoid a
    // stranded half-glyph.
    try sb.resize(2);
    const v = sb.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, ' '), v.cells[1].char);
    try testing.expect(!v.cells[1].attrs.wide);
}
```

- [ ] **Step 2: Run, expect compile error (`resize` undefined)**

- [ ] **Step 3: Implement `resize`**

In `scrollback.zig`, inside the `Scrollback` struct, add:

```zig
    pub fn resize(self: *Self, new_cols: u32) !void {
        if (new_cols == self.cols) return;

        const new_total: usize = @as(usize, self.capacity) * @as(usize, new_cols);

        const new_cells = try self.allocator.alloc(Cell, new_total);
        errdefer self.allocator.free(new_cells);
        const new_fg = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_fg);
        const new_bg = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_bg);
        const new_ul = try self.allocator.alloc(?[3]u8, new_total);
        errdefer self.allocator.free(new_ul);
        const new_hl = try self.allocator.alloc(u16, new_total);

        @memset(new_cells, Cell{ .char = ' ' });
        @memset(new_fg, null);
        @memset(new_bg, null);
        @memset(new_ul, null);
        @memset(new_hl, 0);

        const copy_cols: usize = @min(self.cols, new_cols);
        var slot: u32 = 0;
        while (slot < self.capacity) : (slot += 1) {
            const old_start: usize = @as(usize, slot) * @as(usize, self.cols);
            const new_start: usize = @as(usize, slot) * @as(usize, new_cols);
            @memcpy(new_cells[new_start .. new_start + copy_cols],
                    self.cells[old_start .. old_start + copy_cols]);
            @memcpy(new_fg[new_start .. new_start + copy_cols],
                    self.fg_rgb[old_start .. old_start + copy_cols]);
            @memcpy(new_bg[new_start .. new_start + copy_cols],
                    self.bg_rgb[old_start .. old_start + copy_cols]);
            @memcpy(new_ul[new_start .. new_start + copy_cols],
                    self.ul_color_rgb[old_start .. old_start + copy_cols]);
            @memcpy(new_hl[new_start .. new_start + copy_cols],
                    self.hyperlink_ids[old_start .. old_start + copy_cols]);

            // Wide-char boundary fix: if the new last column holds a wide-left
            // glyph whose dummy was just dropped, blank it out.
            if (new_cols < self.cols and copy_cols > 0) {
                const last = new_start + copy_cols - 1;
                if (new_cells[last].attrs.wide) {
                    new_cells[last] = .{ .char = ' ' };
                    new_fg[last] = null;
                    new_bg[last] = null;
                    new_ul[last] = null;
                    new_hl[last] = 0;
                }
            }

            // Clamp used_cols to new width
            if (self.used_cols[slot] > new_cols) self.used_cols[slot] = @intCast(new_cols);
        }

        self.allocator.free(self.cells);
        self.allocator.free(self.fg_rgb);
        self.allocator.free(self.bg_rgb);
        self.allocator.free(self.ul_color_rgb);
        self.allocator.free(self.hyperlink_ids);

        self.cells = new_cells;
        self.fg_rgb = new_fg;
        self.bg_rgb = new_bg;
        self.ul_color_rgb = new_ul;
        self.hyperlink_ids = new_hl;
        self.cols = new_cols;
    }
```

- [ ] **Step 4: Run, expect pass**

- [ ] **Step 5: Commit**

```sh
git add src/scrollback.zig
git commit -m "$(cat <<'EOF'
feat(scrollback): resize(new_cols) with truncate / pad + wide-char fix

v1 truncate-only resize. Allocates new flat blobs, copies min(old,new)
columns from each row, pads with blanks, and blanks out wide-char left
halves stranded at the new last column. used_cols clamped to new
width. Capacity remains comptime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Wire `scrollback.resize` into `Term.resize`

**Files:**
- Modify: `src/term.zig` (`resize`, line 550-754)

- [ ] **Step 1: Write the failing test**

```zig
test "Term: resize forwards to scrollback and clamps view_offset" {
    if (config.scrollback_lines == 0) return error.SkipZigTest;
    var term = try Term.init(testing.allocator, 5, 4);
    defer term.deinit();

    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(1, 0, .{ .char = 'B' });
    term.setCell(2, 0, .{ .char = 'C' });
    term.setCell(3, 0, .{ .char = 'D' });
    term.setCell(4, 0, .{ .char = 'E' });
    term.scroll_bottom = 3;
    term.scrollUp(1);
    term.view_offset = 1;

    try term.resize(3, 4);
    try testing.expectEqual(@as(u32, 3), term.scrollback.cols);
    const v = term.scrollback.rowAt(0);
    try testing.expectEqual(@as(u21, 'A'), v.cells[0].char);
    try testing.expectEqual(@as(u21, 'B'), v.cells[1].char);
    try testing.expectEqual(@as(u21, 'C'), v.cells[2].char);

    // view_offset was 1, scrollback.count is 1, no clamp needed.
    try testing.expectEqual(@as(u32, 1), term.view_offset);
}
```

- [ ] **Step 2: Run, expect failure (resize hasn't been wired yet)**

- [ ] **Step 3: Modify `Term.resize`**

At the END of the existing `resize` function in `term.zig` (after the alt-buffer commit, before the function returns), add:

```zig
        if (config.scrollback_lines > 0) {
            try self.scrollback.resize(new_cols);
            if (self.view_offset > self.scrollback.count) {
                self.view_offset = self.scrollback.count;
            }
        }
```

WARNING: `try` here can fail with OOM. The existing `resize` does its allocations under careful errdefer ordering (lines 558-606). The scrollback resize should happen AFTER all main+alt buffers are committed (Phase 2 of existing resize, around line 690-754). If `scrollback.resize` fails, the term still survives — the scrollback is partially in old state. Since `Scrollback.resize` allocates new blobs first under errdefer, on failure the old blobs are still owned and consistent — so a failure leaves us with stale-cols scrollback but a functional terminal. Acceptable.

- [ ] **Step 4: Run, expect pass**

- [ ] **Step 5: Commit**

```sh
git commit -am "$(cat <<'EOF'
feat(term): forward resize to scrollback and clamp view_offset

After main+alt buffers are committed, resize the scrollback to the new
column count and clamp view_offset to the (possibly unchanged)
scrollback.count. OOM in scrollback.resize leaves the terminal
functional with stale-cols scrollback — acceptable for v1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4 — Polish

### Task 15: Comptime size snapshot test

**Files:**
- Modify: `src/term.zig`

- [ ] **Step 1: Determine the expected `@sizeOf(Term)` with `scrollback_lines = 0`**

```sh
cd /home/midasdf/zt
zig build -Dbackend=x11 -Dscrollback_lines=0 -Doptimize=Debug
# Then add a temporary @compileLog at the end of term.zig:
#   comptime { @compileLog(@sizeOf(Term)); }
# Run zig build, capture the printed size, remove the line.
```

Record the size as `EXPECTED_TERM_SIZE_NO_SCROLLBACK`. Example: `1024` (replace with the actual number).

- [ ] **Step 2: Add a guarded snapshot test**

At the end of `term.zig`'s test section, add:

```zig
test "Term: @sizeOf is unchanged when scrollback_lines == 0" {
    if (config.scrollback_lines != 0) return error.SkipZigTest;
    const EXPECTED: usize = <RECORDED VALUE>;
    try testing.expectEqual(EXPECTED, @sizeOf(Term));
}
```

(Replace `<RECORDED VALUE>` with the number from step 1.)

- [ ] **Step 3: Verify both flag values pass tests**

```sh
zig build test
zig build test -Dscrollback_lines=0
```

- [ ] **Step 4: Commit**

```sh
git commit -am "$(cat <<'EOF'
test(term): snapshot @sizeOf(Term) under -Dscrollback_lines=0

Guards against accidental field bloat creeping into the disabled path.
Bumping the snapshot requires explicit consent in a follow-up commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 16: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/qa-checklist.md`

- [ ] **Step 1: README.md — remove the "No scrollback buffer" limitation**

Find the line in the **Limitations** section:

```
- **No scrollback buffer** — only the current viewport
```

Replace with:

```
- **Scrollback** — fixed capacity, set at compile time via `-Dscrollback_lines=N` (default 10000, 0 disables). No reflow on column resize.
```

Also locate the **Mouse support is limited** line and update:

```
- **Mouse wheel** — scrolls scrollback in main screen; translates to arrow keys for `less`/`vim` in alt screen; passes through to apps with mouse capture.
```

- [ ] **Step 2: README.md — add the build flag to the More Options block**

In the **More Options** section, append a new example:

```sh
# Disable scrollback (smaller binary, no scroll history)
zig build -Dbackend=x11 -Dscrollback_lines=0 -Doptimize=ReleaseFast

# Smaller scrollback (lower memory)
zig build -Dbackend=x11 -Dscrollback_lines=2000 -Doptimize=ReleaseFast
```

- [ ] **Step 3: Add scrollback section to qa-checklist.md**

Open `docs/qa-checklist.md` and append:

```markdown
## Scrollback

- [ ] `seq 1 5000 | cat` then mouse-wheel up scrolls earlier output into view; wheel down returns to live tail.
- [ ] Shift+PageUp / Shift+PageDown moves a page at a time.
- [ ] Shift+Home jumps to the oldest scrollback row; Shift+End jumps to live tail.
- [ ] Typing any printable character while scrolled jumps to live tail before the keystroke is sent.
- [ ] `less /etc/services` — wheel inside `less` does NOT touch our scrollback (alt screen).
- [ ] Quit `less` — main scrollback contents intact.
- [ ] `vim` — wheel inside `vim` translates to arrow keys; main scrollback untouched.
- [ ] `btop` — wheel forwarded to btop (mouse_mode != none); Shift+PgUp scrolls our scrollback (handled by us).
- [ ] Resize the window (drag corner) while scrolled to middle of scrollback — no crash; view stays sane.
- [ ] `clear` command followed by Shift+PgUp shows nothing (ED 3 cleared scrollback).
- [ ] Inside `less`, run `:!clear` then quit — main scrollback was NOT cleared.
- [ ] Cross-compile aarch64 with `-Dscrollback_lines=0` and `-Dscrollback_lines=2000` — both link, binary size delta < 5 KB at `=0`.
```

- [ ] **Step 4: Commit**

```sh
git add README.md docs/qa-checklist.md
git commit -m "$(cat <<'EOF'
docs(scrollback): update README limitations + qa-checklist

Removes the "no scrollback buffer" limitation, adds the
-Dscrollback_lines build flag examples, and seeds qa-checklist with
the manual smoke tests covering wheel, Shift+key, alt-screen, ED 3,
and resize behaviours.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 17: Manual QA pass

**Files:** none (just running the binary)

- [ ] **Step 1: Build with all backends**

```sh
zig build -Dbackend=x11 -Doptimize=ReleaseFast
zig build -Dbackend=wayland -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseSmall   # fbdev
```

- [ ] **Step 2: Run the qa-checklist.md `## Scrollback` section against each backend you can launch**

Mark each item PASS/FAIL/N-A. If anything fails, file a follow-up task and either fix it before merging or document the limitation.

- [ ] **Step 3: Run the existing test suite**

```sh
zig build test
zig build test -Dscrollback_lines=0
zig build test -Dscrollback_lines=2000
```

All three should pass.

- [ ] **Step 4: Merge feat/scrollback into main**

```sh
git checkout main
git merge --no-ff feat/scrollback -m "$(cat <<'EOF'
Merge feat/scrollback: main-screen scrollback buffer

See docs/superpowers/specs/2026-05-01-zt-scrollback-design.md for the
design and docs/superpowers/plans/2026-05-01-zt-scrollback.md for the
phased implementation. Capacity is comptime via -Dscrollback_lines
(default 10000, 0 opts out at zero overhead).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Done

After Task 17 the feature is shipped:
- `Scrollback` is owned by `Term` behind a comptime gate
- Wheel + Shift+keys browse history in main screen
- Alt-screen apps unaffected
- Resize handles truncate/pad
- Documentation reflects the new state

Phase 2+ deferrals (selection of scrollback rows, search, reflow) are tracked under a separate spec.
