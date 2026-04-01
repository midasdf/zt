# xterm-256color Full Compatibility Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make zt pass vttest basic tests and fully support all xterm-256color terminfo capabilities, enabling every TUI app to work correctly.

**Architecture:** Three tiers of progressive enhancement. Tier 1 adds features apps actively use (OSC, focus events, mode queries). Tier 2 adds spec-compliance features. Tier 3 adds niche/advanced features (VT52, Tektronix). Each tier is independently shippable. All changes are in `src/vt.zig` and `src/term.zig` unless noted.

**Tech Stack:** Zig 0.15+, XCB (for focus events), existing VT parser state machine.

**Current state (v0.2.2):** CSI parser handles `?`/`>`/`<`/`=` private markers. 33 CSI final bytes, 12 ESC sequences, 18 SGR codes, 17 DECSET modes. BCE implemented. Deferred wrap implemented. DCS XTGETTCAP implemented.

---

## Chunk 1: Tier 1 — Features Apps Actually Use

### Task 1: OSC Dispatch (Window Title, Dynamic Colors)

**Files:**
- Modify: `src/vt.zig:606-614` (executeActionWithFd, osc_dispatch handler)
- Modify: `src/term.zig` (add title buffer field)
- Test: `src/vt.zig` (add tests at bottom)

Currently `osc_dispatch => {}` silently drops all OSC. Apps like Claude Code, vim, fish, and htop send OSC 0/2 (title), OSC 10/11 (color query), OSC 52 (clipboard), OSC 104 (reset colors).

- [ ] **Step 1: Add title buffer to Term**

In `src/term.zig`, add field after `cursor_style`:
```zig
    // Window/icon title (OSC 0/1/2)
    title: [256]u8 = undefined,
    title_len: u8 = 0,
```

- [ ] **Step 2: Write handleOsc function in vt.zig**

Add after `handleDcsDispatch`:
```zig
fn handleOsc(payload: []const u8, term: *Term, writer_fd: ?std.posix.fd_t) void {
    // Parse "Ps;Pt" — find first ';' to separate command from parameter
    const sep = std.mem.indexOfScalar(u8, payload, ';');
    const cmd_str = if (sep) |s| payload[0..s] else payload;
    const param = if (sep) |s| payload[s + 1 ..] else &[_]u8{};

    // Parse command number
    var cmd: u16 = 0;
    for (cmd_str) |ch| {
        if (ch >= '0' and ch <= '9') {
            cmd = cmd *| 10 +| (ch - '0');
        } else break;
    }

    switch (cmd) {
        0, 2 => { // Set window title (+ icon name for 0)
            const len = @min(param.len, 255);
            @memcpy(term.title[0..len], param[0..len]);
            term.title_len = @intCast(len);
        },
        1 => {}, // Set icon name only — silently accept
        4 => {}, // Set color palette — silently accept
        7 => {}, // Set working directory — silently accept
        8 => {}, // Hyperlinks — silently accept
        10, 11, 12 => {
            // Dynamic color query: param == "?" means query
            if (std.mem.eql(u8, param, "?")) {
                if (writer_fd) |fd| {
                    // Respond with current color in rgb:RR/GG/BB format
                    // Default: fg=white, bg=black, cursor=white
                    const response = switch (cmd) {
                        10 => "\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
                        11 => "\x1b]11;rgb:0000/0000/0000\x1b\\",
                        12 => "\x1b]12;rgb:ffff/ffff/ffff\x1b\\",
                        else => unreachable,
                    };
                    _ = std.posix.write(fd, response) catch {};
                }
            }
            // Set color — silently accept (no palette mutation)
        },
        52 => {}, // Clipboard — silently accept (no X11 clipboard integration yet)
        104, 110, 111, 112 => {}, // Reset colors — silently accept
        else => {},
    }
}
```

- [ ] **Step 3: Wire osc_dispatch to handleOsc**

In `executeActionWithFd` (line 612), change:
```zig
        .osc_dispatch => {},
```
to:
```zig
        .osc_dispatch => |payload| handleOsc(payload, term, writer_fd),
```

- [ ] **Step 4: Write test for OSC title parsing**

