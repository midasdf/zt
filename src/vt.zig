const std = @import("std");
const term_mod = @import("term.zig");
const Term = term_mod.Term;
const Cell = term_mod.Cell;
const testing = std.testing;

// =============================================================================
// VT Parser Types
// =============================================================================

pub const CsiAction = struct {
    params: [16]u16 = [_]u16{0} ** 16,
    param_count: u8 = 0,
    intermediates: [2]u8 = [_]u8{0} ** 2,
    intermediate_count: u8 = 0,
    final_byte: u8 = 0,
    private_marker: u8 = 0, // '?' or '>' or 0
};

pub const EscAction = struct {
    intermediate: u8 = 0,
    final_byte: u8 = 0,
};

pub const Action = union(enum) {
    print: u21,
    execute: u8,
    csi_dispatch: CsiAction,
    esc_dispatch: EscAction,
    osc_dispatch: []const u8,
    none,
};

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    dcs_entry,
    dcs_param,
    dcs_passthrough,
    utf8,
};

// =============================================================================
// VT Parser
// =============================================================================

pub const Parser = struct {
    state: State = .ground,
    // CSI accumulators
    params: [16]u16 = [_]u16{0} ** 16,
    param_count: u8 = 0,
    intermediates: [2]u8 = [_]u8{0} ** 2,
    intermediate_count: u8 = 0,
    private_marker: u8 = 0,
    // UTF-8 accumulator
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,
    // OSC accumulator
    osc_buf: [256]u8 = undefined,
    osc_len: u16 = 0,
    // ESC in OSC tracking
    esc_in_osc: bool = false,

    pub fn feed(self: *Parser, byte: u8) Action {
        return switch (self.state) {
            .ground => self.handleGround(byte),
            .utf8 => self.handleUtf8(byte),
            .escape => self.handleEscape(byte),
            .escape_intermediate => self.handleEscapeIntermediate(byte),
            .csi_entry => self.handleCsiEntry(byte),
            .csi_param => self.handleCsiParam(byte),
            .csi_intermediate => self.handleCsiIntermediate(byte),
            .csi_ignore => self.handleCsiIgnore(byte),
            .osc_string => self.handleOscString(byte),
            .dcs_entry, .dcs_param, .dcs_passthrough => self.handleDcs(byte),
        };
    }

    fn handleGround(self: *Parser, byte: u8) Action {
        if (byte <= 0x1F) {
            // C0 controls
            if (byte == 0x1B) {
                self.state = .escape;
                return .none;
            }
            return Action{ .execute = byte };
        } else if (byte <= 0x7E) {
            // Printable ASCII
            return Action{ .print = @as(u21, byte) };
        } else if (byte >= 0xC0 and byte <= 0xDF) {
            // 2-byte UTF-8
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 2;
            self.state = .utf8;
            return .none;
        } else if (byte >= 0xE0 and byte <= 0xEF) {
            // 3-byte UTF-8
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 3;
            self.state = .utf8;
            return .none;
        } else if (byte >= 0xF0 and byte <= 0xF7) {
            // 4-byte UTF-8
            self.utf8_buf[0] = byte;
            self.utf8_len = 1;
            self.utf8_expected = 4;
            self.state = .utf8;
            return .none;
        } else {
            // 0x7F (DEL) or invalid lead bytes — ignore
            return .none;
        }
    }

    fn handleUtf8(self: *Parser, byte: u8) Action {
        if (byte >= 0x80 and byte <= 0xBF) {
            // Valid continuation byte
            self.utf8_buf[self.utf8_len] = byte;
            self.utf8_len += 1;
            if (self.utf8_len == self.utf8_expected) {
                // Decode complete sequence
                const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                self.state = .ground;
                return Action{ .print = cp };
            }
            return .none;
        } else {
            // Invalid continuation — reprocess byte in ground state.
            // If the byte produces an action, return it (sacrificing the
            // replacement char). Otherwise return U+FFFD replacement.
            self.state = .ground;
            const ground_action = self.handleGround(byte);
            return switch (ground_action) {
                .none => Action{ .print = 0xFFFD },
                else => ground_action,
            };
        }
    }

    fn decodeUtf8(bytes: []const u8) u21 {
        switch (bytes.len) {
            2 => {
                const b0 = @as(u21, bytes[0] & 0x1F);
                const b1 = @as(u21, bytes[1] & 0x3F);
                return (b0 << 6) | b1;
            },
            3 => {
                const b0 = @as(u21, bytes[0] & 0x0F);
                const b1 = @as(u21, bytes[1] & 0x3F);
                const b2 = @as(u21, bytes[2] & 0x3F);
                return (b0 << 12) | (b1 << 6) | b2;
            },
            4 => {
                const b0 = @as(u21, bytes[0] & 0x07);
                const b1 = @as(u21, bytes[1] & 0x3F);
                const b2 = @as(u21, bytes[2] & 0x3F);
                const b3 = @as(u21, bytes[3] & 0x3F);
                return (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;
            },
            else => return 0xFFFD,
        }
    }

    fn handleEscape(self: *Parser, byte: u8) Action {
        if (byte == '[') {
            self.clearCsi();
            self.state = .csi_entry;
            return .none;
        } else if (byte == ']') {
            self.osc_len = 0;
            self.esc_in_osc = false;
            self.state = .osc_string;
            return .none;
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediates[0] = byte;
            self.intermediate_count = 1;
            self.state = .escape_intermediate;
            return .none;
        } else if (byte >= 0x30 and byte <= 0x7E) {
            self.state = .ground;
            return Action{ .esc_dispatch = .{ .intermediate = 0, .final_byte = byte } };
        } else if (byte == 0x1B) {
            // ESC ESC — stay in escape, reset
            return .none;
        } else {
            self.state = .ground;
            return .none;
        }
    }

    fn handleEscapeIntermediate(self: *Parser, byte: u8) Action {
        if (byte >= 0x20 and byte <= 0x2F) {
            // Accumulate intermediate (ignore overflow)
            if (self.intermediate_count < 2) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return .none;
        } else if (byte >= 0x30 and byte <= 0x7E) {
            self.state = .ground;
            return Action{ .esc_dispatch = .{
                .intermediate = self.intermediates[0],
                .final_byte = byte,
            } };
        } else {
            self.state = .ground;
            return .none;
        }
    }

    fn handleCsiEntry(self: *Parser, byte: u8) Action {
        if (byte == '?' or byte == '>') {
            self.private_marker = byte;
            self.state = .csi_param;
            return .none;
        } else if (byte >= '0' and byte <= '9') {
            self.params[0] = byte - '0';
            self.state = .csi_param;
            return .none;
        } else if (byte == ';') {
            self.param_count = 1; // first param is default 0
            self.state = .csi_param;
            return .none;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            // Final byte with no params
            self.state = .ground;
            return Action{ .csi_dispatch = self.buildCsiAction(byte) };
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediates[0] = byte;
            self.intermediate_count = 1;
            self.state = .csi_intermediate;
            return .none;
        } else {
            return .none;
        }
    }

    fn handleCsiParam(self: *Parser, byte: u8) Action {
        if (byte >= '0' and byte <= '9') {
            // Accumulate digit
            const idx = self.param_count;
            if (idx < 16) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            }
            return .none;
        } else if (byte == ';') {
            // Next param
            if (self.param_count < 15) {
                self.param_count += 1;
            }
            return .none;
        } else if (byte >= 0x20 and byte <= 0x2F) {
            self.intermediates[0] = byte;
            self.intermediate_count = 1;
            self.state = .csi_intermediate;
            return .none;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            // Final byte — finalize param_count
            self.param_count += 1;
            self.state = .ground;
            return Action{ .csi_dispatch = self.buildCsiAction(byte) };
        } else if (byte == 0x3A or (byte >= 0x3C and byte <= 0x3F)) {
            // Malformed
            self.state = .csi_ignore;
            return .none;
        } else {
            return .none;
        }
    }

    fn handleCsiIntermediate(self: *Parser, byte: u8) Action {
        if (byte >= 0x20 and byte <= 0x2F) {
            if (self.intermediate_count < 2) {
                self.intermediates[self.intermediate_count] = byte;
                self.intermediate_count += 1;
            }
            return .none;
        } else if (byte >= 0x40 and byte <= 0x7E) {
            self.state = .ground;
            return Action{ .csi_dispatch = self.buildCsiAction(byte) };
        } else {
            self.state = .csi_ignore;
            return .none;
        }
    }

    fn handleCsiIgnore(self: *Parser, byte: u8) Action {
        if (byte >= 0x40 and byte <= 0x7E) {
            self.state = .ground;
        }
        return .none;
    }

    fn handleOscString(self: *Parser, byte: u8) Action {
        if (self.esc_in_osc) {
            self.esc_in_osc = false;
            if (byte == '\\') {
                // ST (ESC \) — dispatch OSC
                self.state = .ground;
                return Action{ .osc_dispatch = self.osc_buf[0..self.osc_len] };
            }
            // Not ST, store the ESC and this byte
            if (self.osc_len < 256) {
                self.osc_buf[self.osc_len] = 0x1B;
                self.osc_len += 1;
            }
            if (self.osc_len < 256) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
            return .none;
        }

        if (byte == 0x07) {
            // BEL terminates OSC
            self.state = .ground;
            return Action{ .osc_dispatch = self.osc_buf[0..self.osc_len] };
        } else if (byte == 0x9C) {
            // ST (8-bit)
            self.state = .ground;
            return Action{ .osc_dispatch = self.osc_buf[0..self.osc_len] };
        } else if (byte == 0x1B) {
            // Could be start of ST (ESC \)
            self.esc_in_osc = true;
            return .none;
        } else {
            if (self.osc_len < 256) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
            return .none;
        }
    }

    fn handleDcs(self: *Parser, byte: u8) Action {
        // Minimal DCS handling — just consume until ST
        if (byte == 0x9C) {
            self.state = .ground;
        } else if (byte == 0x1B) {
            // Could be ESC \ (ST)
            self.state = .escape;
        }
        return .none;
    }

    fn clearCsi(self: *Parser) void {
        self.params = [_]u16{0} ** 16;
        self.param_count = 0;
        self.intermediates = [_]u8{0} ** 2;
        self.intermediate_count = 0;
        self.private_marker = 0;
    }

    fn buildCsiAction(self: *const Parser, final_byte: u8) CsiAction {
        return CsiAction{
            .params = self.params,
            .param_count = self.param_count,
            .intermediates = self.intermediates,
            .intermediate_count = self.intermediate_count,
            .final_byte = final_byte,
            .private_marker = self.private_marker,
        };
    }
};

// =============================================================================
// Action Executor
// =============================================================================

/// Bulk-feed a data buffer, using a fast path for contiguous printable ASCII
/// in ground state (bypasses Action union overhead).
pub fn feedBulk(parser: *Parser, data: []const u8, term: *Term, writer_fd: ?std.posix.fd_t) void {
    var i: usize = 0;
    while (i < data.len) {
        // Fast path: ground state + printable ASCII run
        if (parser.state == .ground and data[i] >= 0x20 and data[i] <= 0x7E) {
            const start = i;
            while (i < data.len and data[i] >= 0x20 and data[i] <= 0x7E) : (i += 1) {}
            // Bulk print — all ASCII, never wide, bypass Action union
            for (data[start..i]) |byte| {
                handlePrint(@as(u21, byte), term);
            }
            continue;
        }
        // Slow path: control/escape sequences, UTF-8
        const action = parser.feed(data[i]);
        executeActionWithFd(action, term, writer_fd);
        i += 1;
    }
}

pub fn executeAction(action: Action, term: *Term) void {
    executeActionWithFd(action, term, null);
}

pub fn executeActionWithFd(action: Action, term: *Term, writer_fd: ?std.posix.fd_t) void {
    switch (action) {
        .print => |cp| handlePrint(cp, term),
        .execute => |c| handleControl(c, term),
        .csi_dispatch => |csi| handleCsi(csi, term, writer_fd),
        .esc_dispatch => |esc| handleEsc(esc, term),
        .osc_dispatch => {},
        .none => {},
    }
}

fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK Radicals, Kangxi, Ideographic Description
        (cp >= 0x3040 and cp <= 0x33BF) or // Hiragana, Katakana, Bopomofo, CJK compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Unified Extension A
        (cp >= 0x4E00 and cp <= 0xA4CF) or // CJK Unified, Yi
        (cp >= 0xA960 and cp <= 0xA97C) or // Hangul Jamo Extended-A
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE10 and cp <= 0xFE6F) or // CJK Compatibility Forms, Small Forms
        (cp >= 0xFF01 and cp <= 0xFF60) or // Fullwidth Forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // Fullwidth Signs
        (cp >= 0x1F300 and cp <= 0x1F9FF) or // Misc Symbols, Emoticons
        (cp >= 0x20000 and cp <= 0x2FFFF) or // CJK Extension B-F
        (cp >= 0x30000 and cp <= 0x3FFFF); // CJK Extension G+
}

fn handlePrint(cp: u21, term: *Term) void {
    const wide = isWide(cp);

    if (term.cursor_x >= term.cols) {
        if (term.decawm) {
            term.cursor_x = 0;
            term.insertNewline();
        } else {
            term.cursor_x = term.cols - 1;
        }
    }

    // Wide char needs 2 columns — wrap if at last column
    if (wide and term.cursor_x + 1 >= term.cols) {
        if (term.decawm) {
            term.setCell(term.cursor_x, term.cursor_y, Cell{});
            term.cursor_x = 0;
            term.insertNewline();
        }
    }

    // Clear any existing wide char pair we're overwriting
    if (term.cursor_x < term.cols and term.cursor_y < term.rows) {
        const existing = term.getCell(term.cursor_x, term.cursor_y);
        if (existing.attrs.wide_dummy and term.cursor_x > 0) {
            term.setCell(term.cursor_x - 1, term.cursor_y, Cell{});
        } else if (existing.attrs.wide and term.cursor_x + 1 < term.cols) {
            term.setCell(term.cursor_x + 1, term.cursor_y, Cell{});
        }
    }

    var attrs = term.current_attrs;
    if (wide) attrs.wide = true;

    const cell = Cell{
        .char = cp,
        .fg = term.current_fg,
        .bg = term.current_bg,
        .attrs = attrs,
    };
    term.setCell(term.cursor_x, term.cursor_y, cell);

    // Store TrueColor RGB if set
    if (term.current_fg_rgb) |rgb| {
        term.setFgRgb(term.cursor_x, term.cursor_y, rgb) catch {};
    }
    if (term.current_bg_rgb) |rgb| {
        term.setBgRgb(term.cursor_x, term.cursor_y, rgb) catch {};
    }

    term.cursor_x += 1;

    // Wide char: set dummy cell for right half
    if (wide and term.cursor_x < term.cols) {
        var dummy = Cell{ .bg = term.current_bg };
        dummy.attrs.wide_dummy = true;
        term.setCell(term.cursor_x, term.cursor_y, dummy);
        term.cursor_x += 1;
    }
}