```zig
test "OSC: title set via OSC 0" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // ESC ] 0 ; H e l l o BEL
    for ("\x1b]0;Hello\x07") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    try testing.expectEqualSlices(u8, "Hello", term.title[0..term.title_len]);
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add src/vt.zig src/term.zig
git commit -m "feat: implement OSC dispatch (title, dynamic color query, clipboard accept)"
```

---

### Task 2: Focus Events (DECSET ?1004)

**Files:**
- Modify: `src/term.zig` (add `focus_events` flag)
- Modify: `src/vt.zig` (DECSET ?1004 handler)
- Modify: `src/backend/x11.zig` (add XCB_FOCUS_IN/OUT event handling)
- Modify: `src/main.zig` (send CSI I / CSI O on focus change)

Claude Code enables `?1004` and expects `CSI I` on focus-in and `CSI O` on focus-out.

- [ ] **Step 1: Add focus_events flag to Term**

In `src/term.zig`, add field after `deckpam`:
```zig
    // Focus event tracking (DECSET ?1004)
    focus_events: bool = false,
```

- [ ] **Step 2: Update DECSET ?1004 in vt.zig**

Change the line `1004 => {},` to:
```zig
            1004 => term.focus_events = set,
```

- [ ] **Step 3: Add focus event to X11 backend**

In `src/backend/x11.zig`, in the `pollEvents` switch (around line 720), add before the `else => continue` case:
```zig
            c.XCB_FOCUS_IN => return .focus_in,
            c.XCB_FOCUS_OUT => return .focus_out,
```

Also add to the Event union type (search for the event enum/union in x11.zig):
```zig
    focus_in,
    focus_out,
```

- [ ] **Step 4: Handle focus events in main.zig**

In the backend event switch (around line 411), add cases:
```zig
                                .focus_in => {
                                    if (term.focus_events) {
                                        if (!ptyBufferedWrite(&pty, "\x1b[I", &write_buf, &write_pending, epoll_fd)) {
                                            running = false;
                                            break;
                                        }
                                    }
                                },
                                .focus_out => {
                                    if (term.focus_events) {
                                        if (!ptyBufferedWrite(&pty, "\x1b[O", &write_buf, &write_pending, epoll_fd)) {
                                            running = false;
                                            break;
                                        }
                                    }
                                },
```

- [ ] **Step 5: Run tests + build**

Run: `zig build test && zig build -Dbackend=x11`
Expected: PASS + compiles

- [ ] **Step 6: Commit**

```bash
git add src/term.zig src/vt.zig src/backend/x11.zig src/main.zig
git commit -m "feat: implement focus events (DECSET ?1004, CSI I/O)"
```

---

### Task 3: DECRQM — Mode Query Response

**Files:**
- Modify: `src/vt.zig` (handleCsi, add `p` case for `$p` intermediate)

Apps use `CSI Ps $ p` (ANSI mode query) and `CSI ? Ps $ p` (DEC mode query) to detect terminal capabilities. Response: `CSI Ps ; Pm $ y` where Pm: 1=set, 2=reset, 0=not recognized.

- [ ] **Step 1: Add DECRQM handler to handleCsi**

The sequence `CSI ? Ps $ p` has intermediate `$` and final `p`. The parser puts `$` in intermediates[0].

In handleCsi, update the `'p'` case:
```zig
        'p' => {
            if (csi.intermediate_count > 0 and csi.intermediates[0] == '!') {
                // DECSTR — Soft Terminal Reset (existing code)
                term.cursor_x = 0;
                term.cursor_y = 0;
                term.wrap_next = false;
                term.insert_mode = false;
                term.linefeed_mode = false;
                term.origin_mode = false;
                term.decawm = true;
                term.decckm = false;
                term.cursor_visible = true;
                term.current_fg = 7;
                term.current_bg = 0;
                term.current_attrs = .{};
                term.current_fg_rgb = null;
                term.current_bg_rgb = null;
                term.charset = 0;
                term.charsets = .{ .us_ascii, .us_ascii, .us_ascii, .us_ascii };
                term.scroll_top = 0;
                term.scroll_bottom = term.rows -| 1;
                for (0..term.tabs.len) |c_idx| {
                    term.tabs[c_idx] = (c_idx % 8 == 0) and c_idx > 0;
                }
            } else if (csi.intermediate_count > 0 and csi.intermediates[0] == '$') {
                // DECRQM — Request Mode
                if (writer_fd) |fd| {
                    const mode = if (pc > 0) p[0] else 0;
                    var buf: [32]u8 = undefined;
                    if (csi.private_marker == '?') {
                        // DEC private mode query
                        const status: u8 = queryDecMode(term, mode);
                        const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, status }) catch return;
                        _ = std.posix.write(fd, resp) catch {};
                    } else if (csi.private_marker == 0) {
                        // ANSI mode query
                        const status: u8 = queryAnsiMode(term, mode);
                        const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}$y", .{ mode, status }) catch return;
                        _ = std.posix.write(fd, resp) catch {};
                    }
                }
            }
        },
```

- [ ] **Step 2: Add queryDecMode and queryAnsiMode functions**

```zig
fn queryDecMode(term: *const Term, mode: u16) u8 {
    // Returns: 1=set, 2=reset, 0=not recognized
    return switch (mode) {
        1 => if (term.decckm) @as(u8, 1) else 2,
        6 => if (term.origin_mode) @as(u8, 1) else 2,
        7 => if (term.decawm) @as(u8, 1) else 2,
        25 => if (term.cursor_visible) @as(u8, 1) else 2,
        47, 1047 => if (term.is_alt_screen) @as(u8, 1) else 2,
        1049 => if (term.is_alt_screen) @as(u8, 1) else 2,
        1004 => if (term.focus_events) @as(u8, 1) else 2,
        2004 => if (term.bracketed_paste) @as(u8, 1) else 2,
        2026 => if (term.sync_update) @as(u8, 1) else 2,
        else => 0,
    };
}

fn queryAnsiMode(term: *const Term, mode: u16) u8 {
    return switch (mode) {
        4 => if (term.insert_mode) @as(u8, 1) else 2,
        20 => if (term.linefeed_mode) @as(u8, 1) else 2,
        else => 0,
    };
}
```

- [ ] **Step 3: Write test**

```zig
test "DECRQM: query DECAWM mode" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    // DECAWM is true by default
    try testing.expect(term.decawm);
    const status = queryDecMode(&term, 7);
    try testing.expectEqual(@as(u8, 1), status);
}
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/vt.zig
git commit -m "feat: implement DECRQM mode query response (CSI $ p)"
```

---

### Task 4: Missing SGR and ESC Sequences

**Files:**
- Modify: `src/vt.zig` (handleSgr, handleEsc)

- [ ] **Step 1: Add SGR 21 (doubly-underlined) to handleSgr**

In `handleSgr`, add after the `9 =>` case:
```zig
            21 => term.current_attrs.underline = true, // Doubly-underlined (treated as underline)
```

- [ ] **Step 2: Add ESC n/o (LS2/LS3) to handleEsc**

In the no-intermediate switch of `handleEsc`, add:
```zig
        'n' => term.charset = 2, // LS2 — Locking Shift 2 (activate G2)
        'o' => term.charset = 3, // LS3 — Locking Shift 3 (activate G3)
```

- [ ] **Step 3: Add ESC F (cursor to lower-left)**

```zig
        'F' => { // Cursor to lower left corner
            term.cursor_x = 0;
            term.cursor_y = term.rows -| 1;
            term.wrap_next = false;
        },
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/vt.zig
git commit -m "feat: add SGR 21 (double underline), ESC n/o (LS2/LS3), ESC F"
```

---

### Task 5: XTVERSION and DECRQSS Responses

**Files:**
- Modify: `src/vt.zig` (handleCsi `q` case, handleDcsDispatch)

- [ ] **Step 1: Add XTVERSION response (CSI > 0 q)**