fn handleControl(c: u8, term: *Term) void {
    switch (c) {
        0x0A, 0x0B, 0x0C => term.insertNewline(), // LF, VT, FF
        0x0D => term.carriageReturn(), // CR
        0x08 => { // BS
            if (term.cursor_x > 0) term.cursor_x -= 1;
        },
        0x09 => { // HT — advance to next tab stop (every 8 columns)
            term.cursor_x = @min(((term.cursor_x / 8) + 1) * 8, term.cols -| 1);
        },
        0x07 => {}, // BEL — ignore
        else => {},
    }
}

fn handleCsi(csi: CsiAction, term: *Term, writer_fd: ?std.posix.fd_t) void {
    const p = csi.params;
    const pc = csi.param_count;

    switch (csi.final_byte) {
        'A' => { // CUU — cursor up
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.moveCursorRel(0, -@as(i32, @intCast(n)));
        },
        'B' => { // CUD — cursor down
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.moveCursorRel(0, @as(i32, @intCast(n)));
        },
        'C' => { // CUF — cursor forward
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.moveCursorRel(@as(i32, @intCast(n)), 0);
        },
        'D' => { // CUB — cursor back
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.moveCursorRel(-@as(i32, @intCast(n)), 0);
        },
        'E' => { // CNL — cursor next line
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.moveCursorRel(0, @as(i32, @intCast(n)));
            term.cursor_x = 0;
        },
        'F' => { // CPL — cursor preceding line
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.moveCursorRel(0, -@as(i32, @intCast(n)));
            term.cursor_x = 0;
        },
        'G' => { // CHA — cursor horizontal absolute (1-indexed)
            const col = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            term.cursor_x = @min(@as(u32, @intCast(col)), term.cols -| 1);
        },
        'H', 'f' => { // CUP — cursor position (1-indexed params)
            const row = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            const col = if (pc > 1 and p[1] > 0) p[1] - 1 else 0;
            term.moveCursorTo(@intCast(col), @intCast(row));
        },
        'J' => { // ED — erase display
            const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
            term.eraseDisplay(mode);
        },
        'K' => { // EL — erase line
            const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
            term.eraseLine(mode);
        },
        'L' => { // IL — insert lines
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.insertLines(@intCast(n));
        },
        'M' => { // DL — delete lines
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.deleteLines(@intCast(n));
        },
        'P' => { // DCH — delete characters
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.deleteChars(@intCast(n));
        },
        'X' => { // ECH — erase characters
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.eraseChars(@intCast(n));
        },
        '@' => { // ICH — insert characters
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.insertChars(@intCast(n));
        },
        'd' => { // VPA — vertical position absolute (1-indexed)
            const row = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            term.cursor_y = @min(@as(u32, @intCast(row)), term.rows -| 1);
        },
        'm' => handleSgr(csi, term), // SGR
        'c' => { // DA1 — device attributes
            if (csi.private_marker == 0) {
                if (writer_fd) |fd| {
                    // Report as VT220 with basic capabilities
                    _ = std.posix.write(fd, "\x1b[?62;22c") catch {};
                }
            }
        },
        'n' => { // DSR — device status report
            if (csi.private_marker == 0 and pc > 0 and p[0] == 6) {
                if (writer_fd) |fd| {
                    var buf: [32]u8 = undefined;
                    const response = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ term.cursor_y + 1, term.cursor_x + 1 }) catch return;
                    _ = std.posix.write(fd, response) catch {};
                }
            }
        },
        'S' => { // SU — scroll up
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.scrollUp(@intCast(n));
        },
        'T' => { // SD — scroll down
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.scrollDown(@intCast(n));
        },
        'r' => { // DECSTBM — set scroll region (1-indexed)
            const top = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            const bot = if (pc > 1 and p[1] > 0) p[1] - 1 else @as(u16, @intCast(term.rows -| 1));
            term.setScrollRegion(@intCast(top), @intCast(bot));
        },
        's' => { // Save cursor
            term.saved_cursor_x = term.cursor_x;
            term.saved_cursor_y = term.cursor_y;
        },
        'u' => { // Restore cursor
            term.cursor_x = term.saved_cursor_x;
            term.cursor_y = term.saved_cursor_y;
        },
        'h' => { // DECSET
            if (csi.private_marker == '?') handleDecSet(csi, term, true);
        },
        'l' => { // DECRST
            if (csi.private_marker == '?') handleDecSet(csi, term, false);
        },
        else => {},
    }
}