In the `'q'` case of handleCsi, add:
```zig
        'q' => {
            if (csi.intermediate_count > 0 and csi.intermediates[0] == ' ') {
                // DECSCUSR — Set Cursor Style
                term.cursor_style = if (pc > 0) @intCast(p[0]) else 0;
            } else if (csi.private_marker == '>' and pc > 0 and p[0] == 0) {
                // XTVERSION — respond with terminal name and version
                if (writer_fd) |fd| {
                    _ = std.posix.write(fd, "\x1bP>|zt(0.2.3)\x1b\\") catch {};
                }
            }
        },
```

- [ ] **Step 2: Add DECRQSS handler to DCS dispatch**

In `handleDcsDispatch`, add after the XTGETTCAP handler:
```zig
    // DECRQSS: DCS $ q Pt ST — Request Status String
    if (payload.len >= 2 and payload[0] == '$' and payload[1] == 'q') {
        const query = payload[2..];
        respondDecrqss(fd, query, term);
        return;
    }
```

Note: `handleDcsDispatch` needs `term` parameter now. Update its signature and call site.

Add the responder:
```zig
fn respondDecrqss(fd: std.posix.fd_t, query: []const u8, term: *const Term) void {
    if (std.mem.eql(u8, query, "m")) {
        // SGR state — respond with current attributes
        // Simplified: just report the basic state
        _ = std.posix.write(fd, "\x1bP1$r0m\x1b\\") catch {};
    } else if (std.mem.eql(u8, query, "r")) {
        // DECSTBM state
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1bP1$r{d};{d}r\x1b\\", .{ term.scroll_top + 1, term.scroll_bottom + 1 }) catch return;
        _ = std.posix.write(fd, resp) catch {};
    } else if (std.mem.eql(u8, query, " q")) {
        // DECSCUSR state
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrint(&buf, "\x1bP1$r{d} q\x1b\\", .{term.cursor_style}) catch return;
        _ = std.posix.write(fd, resp) catch {};
    } else {
        // Unknown — respond with invalid
        _ = std.posix.write(fd, "\x1bP0$r\x1b\\") catch {};
    }
}
```

- [ ] **Step 3: Update handleDcsDispatch signature**

Change signature to accept `term`:
```zig
fn handleDcsDispatch(payload: []const u8, writer_fd: ?std.posix.fd_t, term: *const Term) void {
```

Update call site in `executeActionWithFd`:
```zig
        .dcs_dispatch => |payload| handleDcsDispatch(payload, writer_fd, term),
```

- [ ] **Step 4: Run tests**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/vt.zig
git commit -m "feat: implement XTVERSION and DECRQSS responses"
```

---

### Task 6: DECSET ?67 (DECBKM) and Keypad Application Mode

**Files:**
- Modify: `src/term.zig` (add `decbkm` flag)
- Modify: `src/vt.zig` (DECSET handler)
- Modify: `src/input.zig` (backspace key handling, keypad app mode)

- [ ] **Step 1: Add decbkm flag to Term**

```zig
    // Backarrow key mode (DECSET ?67): true=BS(0x08), false=DEL(0x7F)
    decbkm: bool = false,
```

- [ ] **Step 2: Handle ?67 in DECSET**

In handleDecSet, add:
```zig
            67 => term.decbkm = set,
```

- [ ] **Step 3: Update input.zig for DECBKM**

In `src/input.zig`, find the backspace key handling (KEY_BACKSPACE) and make it check `decbkm`:

The translateKey function takes `decckm` — it now also needs `decbkm`. However, to minimize API changes, we can handle this in main.zig where the key event is processed. Find the backspace mapping in input.zig and note how it currently sends 0x7F.

In the special keys table in input.zig, backspace sends `"\x7f"`. We need to make this conditional. The simplest approach: add a `decbkm` parameter to `translateKey`, or handle it post-translation in main.zig.

For minimal changes, handle in main.zig after translateKey:
```zig
// In the key event handler, after getting bytes from translateKey:
if (bytes.len == 1 and bytes[0] == 0x7F and term.decbkm) {
    // DECBKM: backspace sends BS instead of DEL
    const bs = "\x08";
    if (!ptyBufferedWrite(&pty, bs, &write_buf, &write_pending, epoll_fd)) { ... }
} else {
    // normal path
}
```

- [ ] **Step 4: Run tests + build**

Run: `zig build test && zig build -Dbackend=x11`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/term.zig src/vt.zig src/main.zig
git commit -m "feat: implement DECBKM (?67) backspace key mode"
```