fn handleSgr(csi: CsiAction, term: *Term) void {
    const p = csi.params;
    const pc = csi.param_count;

    if (pc == 0) {
        // ESC[m with no params = reset
        resetSgr(term);
        return;
    }

    var i: u8 = 0;
    while (i < pc) : (i += 1) {
        const param = p[i];
        switch (param) {
            0 => resetSgr(term),
            1 => term.current_attrs.bold = true,
            2 => term.current_attrs.dim = true,
            3 => term.current_attrs.italic = true,
            4 => term.current_attrs.underline = true,
            7 => term.current_attrs.reverse = true,
            22 => {
                term.current_attrs.bold = false;
                term.current_attrs.dim = false;
            },
            23 => term.current_attrs.italic = false,
            24 => term.current_attrs.underline = false,
            27 => term.current_attrs.reverse = false,
            30...37 => term.current_fg = @intCast(param - 30),
            38 => {
                // Extended foreground
                i = parseExtendedColor(p, pc, i, term, true);
            },
            39 => {
                term.current_fg = 7;
                term.current_fg_rgb = null;
            },
            40...47 => term.current_bg = @intCast(param - 40),
            48 => {
                // Extended background
                i = parseExtendedColor(p, pc, i, term, false);
            },
            49 => {
                term.current_bg = 0;
                term.current_bg_rgb = null;
            },
            90...97 => term.current_fg = @intCast(param - 90 + 8),
            100...107 => term.current_bg = @intCast(param - 100 + 8),
            else => {},
        }
    }
}

fn parseExtendedColor(p: [16]u16, pc: u8, start: u8, term: *Term, is_fg: bool) u8 {
    const i = start;
    if (i + 1 < pc) {
        const sub = p[i + 1];
        if (sub == 5 and i + 2 < pc) {
            // 256-color: 38;5;n or 48;5;n
            const color: u8 = @intCast(p[i + 2]);
            if (is_fg) {
                term.current_fg = color;
                term.current_fg_rgb = null;
            } else {
                term.current_bg = color;
                term.current_bg_rgb = null;
            }
            return i + 2;
        } else if (sub == 2 and i + 4 < pc) {
            // TrueColor: 38;2;r;g;b or 48;2;r;g;b
            const r: u8 = @intCast(p[i + 2]);
            const g: u8 = @intCast(p[i + 3]);
            const b: u8 = @intCast(p[i + 4]);
            if (is_fg) {
                term.current_fg_rgb = .{ r, g, b };
            } else {
                term.current_bg_rgb = .{ r, g, b };
            }
            return i + 4;
        }
    }
    return i;
}

fn resetSgr(term: *Term) void {
    term.current_fg = 7;
    term.current_bg = 0;
    term.current_attrs = .{};
    term.current_fg_rgb = null;
    term.current_bg_rgb = null;
}

fn handleDecSet(csi: CsiAction, term: *Term, set: bool) void {
    const p = csi.params;
    const pc = csi.param_count;

    var i: u8 = 0;
    while (i < pc) : (i += 1) {
        switch (p[i]) {
            1 => term.decckm = set,
            7 => term.decawm = set,
            25 => term.cursor_visible = set,
            47, 1047 => {
                term.switchScreen(set) catch |err| {
                    std.log.err("switchScreen failed: {}", .{err});
                };
            },
            1049 => {
                if (set) {
                    term.saved_cursor_x = term.cursor_x;
                    term.saved_cursor_y = term.cursor_y;
                    term.switchScreen(true) catch |err| {
                        std.log.err("switchScreen failed: {}", .{err});
                    };
                    term.eraseDisplay(2);
                } else {
                    term.switchScreen(false) catch |err| {
                        std.log.err("switchScreen failed: {}", .{err});
                    };
                    term.cursor_x = term.saved_cursor_x;
                    term.cursor_y = term.saved_cursor_y;
                }
            },
            2004 => term.bracketed_paste = set,
            else => {},
        }
    }
}