---

### Task 7: Tier 1 Integration Test + Version Bump

**Files:**
- Modify: `build.zig.zon` (version bump)
- Modify: `README.md` (update escape sequence tables)

- [ ] **Step 1: Run full test suite**

Run: `zig build test`
Expected: All pass

- [ ] **Step 2: Build and install**

Run: `zig build -Doptimize=ReleaseFast -Dbackend=x11`

- [ ] **Step 3: Update README escape sequence tables**

Add new features to the tables:
- OSC 0/2 (title), OSC 10-12 (color query), DECRQM, XTVERSION, DECRQSS, Focus events, DECBKM, SGR 21, ESC n/o/F

- [ ] **Step 4: Commit and tag v0.3.0**

```bash
git add -A
git commit -m "feat: Tier 1 xterm compat complete — OSC, focus, DECRQM, XTVERSION"
git tag v0.2.3
git push && git push --tags
```

---

## Chunk 2: Tier 2 — Spec Compliance

### Task 8: XTSAVE/XTRESTORE (CSI ? Ps s / CSI ? Ps r)

**Files:**
- Modify: `src/term.zig` (add saved mode values storage)
- Modify: `src/vt.zig` (handle `s`/`r` with `?` marker)

- [ ] **Step 1: Add saved mode storage to Term**

```zig
    // Saved DEC mode values (XTSAVE/XTRESTORE)
    saved_dec_modes: [32]struct { mode: u16 = 0, value: bool = false } = .{.{}} ** 32,
    saved_dec_mode_count: u8 = 0,
```

- [ ] **Step 2: Handle CSI ? Ps s in handleCsi 's' case**

Update the `'s'` case to check private_marker:
```zig
        's' => {
            if (csi.private_marker == '?') {
                // XTSAVE — Save DEC Private Mode values
                saveDECModes(csi, term);
            } else if (csi.private_marker == 0) {
                term.saved_cursor_x = term.cursor_x;
                term.saved_cursor_y = term.cursor_y;
            }
        },
```

- [ ] **Step 3: Handle CSI ? Ps r (XTRESTORE)**

Update the `'r'` case to check for private marker:
```zig
        'r' => {
            if (csi.private_marker == '?') {
                // XTRESTORE — Restore DEC Private Mode values
                restoreDECModes(csi, term);
            } else if (csi.private_marker == 0) {
                // DECSTBM (existing code)
                const top = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
                const bot = if (pc > 1 and p[1] > 0) p[1] - 1 else @as(u16, @intCast(term.rows -| 1));
                term.setScrollRegion(@intCast(top), @intCast(bot));
                term.cursor_x = 0;
                term.cursor_y = 0;
                term.wrap_next = false;
            }
        },
```

- [ ] **Step 4: Implement save/restore helper functions**

```zig
fn saveDECModes(csi: CsiAction, term: *Term) void {
    const p = csi.params;
    const pc = csi.param_count;
    term.saved_dec_mode_count = 0;
    var i: u8 = 0;
    while (i < pc and term.saved_dec_mode_count < 32) : (i += 1) {
        const mode = p[i];
        const value = queryDecMode(term, mode) == 1;
        term.saved_dec_modes[term.saved_dec_mode_count] = .{ .mode = mode, .value = value };
        term.saved_dec_mode_count += 1;
    }
}

fn restoreDECModes(csi: CsiAction, term: *Term) void {
    // Restore each saved mode
    for (0..term.saved_dec_mode_count) |idx| {
        const saved = term.saved_dec_modes[idx];
        // Re-use handleDecSet logic by constructing a synthetic CsiAction
        var restore_csi = CsiAction{};
        restore_csi.params[0] = saved.mode;
        restore_csi.param_count = 1;
        handleDecSet(restore_csi, term, saved.value);
    }
}
```

- [ ] **Step 5: Run tests + commit**