fn handleEsc(esc: EscAction, term: *Term) void {
    switch (esc.final_byte) {
        '7' => { // DECSC — save cursor
            term.saved_cursor_x = term.cursor_x;
            term.saved_cursor_y = term.cursor_y;
        },
        '8' => { // DECRC — restore cursor
            term.cursor_x = term.saved_cursor_x;
            term.cursor_y = term.saved_cursor_y;
        },
        'D' => { // IND — index (cursor down, scroll if at bottom of scroll region)
            if (term.cursor_y == term.scroll_bottom) {
                term.scrollUp(1);
            } else if (term.cursor_y < term.rows - 1) {
                term.cursor_y += 1;
            }
        },
        'M' => { // RI — reverse index
            if (term.cursor_y == term.scroll_top) {
                term.scrollDown(1);
            } else if (term.cursor_y > 0) {
                term.cursor_y -= 1;
            }
        },
        'c' => { // RIS — full reset
            term.cursor_x = 0;
            term.cursor_y = 0;
            term.saved_cursor_x = 0;
            term.saved_cursor_y = 0;
            term.scroll_top = 0;
            term.scroll_bottom = term.rows -| 1;
            term.current_fg = 7;
            term.current_bg = 0;
            term.current_attrs = .{};
            term.current_fg_rgb = null;
            term.current_bg_rgb = null;
            term.decckm = false;
            term.decawm = true;
            term.cursor_visible = true;
            term.bracketed_paste = false;
            term.eraseDisplay(2);
        },
        else => {},
    }
}

// =============================================================================
// Parser Tests
// =============================================================================

test "VT: plain ASCII produces print actions" {
    var p = Parser{};
    const action = p.feed('A');
    try testing.expectEqual(Action{ .print = 'A' }, action);
}

test "VT: LF produces execute action" {
    var p = Parser{};
    const action = p.feed(0x0A);
    try testing.expectEqual(Action{ .execute = 0x0A }, action);
}

test "VT: CSI cursor up (ESC [ 5 A)" {
    var p = Parser{};
    _ = p.feed(0x1B);
    _ = p.feed('[');
    _ = p.feed('5');
    const action = p.feed('A');
    switch (action) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'A'), csi.final_byte);
            try testing.expectEqual(@as(u16, 5), csi.params[0]);
            try testing.expectEqual(@as(u8, 1), csi.param_count);
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: SGR with multiple params (ESC [ 1 ; 31 m)" {
    var p = Parser{};
    var last_action: Action = .none;
    for ("\x1b[1;31m") |byte| {
        last_action = p.feed(byte);
    }
    switch (last_action) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'm'), csi.final_byte);
            try testing.expectEqual(@as(u8, 2), csi.param_count);
            try testing.expectEqual(@as(u16, 1), csi.params[0]);
            try testing.expectEqual(@as(u16, 31), csi.params[1]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: DEC private mode (ESC [ ? 1049 h)" {
    var p = Parser{};
    var last: Action = .none;
    for ("\x1b[?1049h") |byte| {
        last = p.feed(byte);
    }
    switch (last) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'h'), csi.final_byte);
            try testing.expectEqual(@as(u8, '?'), csi.private_marker);
            try testing.expectEqual(@as(u16, 1049), csi.params[0]);
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: UTF-8 multibyte (a = E3 81 82)" {
    var p = Parser{};
    try testing.expectEqual(Action.none, p.feed(0xE3));
    try testing.expectEqual(Action.none, p.feed(0x81));
    const action = p.feed(0x82);
    switch (action) {
        .print => |cp| try testing.expectEqual(@as(u21, 0x3042), cp),
        else => return error.TestExpectedEqual,
    }
}

test "VT: CSI with no params defaults" {
    var p = Parser{};
    var last: Action = .none;
    for ("\x1b[H") |byte| {
        last = p.feed(byte);
    }
    switch (last) {
        .csi_dispatch => |csi| {
            try testing.expectEqual(@as(u8, 'H'), csi.final_byte);
            // No params means param_count=0
        },
        else => return error.TestExpectedEqual,
    }
}

test "VT: malformed CSI goes to csi_ignore" {
    var p = Parser{};
    // ESC [ ? 1 < (< is invalid in CSI param) should end up in csi_ignore
    for ("\x1b[?1<") |byte| {
        _ = p.feed(byte);
    }
    try testing.expectEqual(State.csi_ignore, p.state);
    // Then a final byte should bring us back to ground
    _ = p.feed('m');
    try testing.expectEqual(State.ground, p.state);
}

// =============================================================================
// Executor Tests
// =============================================================================

test "Executor: print 'Hello' fills cells" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("Hello") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    try testing.expectEqual(@as(u21, 'H'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, 'o'), term.getCell(4, 0).char);
    try testing.expectEqual(@as(u32, 5), term.cursor_x);
}

test "Executor: SGR sets colors" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b[31mX") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    try testing.expectEqual(@as(u8, 1), term.getCell(0, 0).fg);
}

test "Executor: CUP moves cursor" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b[5;10H") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    try testing.expectEqual(@as(u32, 9), term.cursor_x);
    try testing.expectEqual(@as(u32, 4), term.cursor_y);
}

test "Executor: DECSET 1049 switches to alt screen" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    term.setCell(0, 0, .{ .char = 'M' });
    for ("\x1b[?1049h") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    try testing.expect(term.is_alt_screen);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 0).char);
}

test "Executor: SGR 0 resets all attributes" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b[1;31m\x1b[0mX") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    try testing.expectEqual(@as(u8, 7), term.getCell(0, 0).fg);
    try testing.expect(!term.getCell(0, 0).attrs.bold);
}

test "Executor: cursor save/restore (CSI s/u)" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b[4;6H\x1b[s\x1b[11;11H\x1b[u") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    try testing.expectEqual(@as(u32, 5), term.cursor_x);
    try testing.expectEqual(@as(u32, 3), term.cursor_y);
}

test "Executor: DECSTBM sets scroll region" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b[5;20r") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    try testing.expectEqual(@as(u32, 4), term.scroll_top);
    try testing.expectEqual(@as(u32, 19), term.scroll_bottom);
}

test "Executor: DECAWM wraps at right edge" {
    var term = try Term.init(testing.allocator, 5, 2);
    defer term.deinit();
    var parser = Parser{};
    for ("ABCDE") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    // After 5 chars in 5-col terminal, cursor_x == 5 (one past end)
    // Print F should wrap
    executeAction(parser.feed('F'), &term);
    try testing.expectEqual(@as(u21, 'F'), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u32, 1), term.cursor_x);
    try testing.expectEqual(@as(u32, 1), term.cursor_y);
}

test "Executor: TrueColor SGR 38;2;r;g;b" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b[38;2;255;128;0mX") |byte| {
        executeAction(parser.feed(byte), &term);
    }
    const rgb = term.getFgRgb(0, 0);
    try testing.expect(rgb != null);
    try testing.expectEqual([3]u8{ 255, 128, 0 }, rgb.?);
}

test "Executor: ED mode 0 erases below" {
    var term = try Term.init(testing.allocator, 80, 3);
    defer term.deinit();
    term.setCell(0, 0, .{ .char = 'A' });
    term.setCell(0, 1, .{ .char = 'B' });
    term.setCell(0, 2, .{ .char = 'C' });
    term.cursor_y = 1;
    term.cursor_x = 0;
    term.eraseDisplay(0);
    try testing.expectEqual(@as(u21, 'A'), term.getCell(0, 0).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 1).char);
    try testing.expectEqual(@as(u21, ' '), term.getCell(0, 2).char);
}

test "Executor: tab stops every 8 columns" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    term.cursor_x = 3;
    executeAction(parser.feed(0x09), &term); // HT
    try testing.expectEqual(@as(u32, 8), term.cursor_x);
}