Run: `zig build test`
```bash
git add src/vt.zig src/term.zig
git commit -m "feat: implement XTSAVE/XTRESTORE (CSI ? s/r)"
```

---

### Task 9: Selective Erase (DECSED/DECSEL) and Character Protection

**Files:**
- Modify: `src/term.zig` (add protection attribute to Cell.Attrs)
- Modify: `src/vt.zig` (CSI ? J, CSI ? K, CSI " q)

- [ ] **Step 1: Add `protected` bit to Cell.Attrs**

In Cell.Attrs, replace `_pad: u6` with:
```zig
        protected: bool = false, // DECSCA character protection
        _pad: u5 = 0,
```

- [ ] **Step 2: Add DECSCA handler (CSI " q)**

In handleCsi, the `'q'` case already handles DECSCUSR (intermediate=' '). Add intermediate='"':
```zig
        'q' => {
            if (csi.intermediate_count > 0 and csi.intermediates[0] == ' ') {
                term.cursor_style = if (pc > 0) @intCast(p[0]) else 0;
            } else if (csi.intermediate_count > 0 and csi.intermediates[0] == '"') {
                // DECSCA — Set Character Protection Attribute
                const ps = if (pc > 0) p[0] else 0;
                term.current_attrs.protected = (ps == 1);
            } else if (csi.private_marker == '>' and pc > 0 and p[0] == 0) {
                // XTVERSION
                if (writer_fd) |fd| {
                    _ = std.posix.write(fd, "\x1bP>|zt(0.2.3)\x1b\\") catch {};
                }
            }
        },
```

- [ ] **Step 3: Add selective erase (CSI ? J and CSI ? K)**

These erase only cells that do NOT have the `protected` attribute set.

In the `'J'` case, add private marker handling:
```zig
        'J' => {
            if (csi.private_marker == '?') {
                // DECSED — Selective Erase in Display (respects DECSCA)
                const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
                term.selectiveEraseDisplay(mode);
            } else {
                const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
                term.eraseDisplay(mode);
            }
        },
        'K' => {
            if (csi.private_marker == '?') {
                // DECSEL — Selective Erase in Line
                const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
                term.selectiveEraseLine(mode);
            } else {
                const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
                term.eraseLine(mode);
            }
        },
```

- [ ] **Step 4: Implement selective erase in term.zig**

```zig
    /// Selective erase: only erase cells without protection attribute
    pub fn selectiveEraseDisplay(self: *Self, mode: u8) void {
        const cols: usize = self.cols;
        const blank = self.blankCell();
        switch (mode) {
            0 => { // Below
                for (self.cursor_y..self.rows) |y| {
                    const phys = self.row_map[y];
                    const from: usize = if (y == self.cursor_y) self.cursor_x else 0;
                    for (from..cols) |x| {
                        if (!self.cells[phys * cols + x].attrs.protected) {
                            self.cells[phys * cols + x] = blank;
                        }
                    }
                }
                self.markDirtyRange(.{ .start = @as(usize, self.cursor_y) * cols + self.cursor_x, .end = @as(usize, self.rows) * cols });
            },
            1 => { // Above
                for (0..self.cursor_y + 1) |y| {
                    const phys = self.row_map[y];
                    const to: usize = if (y == self.cursor_y) self.cursor_x + 1 else cols;
                    for (0..to) |x| {
                        if (!self.cells[phys * cols + x].attrs.protected) {
                            self.cells[phys * cols + x] = blank;
                        }
                    }
                }
                self.markDirtyRange(.{ .start = 0, .end = @as(usize, self.cursor_y) * cols + self.cursor_x + 1 });
            },
            2 => { // All
                for (0..self.rows) |y| {
                    const phys = self.row_map[y];
                    for (0..cols) |x| {
                        if (!self.cells[phys * cols + x].attrs.protected) {
                            self.cells[phys * cols + x] = blank;
                        }
                    }
                }
                const total = @as(usize, self.cols) * @as(usize, self.rows);
                self.markDirtyRange(.{ .start = 0, .end = total });
            },
            else => {},
        }
    }

    pub fn selectiveEraseLine(self: *Self, mode: u8) void {
        const cols: usize = self.cols;
        const phys = self.row_map[self.cursor_y];
        const blank = self.blankCell();
        const row_start = @as(usize, self.cursor_y) * cols;
        switch (mode) {
            0 => {
                for (self.cursor_x..self.cols) |x| {
                    if (!self.cells[phys * cols + x].attrs.protected) {
                        self.cells[phys * cols + x] = blank;
                    }
                }
                self.markDirtyRange(.{ .start = row_start + self.cursor_x, .end = row_start + cols });
            },
            1 => {
                for (0..self.cursor_x + 1) |x| {
                    if (!self.cells[phys * cols + x].attrs.protected) {
                        self.cells[phys * cols + x] = blank;
                    }
                }
                self.markDirtyRange(.{ .start = row_start, .end = row_start + self.cursor_x + 1 });
            },
            2 => {
                for (0..cols) |x| {
                    if (!self.cells[phys * cols + x].attrs.protected) {
                        self.cells[phys * cols + x] = blank;
                    }
                }
                self.markDirtyRange(.{ .start = row_start, .end = row_start + cols });
            },
            else => {},
        }
    }
```

- [ ] **Step 5: Run tests + commit**

Run: `zig build test`
```bash
git add src/vt.zig src/term.zig
git commit -m "feat: implement DECSCA, DECSED, DECSEL (selective erase with protection)"
```

---

### Task 10: Remaining Tier 2 (ESC %, CSI " p, CSI i, ?45)

**Files:**
- Modify: `src/vt.zig`

- [ ] **Step 1: Add ESC % G / ESC % @ (UTF-8 charset)**

In handleEsc's intermediate `%` case (via the intermediate switch):
```zig
            '%' => {
                // ESC % G = UTF-8 mode, ESC % @ = ISO 8859-1
                // We always operate in UTF-8, silently accept
            },
```

- [ ] **Step 2: Add CSI " p (DECSCL)**

In handleCsi `'p'` case, add intermediate `"`:
```zig
            } else if (csi.intermediate_count > 0 and csi.intermediates[0] == '"') {
                // DECSCL — Set Conformance Level (silently accept, we're always VT220+)
            }
```

- [ ] **Step 3: Add CSI i (MC — Media Copy)**

```zig
        'i' => {
            // MC — Media Copy (printer control)
            // Silently accept — no printer support
        },
```

- [ ] **Step 4: Add ?45 (XTREVWRAP) to DECSET**

```zig
            45 => {}, // XTREVWRAP — reverse-wraparound (silently accept)
```

- [ ] **Step 5: Run tests + commit**

Run: `zig build test`
```bash
git add src/vt.zig
git commit -m "feat: add ESC %, DECSCL, MC, XTREVWRAP for Tier 2 compliance"
```

---

### Task 11: Tier 2 Finalize + v0.2.4

- [ ] **Step 1: Run full test suite**
- [ ] **Step 2: Update README**
- [ ] **Step 3: Commit, tag v0.2.4, push**

---

## Chunk 3: Tier 3 — Niche Features (Differentiation)

### Task 12: VT52 Mode

**Files:**
- Modify: `src/vt.zig` (add VT52 parser state + executor)
- Modify: `src/term.zig` (add `vt52_mode` flag)

VT52 mode is entered via `CSI ? 2 l` (DECANM reset). In VT52, all commands are `ESC` + single byte. Exit via `ESC <`.

- [ ] **Step 1: Add vt52_mode flag to Term**

```zig
    vt52_mode: bool = false,
```

- [ ] **Step 2: Add VT52 state to Parser**

Add a new state `vt52_esc` to the State enum:
```zig
    vt52_esc, // ESC received in VT52 mode
```

- [ ] **Step 3: Handle DECANM (?2) in DECSET**

```zig
            2 => {
                if (!set) term.vt52_mode = true; // DECANM reset → enter VT52
                // set: exit VT52 (handled by ESC <)
            },
```

- [ ] **Step 4: Add VT52 dispatch to feedBulk**

In `feedBulk`, before the normal parser path, add:
```zig
        // VT52 mode: simplified parser
        if (term.vt52_mode) {
            handleVt52Byte(data[i], term, parser, writer_fd);
            i += 1;
            continue;
        }
```

- [ ] **Step 5: Implement VT52 handler**

```zig
fn handleVt52Byte(byte: u8, term: *Term, parser: *Parser, writer_fd: ?std.posix.fd_t) void {
    if (parser.state == .vt52_esc) {
        parser.state = .ground;
        switch (byte) {
            'A' => { if (term.cursor_y > 0) term.cursor_y -= 1; },
            'B' => { if (term.cursor_y < term.rows - 1) term.cursor_y += 1; },
            'C' => { if (term.cursor_x < term.cols - 1) term.cursor_x += 1; },
            'D' => { if (term.cursor_x > 0) term.cursor_x -= 1; },
            'F' => term.charsets[0] = .dec_graphics,
            'G' => term.charsets[0] = .us_ascii,
            'H' => { term.cursor_x = 0; term.cursor_y = 0; },
            'I' => { // Reverse LF
                if (term.cursor_y == term.scroll_top) term.scrollDown(1)
                else if (term.cursor_y > 0) term.cursor_y -= 1;
            },
            'J' => term.eraseDisplay(0),
            'K' => term.eraseLine(0),
            'Y' => { parser.state = .vt52_esc; /* need 2 more bytes — simplified: use params */ },
            'Z' => { // Identify
                if (writer_fd) |fd| _ = std.posix.write(fd, "\x1b/Z") catch {};
            },
            '<' => { term.vt52_mode = false; }, // Exit VT52, enter VT100
            '=' => term.deckpam = true,
            '>' => term.deckpam = false,
            else => {},
        }
        return;
    }
    if (byte == 0x1B) {
        parser.state = .vt52_esc;
        return;
    }
    // Normal printing / control chars
    if (byte <= 0x1F) {
        handleControl(byte, term);
    } else if (byte <= 0x7E) {
        handlePrint(@as(u21, byte), term);
    }
}
```

Note: VT52 `ESC Y row col` (cursor addressing) needs two more bytes. For simplicity, we can handle this as a 3-byte sequence using parser state. This can be refined later.

- [ ] **Step 6: Run tests + commit**

```bash
git add src/vt.zig src/term.zig
git commit -m "feat: implement VT52 compatibility mode (DECANM)"
```

---

### Task 13: Tektronix 4014 Mode (Stub)

This is extremely niche. For now, add the DECSET ?38 handler that acknowledges the mode switch but stays in VT mode, and silently consume any Tek commands.

- [ ] **Step 1: Add ?38 to DECSET as no-op**

```zig
            38 => {}, // DECTEK — Tektronix mode (not implemented, silently ignore)
```

- [ ] **Step 2: Commit**

```bash
git commit -m "feat: acknowledge Tektronix mode request (DECSET ?38, no-op)"
```

---

### Task 14: Tier 3 Finalize + v0.2.5

- [ ] **Step 1: Full test suite**
- [ ] **Step 2: Update README with VT52 mode**
- [ ] **Step 3: Version bump to v0.2.5**
- [ ] **Step 4: Commit, tag, push**

---

## Appendix: Files Modified Per Task

| Task | vt.zig | term.zig | main.zig | input.zig | x11.zig | README |
|------|--------|----------|----------|-----------|---------|--------|
| 1 OSC | ✓ | ✓ | | | | |
| 2 Focus | ✓ | ✓ | ✓ | | ✓ | |
| 3 DECRQM | ✓ | | | | | |
| 4 SGR/ESC | ✓ | | | | | |
| 5 XTVERSION | ✓ | | | | | |
| 6 DECBKM | ✓ | ✓ | ✓ | | | |
| 7 Tier1 final | | | | | | ✓ |
| 8 XTSAVE | ✓ | ✓ | | | | |
| 9 DECSED | ✓ | ✓ | | | | |
| 10 Tier2 misc | ✓ | | | | | |
| 11 Tier2 final | | | | | | ✓ |
| 12 VT52 | ✓ | ✓ | | | | |
| 13 Tek stub | ✓ | | | | | |
| 14 Tier3 final | | | | | | ✓ |
