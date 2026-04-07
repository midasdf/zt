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
    dcs_dispatch: []const u8,
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
    in_subparam: bool = false,
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
        const cp: u21 = switch (bytes.len) {
            2 => blk: {
                const b0 = @as(u21, bytes[0] & 0x1F);
                const b1 = @as(u21, bytes[1] & 0x3F);
                const v = (b0 << 6) | b1;
                // Reject overlong: 2-byte must encode >= U+0080
                break :blk if (v < 0x80) 0xFFFD else v;
            },
            3 => blk: {
                const b0 = @as(u21, bytes[0] & 0x0F);
                const b1 = @as(u21, bytes[1] & 0x3F);
                const b2 = @as(u21, bytes[2] & 0x3F);
                const v = (b0 << 12) | (b1 << 6) | b2;
                // Reject overlong (must encode >= U+0800) and surrogates (U+D800..U+DFFF)
                break :blk if (v < 0x800 or (v >= 0xD800 and v <= 0xDFFF)) 0xFFFD else v;
            },
            4 => blk: {
                const b0 = @as(u21, bytes[0] & 0x07);
                const b1 = @as(u21, bytes[1] & 0x3F);
                const b2 = @as(u21, bytes[2] & 0x3F);
                const b3 = @as(u21, bytes[3] & 0x3F);
                const v = (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;
                // Reject overlong (must encode >= U+10000) and > U+10FFFF
                break :blk if (v < 0x10000 or v > 0x10FFFF) 0xFFFD else v;
            },
            else => 0xFFFD,
        };
        return cp;
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
        } else if (byte == 'P') {
            // DCS — Device Control String
            self.osc_len = 0;
            self.state = .dcs_entry;
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
        if (byte >= 0x3C and byte <= 0x3F) {
            // Private marker bytes: < = > ?
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
            // Accumulate digit (skip if in colon sub-parameter)
            if (self.in_subparam) return .none;
            const idx = self.param_count;
            if (idx < 16) {
                self.params[idx] = self.params[idx] *| 10 +| (byte - '0');
            }
            return .none;
        } else if (byte == ':') {
            // Colon sub-parameter separator (e.g., \e[4:3m)
            // Keep the main parameter, skip sub-parameter digits
            self.in_subparam = true;
            return .none;
        } else if (byte == ';') {
            // Next param — ends any sub-parameter
            self.in_subparam = false;
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
            self.in_subparam = false;
            self.param_count += 1;
            self.state = .ground;
            return Action{ .csi_dispatch = self.buildCsiAction(byte) };
        } else if (byte >= 0x3C and byte <= 0x3F) {
            // Malformed (but NOT 0x3A which is ':')
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
        // Note: 0x9C (8-bit ST) is NOT handled here because it conflicts
        // with UTF-8 multi-byte sequences (e.g. U+2733 ✳ = E2 9C B3).
        // Only ESC \ (7-bit ST) and BEL are used as terminators.
        if (self.esc_in_osc) {
            self.esc_in_osc = false;
            if (byte == '\\') {
                // ESC \ = ST — dispatch DCS payload
                const payload = self.osc_buf[0..self.osc_len];
                self.osc_len = 0;
                self.state = .ground;
                return if (payload.len > 0) Action{ .dcs_dispatch = payload } else .none;
            } else {
                // ESC followed by non-backslash — store the ESC and reprocess byte
                if (self.osc_len < 256) {
                    self.osc_buf[self.osc_len] = 0x1B;
                    self.osc_len += 1;
                }
                // Fall through to store the current byte
            }
        }
        if (byte == 0x1B) {
            // Could be start of ST (ESC \) — wait for next byte
            self.esc_in_osc = true;
            return .none;
        } else {
            if (self.osc_len < 256) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        }
        return .none;
    }

    fn clearCsi(self: *Parser) void {
        self.params = [_]u16{0} ** 16;
        self.param_count = 0;
        self.intermediates = [_]u8{0} ** 2;
        self.intermediate_count = 0;
        self.private_marker = 0;
        self.in_subparam = false;
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
    // Hoist charset/insert_mode checks — only change on escape sequences, not mid-ASCII-run
    var ascii_fast_eligible = (term.charsets[term.charset] == .us_ascii and !term.insert_mode);
    while (i < data.len) {
        // Fast path: ground state + printable ASCII run (US-ASCII charset only, no insert mode)
        // Writes directly to cells[] array, bypassing setCell/handlePrint overhead.
        // Safe because ASCII is never wide and doesn't need TrueColor cleanup.
        if (parser.state == .ground and data[i] >= 0x20 and data[i] <= 0x7E and
            ascii_fast_eligible)
        {
            const cols = term.cols;
            while (true) {
                // Handle printable ASCII run on current line
                if (i >= data.len or (@as(u32, data[i]) -% 0x20) > 0x5E) break;
                // Deferred wrap from previous char
                if (term.wrap_next) {
                    if (term.decawm) {
                        term.cursor_x = 0;
                        term.insertNewline();
                    }
                    term.wrap_next = false;
                }
                // Bulk write: compute run length that fits on current line
                const remaining = cols - term.cursor_x;
                const phys_row = term.row_map[term.cursor_y];
                const phys_base = @as(usize, phys_row) * @as(usize, cols);
                var count: u32 = 0;
                const max_scan = @min(remaining, @as(u32, @intCast(data.len - i)));
                // SIMD path: check 16 bytes at a time for printable ASCII range
                const VEC_LEN = 16;
                const Vec = @Vector(VEC_LEN, u8);
                const lo: Vec = @splat(0x20);
                const hi: Vec = @splat(0x7E);
                while (count + VEC_LEN <= max_scan) {
                    const chunk: Vec = data[i + count ..][0..VEC_LEN].*;
                    if (@reduce(.And, chunk >= lo) and @reduce(.And, chunk <= hi)) {
                        count += VEC_LEN;
                    } else break;
                }
                // Scalar tail (branchless range check: (byte - 0x20) <= 0x5E)
                while (count < max_scan and (@as(u32, data[i + count]) -% 0x20) <= 0x5E) {
                    count += 1;
                }
                if (count == 0) break;
                // Write cells directly to physical row
                const phys_start = phys_base + term.cursor_x;
                // Fix wide character boundaries before overwriting (skip if no wide chars ever written)
                if (term.has_wide_chars) {
                    // If first cell is a wide_dummy, clear the wide cell to its left
                    if (term.cells[phys_start].attrs.wide_dummy and term.cursor_x > 0) {
                        const wide_idx = phys_base + term.cursor_x - 1;
                        term.cells[wide_idx] = term.blankCell();
                        term.fg_rgb[wide_idx] = null;
                        term.bg_rgb[wide_idx] = term.current_bg_rgb;
                        const logical_wide = @as(usize, term.cursor_y) * @as(usize, cols) + term.cursor_x - 1;
                        term.markDirtyRange(.{ .start = logical_wide, .end = logical_wide + 1 });
                    }
                    // If last cell in range is wide, clear its dummy to the right
                    if (count > 0 and term.cells[phys_start + count - 1].attrs.wide) {
                        const dummy_x = term.cursor_x + count;
                        if (dummy_x < cols) {
                            const dummy_phys = phys_base + dummy_x;
                            term.cells[dummy_phys] = term.blankCell();
                            term.fg_rgb[dummy_phys] = null;
                            term.bg_rgb[dummy_phys] = term.current_bg_rgb;
                            const logical_dummy = @as(usize, term.cursor_y) * @as(usize, cols) + dummy_x;
                            term.markDirtyRange(.{ .start = logical_dummy, .end = logical_dummy + 1 });
                        }
                    }
                }
                // Write cells using 8-byte template with char byte patch.
                // Avoids per-field scalar stores (7x speedup over struct init loop).
                // Cell layout: [char:4][attrs:2][fg:1][bg:1] — char offset 0, ASCII in byte 0.
                const template = Cell{
                    .char = 0,
                    .fg = term.current_fg,
                    .bg = term.current_bg,
                    .attrs = term.current_attrs,
                };
                const tmpl_bytes: [8]u8 = std.mem.asBytes(&template).*;
                const cell_dest: [*]u8 = @ptrCast(&term.cells[phys_start]);
                const char_offset = @offsetOf(Cell, "char");
                for (0..count) |j| {
                    const off = j * 8;
                    cell_dest[off..][0..8].* = tmpl_bytes;
                    cell_dest[off + char_offset] = data[i + j];
                }
                // Update TrueColor arrays — skip when palette-only (saves ~37MB writes for ASCII workloads)
                const fg_val: ?[3]u8 = term.current_fg_rgb;
                const bg_val: ?[3]u8 = term.current_bg_rgb;
                if (fg_val != null or bg_val != null) {
                    @memset(term.fg_rgb[phys_start .. phys_start + count], fg_val);
                    @memset(term.bg_rgb[phys_start .. phys_start + count], bg_val);
                    term.has_truecolor_cells = true;
                } else if (term.has_truecolor_cells) {
                    // Must clear residual TrueColor from previous content
                    @memset(term.fg_rgb[phys_start .. phys_start + count], null);
                    @memset(term.bg_rgb[phys_start .. phys_start + count], null);
                }
                // Bulk dirty (logical index)
                const logical_start = @as(usize, term.cursor_y) * @as(usize, cols) + term.cursor_x;
                term.markDirtyRange(.{ .start = logical_start, .end = logical_start + count });
                term.last_printed_char = @as(u21, data[i + count - 1]);
                term.cursor_x += count;
                i += count;
                // Deferred wrap: if cursor went past right margin, set wrap_next
                if (term.cursor_x >= cols) {
                    term.cursor_x = cols - 1;
                    term.wrap_next = true;
                }
                // Inline control character handling — stay in fast path loop
                if (i < data.len) {
                    switch (data[i]) {
                        0x0A, 0x0B, 0x0C => {
                            term.wrap_next = false;
                            term.insertNewline();
                            i += 1;
                            continue;
                        },
                        0x0D => {
                            term.carriageReturn();
                            i += 1;
                            continue;
                        },
                        0x08 => {
                            term.wrap_next = false;
                            if (term.cursor_x > 0) term.cursor_x -= 1;
                            i += 1;
                            continue;
                        },
                        0x09 => {
                            term.tputtab(1);
                            i += 1;
                            continue;
                        },
                        else => {},
                    }
                }
                break;
            }
            continue;
        }
        // Medium path: ground state + UTF-8 multi-byte characters (US-ASCII charset, no insert mode)
        // Decode directly, bypassing per-byte parser state machine overhead.
        // Non-wide chars written directly to cells[] with batch dirty marking.
        if (parser.state == .ground and data[i] >= 0xC0 and data[i] < 0xFE and
            !term.insert_mode)
        {
            const start_i = i;
            var dirty_run_start: usize = @as(usize, term.cursor_y) * @as(usize, term.cols) + term.cursor_x;
            var dirty_run_end: usize = dirty_run_start;
            while (i < data.len and data[i] >= 0xC0 and data[i] < 0xFE) {
                const first = data[i];
                var cp: u21 = undefined;
                var seq_len: usize = undefined;
                if (first < 0xE0) {
                    if (i + 1 >= data.len) break;
                    const b1 = data[i + 1];
                    if (b1 & 0xC0 != 0x80) break;
                    cp = (@as(u21, first & 0x1F) << 6) | @as(u21, b1 & 0x3F);
                    if (cp < 0x80) cp = 0xFFFD; // reject overlong
                    seq_len = 2;
                } else if (first < 0xF0) {
                    if (i + 2 >= data.len) break;
                    const b1 = data[i + 1];
                    const b2 = data[i + 2];
                    if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80) break;
                    cp = (@as(u21, first & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | @as(u21, b2 & 0x3F);
                    if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF)) cp = 0xFFFD; // reject overlong/surrogate
                    seq_len = 3;
                } else if (first < 0xF5) {
                    if (i + 3 >= data.len) break;
                    const b1 = data[i + 1];
                    const b2 = data[i + 2];
                    const b3 = data[i + 3];
                    if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) break;
                    cp = (@as(u21, first & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) | (@as(u21, b2 & 0x3F) << 6) | @as(u21, b3 & 0x3F);
                    if (cp < 0x10000 or cp > 0x10FFFF) cp = 0xFFFD; // reject overlong/>U+10FFFF
                    seq_len = 4;
                } else {
                    // 0xF5..0xFD: invalid lead byte, skip
                    i += 1;
                    continue;
                }
                // Wide chars need handlePrint for dummy cell logic
                if (isWide(cp)) {
                    handlePrint(cp, term);
                    i += seq_len;
                    continue;
                }
                // Non-wide: direct cell write (like ASCII fast path)
                const cols = term.cols;
                // Deferred wrap
                if (term.wrap_next) {
                    // Flush pending dirty before line change
                    if (dirty_run_start < dirty_run_end)
                        term.markDirtyRange(.{ .start = dirty_run_start, .end = dirty_run_end });
                    if (term.decawm) {
                        term.cursor_x = 0;
                        term.insertNewline();
                    }
                    term.wrap_next = false;
                    dirty_run_start = @as(usize, term.cursor_y) * @as(usize, cols) + term.cursor_x;
                    dirty_run_end = dirty_run_start;
                }
                const phys_row = term.row_map[term.cursor_y];
                const phys_idx = @as(usize, phys_row) * @as(usize, cols) + term.cursor_x;
                // Fix wide char boundary if overwriting (skip if no wide chars ever written)
                if (term.has_wide_chars) {
                    if (term.cells[phys_idx].attrs.wide_dummy and term.cursor_x > 0) {
                        const wide_phys = phys_idx - 1;
                        term.cells[wide_phys] = term.blankCell();
                        term.fg_rgb[wide_phys] = null;
                        term.bg_rgb[wide_phys] = term.current_bg_rgb;
                        if (term.current_bg_rgb != null) term.has_truecolor_cells = true;
                        term.markDirty(term.cursor_x - 1, term.cursor_y);
                    } else if (term.cells[phys_idx].attrs.wide and term.cursor_x + 1 < cols) {
                        const dummy_phys = phys_idx + 1;
                        term.cells[dummy_phys] = term.blankCell();
                        term.fg_rgb[dummy_phys] = null;
                        term.bg_rgb[dummy_phys] = term.current_bg_rgb;
                        if (term.current_bg_rgb != null) term.has_truecolor_cells = true;
                        term.markDirty(term.cursor_x + 1, term.cursor_y);
                    }
                }
                term.cells[phys_idx] = .{
                    .char = cp,
                    .fg = term.current_fg,
                    .bg = term.current_bg,
                    .attrs = term.current_attrs,
                };
                if (term.current_fg_rgb != null or term.current_bg_rgb != null) {
                    term.fg_rgb[phys_idx] = term.current_fg_rgb;
                    term.bg_rgb[phys_idx] = term.current_bg_rgb;
                    term.has_truecolor_cells = true;
                } else if (term.has_truecolor_cells) {
                    term.fg_rgb[phys_idx] = null;
                    term.bg_rgb[phys_idx] = null;
                }
                const logical_idx = @as(usize, term.cursor_y) * @as(usize, cols) + term.cursor_x;
                dirty_run_end = logical_idx + 1;
                term.last_printed_char = cp;
                if (term.cursor_x + 1 < cols) {
                    term.cursor_x += 1;
                } else {
                    term.cursor_x = cols - 1;
                    term.wrap_next = true;
                }
                i += seq_len;
            }
            // Flush accumulated dirty range
            if (dirty_run_start < dirty_run_end)
                term.markDirtyRange(.{ .start = dirty_run_start, .end = dirty_run_end });
            if (i > start_i) continue;
        }
        // VT52 mode: simplified parser
        if (term.vt52_mode) {
            handleVt52Byte(data[i], term, parser, writer_fd);
            i += 1;
            continue;
        }
        // Slow path: control/escape sequences, incomplete UTF-8
        const action = parser.feed(data[i]);
        executeActionWithFd(action, term, writer_fd);
        i += 1;
        // Refresh fast-path eligibility — escape sequences may change charset/insert_mode
        ascii_fast_eligible = (term.charsets[term.charset] == .us_ascii and !term.insert_mode);
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
        .esc_dispatch => |esc| handleEsc(esc, term, writer_fd),
        .osc_dispatch => |payload| handleOsc(payload, term, writer_fd),
        .dcs_dispatch => |payload| handleDcsDispatch(payload, writer_fd, term),
        .none => {},
    }
}

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
                    const response = switch (cmd) {
                        10 => "\x1b]10;rgb:ffff/ffff/ffff\x1b\\",
                        11 => "\x1b]11;rgb:0000/0000/0000\x1b\\",
                        12 => "\x1b]12;rgb:ffff/ffff/ffff\x1b\\",
                        else => unreachable,
                    };
                    _ = std.posix.write(fd, response) catch {};
                }
            }
        },
        52 => {}, // Clipboard — silently accept
        104, 110, 111, 112 => {}, // Reset colors — silently accept
        else => {},
    }
}

fn handleDcsDispatch(payload: []const u8, writer_fd: ?std.posix.fd_t, term: *const Term) void {
    const fd = writer_fd orelse return;

    // DECRQSS: DCS $ q Pt ST — Request Status String
    if (payload.len >= 2 and payload[0] == '$' and payload[1] == 'q') {
        respondDecrqss(fd, payload[2..], term);
        return;
    }

    // XTGETTCAP: DCS + q <hex-name>[;<hex-name>...] ST
    const qpos = std.mem.indexOf(u8, payload, "+q") orelse return;
    const hex_names = payload[qpos + 2 ..];

    // Split by ';' and respond to each capability
    var iter = std.mem.splitScalar(u8, hex_names, ';');
    while (iter.next()) |hex_name| {
        if (hex_name.len == 0) continue;
        respondXtgettcap(fd, hex_name);
    }
}

fn respondXtgettcap(fd: std.posix.fd_t, hex_name: []const u8) void {
    // Known capabilities (hex-encoded name → hex-encoded value)
    const caps = .{
        // indn (scroll forward): \e[%p1%dS
        .{ "696e646e", "1b5b257031256453" },
        // rin (scroll backward): \e[%p1%dT
        .{ "72696e", "1b5b257031256454" },
        // colors: 256
        .{ "636f6c6f7273", "323536" },
        // TN (terminal name): zt
        .{ "544e", "7a74" },
        // query-os-name: linux
        .{ "71756572792d6f732d6e616d65", "6c696e7578" },
        // RGB: true (8/8/8)
        .{ "524742", "382f382f38" },
    };

    var resp_buf: [256]u8 = undefined;

    inline for (caps) |cap| {
        if (std.mem.eql(u8, hex_name, cap[0])) {
            // Valid response: DCS 1 + r <name>=<value> ST
            const resp = "\x1bP1+r" ++ cap[0] ++ "=" ++ cap[1] ++ "\x1b\\";
            _ = std.posix.write(fd, resp) catch {};
            return;
        }
    }

    // Unknown capability: DCS 0 + r <name> ST
    const prefix = "\x1bP0+r";
    const suffix = "\x1b\\";
    if (prefix.len + hex_name.len + suffix.len <= resp_buf.len) {
        var pos: usize = 0;
        @memcpy(resp_buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        @memcpy(resp_buf[pos..][0..hex_name.len], hex_name);
        pos += hex_name.len;
        @memcpy(resp_buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
        _ = std.posix.write(fd, resp_buf[0..pos]) catch {};
    }
}

fn respondDecrqss(fd: std.posix.fd_t, query: []const u8, term: *const Term) void {
    if (std.mem.eql(u8, query, "m")) {
        // SGR state — report reset (simplified)
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
        // Unknown — respond invalid
        _ = std.posix.write(fd, "\x1bP0$r\x1b\\") catch {};
    }
}

fn handleVt52Byte(byte: u8, term: *Term, parser: *Parser, writer_fd: ?std.posix.fd_t) void {
    // VT52 ESC Y sub-state: collecting row and column bytes
    // Reuse utf8_buf[0] as sub-state: 0=normal, 'Y'=awaiting row, 'R'=awaiting col
    if (parser.utf8_buf[0] == 'Y') {
        // Awaiting row byte (row = byte - 0x1F, 1-based)
        parser.utf8_buf[1] = byte;
        parser.utf8_buf[0] = 'R'; // now awaiting col
        return;
    }
    if (parser.utf8_buf[0] == 'R') {
        // Awaiting col byte
        const row = if (parser.utf8_buf[1] >= 0x20) parser.utf8_buf[1] - 0x20 else 0;
        const col = if (byte >= 0x20) byte - 0x20 else 0;
        term.cursor_x = @min(@as(u32, col), term.cols -| 1);
        term.cursor_y = @min(@as(u32, row), term.rows -| 1);
        term.wrap_next = false;
        parser.utf8_buf[0] = 0;
        return;
    }

    if (parser.state == .escape) {
        parser.state = .ground;
        switch (byte) {
            'A' => {
                term.wrap_next = false;
                if (term.cursor_y > 0) term.cursor_y -= 1;
            },
            'B' => {
                term.wrap_next = false;
                if (term.cursor_y < term.rows - 1) term.cursor_y += 1;
            },
            'C' => {
                term.wrap_next = false;
                if (term.cursor_x < term.cols - 1) term.cursor_x += 1;
            },
            'D' => {
                term.wrap_next = false;
                if (term.cursor_x > 0) term.cursor_x -= 1;
            },
            'F' => term.charsets[0] = .dec_graphics,
            'G' => term.charsets[0] = .us_ascii,
            'H' => {
                term.cursor_x = 0;
                term.cursor_y = 0;
                term.wrap_next = false;
            },
            'I' => { // Reverse LF
                term.wrap_next = false;
                if (term.cursor_y == term.scroll_top) term.scrollDown(1) else if (term.cursor_y > 0) term.cursor_y -= 1;
            },
            'J' => term.eraseDisplay(0),
            'K' => term.eraseLine(0),
            'Y' => {
                parser.utf8_buf[0] = 'Y';
                return;
            }, // Begin cursor addressing
            'Z' => { // Identify
                if (writer_fd) |fd| _ = std.posix.write(fd, "\x1b/Z") catch {};
            },
            '<' => {
                term.vt52_mode = false;
                parser.utf8_buf[0] = 0;
            }, // Exit VT52 → VT100
            '=' => term.deckpam = true,
            '>' => term.deckpam = false,
            else => {},
        }
        return;
    }
    if (byte == 0x1B) {
        parser.state = .escape;
        return;
    }
    if (byte <= 0x1F) {
        handleControl(byte, term);
    } else if (byte <= 0x7E) {
        handlePrint(@as(u21, byte), term);
    }
}

fn isWide(cp: u21) bool {
    // Unicode 15.1 East Asian Width W/F — comprehensive table based on EAW.txt
    // Fast rejection: ASCII, Latin, common symbols (vast majority of chars)
    if (cp < 0x1100) return false;
    if (cp <= 0x115F) return true; // Hangul Jamo
    if (cp == 0x231A or cp == 0x231B) return true; // Watch, Hourglass
    if (cp >= 0x2329 and cp <= 0x232A) return true; // Angle Brackets
    if (cp >= 0x23E9 and cp <= 0x23F3) return true; // Various clocks/timers
    if (cp >= 0x23F8 and cp <= 0x23FA) return true; // Playback symbols
    if (cp < 0x2E80) return false;
    // CJK Radicals Supplement through Yi Radicals
    if (cp <= 0x303E) return true; // CJK Radicals, Kangxi, CJK Symbols
    if (cp >= 0x3041 and cp <= 0x33BF) return true; // Hiragana, Katakana, Bopomofo, Hangul Compat, Kanbun, CJK Strokes
    if (cp >= 0x33C0 and cp <= 0x33FF) return true; // CJK Compatibility
    if (cp >= 0x3400 and cp <= 0x4DBF) return true; // CJK Unified Extension A
    if (cp >= 0x4E00 and cp <= 0xA4CF) return true; // CJK Unified through Yi
    if (cp >= 0xA960 and cp <= 0xA97C) return true; // Hangul Jamo Extended-A
    if (cp >= 0xAC00 and cp <= 0xD7A3) return true; // Hangul Syllables
    if (cp >= 0xF900 and cp <= 0xFAFF) return true; // CJK Compatibility Ideographs
    if (cp >= 0xFE10 and cp <= 0xFE19) return true; // Vertical Forms
    if (cp >= 0xFE30 and cp <= 0xFE6F) return true; // CJK Compatibility Forms, Small Form Variants
    if (cp >= 0xFF01 and cp <= 0xFF60) return true; // Fullwidth Forms
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return true; // Fullwidth Signs
    // Supplementary planes — Emoji and CJK extensions
    return switch (cp) {
        // Misc Symbols and Pictographs, Emoticons, Transport, etc.
        0x16FE0...0x16FFF, // Ideographic Symbols
        0x17000...0x187FF, // Tangut
        0x18800...0x18AFF, // Tangut Components
        0x18B00...0x18CFF, // Khitan Small Script
        0x18D00...0x18D7F, // Tangut Supplement
        0x1AFF0...0x1AFFF, // Kana Extended-B
        0x1B000...0x1B0FF, // Kana Supplement
        0x1B100...0x1B12F, // Kana Extended-A
        0x1B130...0x1B16F, // Small Kana Extension
        0x1B170...0x1B2FF, // Nushu
        0x1F004,
        0x1F0CF, // Mahjong, Playing Cards
        0x1F18E, // Negative Squared AB
        0x1F191...0x1F19A, // Squared symbols
        0x1F1E0...0x1F1FF, // Regional Indicators (flags)
        0x1F200...0x1F2FF, // Enclosed Ideographic Supplement
        0x1F300...0x1F5FF, // Misc Symbols and Pictographs
        0x1F600...0x1F64F, // Emoticons
        0x1F680...0x1F6FF, // Transport and Map Symbols
        0x1F700...0x1F77F, // Alchemical Symbols (some wide)
        0x1F780...0x1F7FF, // Geometric Shapes Extended
        0x1F800...0x1F8FF, // Supplemental Arrows-C
        0x1F900...0x1F9FF, // Supplemental Symbols and Pictographs
        0x1FA70...0x1FAFF, // Symbols and Pictographs Extended-A
        0x1FB00...0x1FBFF, // Symbols for Legacy Computing
        0x20000...0x2FFFF, // CJK Extensions B-G, Compatibility Supplement
        0x30000...0x3FFFF, // CJK Extension H+
        => true,
        else => false,
    };
}

fn handlePrint(cp: u21, term: *Term) void {
    // Apply charset translation (VT100 DEC Graphics)
    const actual_cp = term_mod.translateCharset(cp, term.charsets[term.charset]);
    const wide = isWide(actual_cp);

    // Deferred wrap: if previous char set wrap_next, wrap now
    if (term.wrap_next) {
        if (term.decawm) {
            term.cursor_x = 0;
            term.insertNewline();
        }
        term.wrap_next = false;
    }

    // Wide char needs 2 columns — wrap if only 1 column left
    if (wide and term.cursor_x + 1 >= term.cols) {
        if (term.decawm) {
            // Clean up wide pair if cursor is on a dummy cell
            const cur = term.getCell(term.cursor_x, term.cursor_y);
            if (cur.attrs.wide_dummy and term.cursor_x > 0) {
                term.setCell(term.cursor_x - 1, term.cursor_y, term.blankCell());
            }
            term.setCell(term.cursor_x, term.cursor_y, term.blankCell());
            term.cursor_x = 0;
            term.insertNewline();
        }
    }

    // Insert mode: shift existing chars right before printing
    if (term.insert_mode) {
        const width: u32 = if (wide) 2 else 1;
        if (term.cursor_x + width < term.cols) {
            term.insertChars(width);
        }
    }

    // Clear any existing wide char pair we're overwriting
    if (term.cursor_x < term.cols and term.cursor_y < term.rows) {
        const existing = term.getCell(term.cursor_x, term.cursor_y);
        if (existing.attrs.wide_dummy and term.cursor_x > 0) {
            term.setCell(term.cursor_x - 1, term.cursor_y, term.blankCell());
        } else if (existing.attrs.wide and term.cursor_x + 1 < term.cols) {
            term.setCell(term.cursor_x + 1, term.cursor_y, term.blankCell());
        }
        // For wide chars: also check cursor_x+1 (where the dummy will go).
        // If cursor_x+1 is a wide cell, its dummy at cursor_x+2 would be orphaned.
        if (wide and term.cursor_x + 1 < term.cols) {
            const next = term.getCell(term.cursor_x + 1, term.cursor_y);
            if (next.attrs.wide and term.cursor_x + 2 < term.cols) {
                term.setCell(term.cursor_x + 2, term.cursor_y, term.blankCell());
            }
        }
    }

    var attrs = term.current_attrs;
    if (wide) {
        attrs.wide = true;
        term.has_wide_chars = true;
    }

    // Direct cell write — compute phys_idx once instead of 3-5 cellIndex calls
    const cols: usize = term.cols;
    const phys_row = term.row_map[term.cursor_y];
    const phys_idx = @as(usize, phys_row) * cols + @as(usize, term.cursor_x);
    term.cells[phys_idx] = .{
        .char = actual_cp,
        .fg = term.current_fg,
        .bg = term.current_bg,
        .attrs = attrs,
    };
    // TrueColor: write directly, skip redundant null+rewrite from setCell
    if (term.current_fg_rgb != null or term.current_bg_rgb != null) {
        term.fg_rgb[phys_idx] = term.current_fg_rgb;
        term.bg_rgb[phys_idx] = term.current_bg_rgb;
        term.has_truecolor_cells = true;
    } else if (term.has_truecolor_cells) {
        term.fg_rgb[phys_idx] = null;
        term.bg_rgb[phys_idx] = null;
    }
    const dirty_idx = @as(usize, term.cursor_y) * cols + @as(usize, term.cursor_x);
    term.dirty.set(dirty_idx);
    term.dirty_flag = true;

    term.last_printed_char = actual_cp;

    // Advance cursor or set deferred wrap
    const width_adv: u32 = if (wide) 2 else 1;
    if (term.cursor_x + width_adv < term.cols) {
        term.cursor_x += width_adv;
        // Wide char: set dummy cell for right half (reuse phys_row)
        if (wide) {
            const dummy_phys = @as(usize, phys_row) * cols + @as(usize, term.cursor_x - 1);
            var dummy = Cell{ .bg = term.current_bg };
            dummy.attrs.wide_dummy = true;
            term.cells[dummy_phys] = dummy;
            if (term.has_truecolor_cells) {
                term.fg_rgb[dummy_phys] = null;
                term.bg_rgb[dummy_phys] = null;
            }
            const dummy_dirty = @as(usize, term.cursor_y) * cols + @as(usize, term.cursor_x - 1);
            term.dirty.set(dummy_dirty);
        }
    } else {
        // At right margin — set deferred wrap, don't advance
        if (wide and term.cursor_x + 1 < term.cols) {
            const dummy_phys = @as(usize, phys_row) * cols + @as(usize, term.cursor_x + 1);
            var dummy = Cell{ .bg = term.current_bg };
            dummy.attrs.wide_dummy = true;
            term.cells[dummy_phys] = dummy;
            if (term.has_truecolor_cells) {
                term.fg_rgb[dummy_phys] = null;
                term.bg_rgb[dummy_phys] = null;
            }
            const dummy_dirty = @as(usize, term.cursor_y) * cols + @as(usize, term.cursor_x + 1);
            term.dirty.set(dummy_dirty);
        }
        term.cursor_x = term.cols - 1;
        term.wrap_next = true;
    }
}

fn handleControl(c: u8, term: *Term) void {
    switch (c) {
        0x0A, 0x0B, 0x0C => { // LF, VT, FF
            term.wrap_next = false;
            if (term.linefeed_mode) term.cursor_x = 0;
            term.insertNewline();
        },
        0x0D => term.carriageReturn(), // CR
        0x08 => { // BS
            term.wrap_next = false;
            if (term.cursor_x > 0) term.cursor_x -= 1;
        },
        0x09 => term.tputtab(1), // HT — advance to next tab stop
        0x07 => {}, // BEL — ignore
        0x0E => term.charset = 1, // SO (LS1 — Locking shift 1, activate G1)
        0x0F => term.charset = 0, // SI (LS0 — Locking shift 0, activate G0)
        else => {},
    }
}

fn handleCsi(csi: CsiAction, term: *Term, writer_fd: ?std.posix.fd_t) void {
    const p = csi.params;
    const pc = csi.param_count;

    switch (csi.final_byte) {
        'A' => { // CUU — cursor up (respects scroll region)
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.wrap_next = false;
            const min_y: u32 = if (term.cursor_y >= term.scroll_top and term.cursor_y <= term.scroll_bottom)
                term.scroll_top
            else
                0;
            term.cursor_y = if (term.cursor_y >= n) @max(term.cursor_y - n, min_y) else min_y;
        },
        'B', 'e' => { // CUD/VPR — cursor down (respects scroll region)
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.wrap_next = false;
            const max_y: u32 = if (term.cursor_y >= term.scroll_top and term.cursor_y <= term.scroll_bottom)
                term.scroll_bottom
            else
                term.rows -| 1;
            term.cursor_y = @min(term.cursor_y + n, max_y);
        },
        'C', 'a' => { // CUF/HPR — cursor forward
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
        'G', '`' => { // CHA/HPA — cursor horizontal absolute (1-indexed)
            const col = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            term.cursor_x = @min(@as(u32, @intCast(col)), term.cols -| 1);
            term.wrap_next = false;
        },
        'H', 'f' => { // CUP — cursor position (1-indexed params)
            const row = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
            const col = if (pc > 1 and p[1] > 0) p[1] - 1 else 0;
            term.moveCursorTo(@intCast(col), @intCast(row));
        },
        'J' => { // ED / DECSED — erase display
            const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
            if (csi.private_marker == '?') {
                term.selectiveEraseDisplay(mode);
            } else {
                term.eraseDisplay(mode);
            }
        },
        'K' => { // EL / DECSEL — erase line
            const mode: u8 = if (pc > 0) @intCast(p[0]) else 0;
            if (csi.private_marker == '?') {
                term.selectiveEraseLine(mode);
            } else {
                term.eraseLine(mode);
            }
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
            term.wrap_next = false;
        },
        'm' => {
            // SGR only without private marker; \e[>4;2m is "Modify Other Keys", not SGR
            if (csi.private_marker == 0) handleSgr(csi, term);
        },
        'c' => { // Device Attributes
            if (writer_fd) |fd| {
                if (csi.private_marker == 0) {
                    // DA1 — report as VT220
                    _ = std.posix.write(fd, "\x1b[?62;22c") catch {};
                } else if (csi.private_marker == '>') {
                    // DA2 — secondary device attributes (xterm-compatible)
                    _ = std.posix.write(fd, "\x1b[>0;0;0c") catch {};
                }
            }
        },
        'n' => { // DSR — device status report
            if (csi.private_marker == 0 and pc > 0) {
                if (writer_fd) |fd| {
                    if (p[0] == 5) {
                        // Status Report — respond "OK"
                        _ = std.posix.write(fd, "\x1b[0n") catch {};
                    } else if (p[0] == 6) {
                        // Cursor Position Report
                        var buf: [32]u8 = undefined;
                        const response = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ term.cursor_y + 1, term.cursor_x + 1 }) catch return;
                        _ = std.posix.write(fd, response) catch {};
                    }
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
        'b' => { // REP — repeat preceding graphic character
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            const ch = term.last_printed_char;
            if (ch > 0) {
                const count = @min(n, term.cols * term.rows);
                var rep: u16 = 0;
                while (rep < count) : (rep += 1) {
                    handlePrint(ch, term);
                }
            }
        },
        'r' => {
            if (csi.private_marker == '?') {
                // XTRESTORE — Restore DEC Private Mode values
                restoreDECModes(csi, term);
            } else if (csi.private_marker == 0) {
                // DECSTBM — set scroll region (1-indexed)
                const top = if (pc > 0 and p[0] > 0) p[0] - 1 else 0;
                const bot = if (pc > 1 and p[1] > 0) p[1] - 1 else @as(u16, @intCast(term.rows -| 1));
                term.setScrollRegion(@intCast(top), @intCast(bot));
                term.cursor_x = 0;
                term.cursor_y = 0;
                term.wrap_next = false;
            }
        },
        's' => {
            if (csi.private_marker == '?') {
                // XTSAVE — Save DEC Private Mode values
                saveDECModes(csi, term);
            } else if (csi.private_marker == 0) {
                // Save cursor position
                term.saved_cursor_x = term.cursor_x;
                term.saved_cursor_y = term.cursor_y;
            }
        },
        'u' => { // Restore cursor (only without private marker; \e[?u/\e[>Nu are Kitty keyboard protocol)
            if (csi.private_marker == 0) {
                term.cursor_x = term.saved_cursor_x;
                term.cursor_y = term.saved_cursor_y;
            }
        },
        'g' => { // TBC — tab clear
            if (pc == 0 or p[0] == 0) {
                // Clear current tab stop
                if (term.cursor_x < term.tabs.len) term.tabs[@intCast(term.cursor_x)] = false;
            } else if (p[0] == 3) {
                // Clear all tab stops
                @memset(term.tabs, false);
            }
        },
        'I' => { // CHT — cursor forward tabulation
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.tputtab(@intCast(n));
        },
        'Z' => { // CBT — cursor backward tabulation
            const n = if (pc > 0 and p[0] > 0) p[0] else 1;
            term.tputtab(-@as(i32, @intCast(n)));
        },
        'h' => { // SM/DECSET — set mode
            if (csi.private_marker == '?') {
                handleDecSet(csi, term, true);
            } else if (csi.private_marker == 0) {
                handleNonPrivateMode(csi, term, true);
            }
            // CSI > h, CSI < h — silently ignore (xterm/kitty private)
        },
        'l' => { // RM/DECRST — reset mode
            if (csi.private_marker == '?') {
                handleDecSet(csi, term, false);
            } else if (csi.private_marker == 0) {
                handleNonPrivateMode(csi, term, false);
            }
            // CSI > l, CSI < l — silently ignore
        },
        'p' => {
            // DECSTR — Soft Terminal Reset (CSI ! p)
            if (csi.intermediate_count > 0 and csi.intermediates[0] == '!') {
                // DECSTR — Soft Terminal Reset (keep screen content)
                term.cursor_x = 0;
                term.cursor_y = 0;
                term.wrap_next = false;
                term.insert_mode = false;
                term.linefeed_mode = false;
                term.origin_mode = false;
                term.decawm = true;
                term.decckm = false;
                term.cursor_visible = true;
                term.deckpam = false;
                term.bracketed_paste = false;
                term.cursor_style = 0;
                term.focus_events = false;
                term.decbkm = false;
                term.sync_update = false;
                term.current_fg = 7;
                term.current_bg = 0;
                term.current_attrs = .{};
                term.current_fg_rgb = null;
                term.current_bg_rgb = null;
                term.charset = 0;
                term.charsets = .{ .us_ascii, .us_ascii, .us_ascii, .us_ascii };
                term.scroll_top = 0;
                term.scroll_bottom = term.rows -| 1;
                term.last_printed_char = 0;
                term.saved_dec_mode_count = 0;
                for (0..term.tabs.len) |c_idx| {
                    term.tabs[c_idx] = (c_idx % 8 == 0) and c_idx > 0;
                }
            } else if (csi.intermediate_count > 0 and csi.intermediates[0] == '$') {
                // DECRQM — Request Mode
                if (writer_fd) |fd| {
                    const mode = if (pc > 0) p[0] else 0;
                    var buf: [32]u8 = undefined;
                    if (csi.private_marker == '?') {
                        const status = queryDecMode(term, mode);
                        const resp = std.fmt.bufPrint(&buf, "\x1b[?{d};{d}$y", .{ mode, status }) catch return;
                        _ = std.posix.write(fd, resp) catch {};
                    } else if (csi.private_marker == 0) {
                        const status = queryAnsiMode(term, mode);
                        const resp = std.fmt.bufPrint(&buf, "\x1b[{d};{d}$y", .{ mode, status }) catch return;
                        _ = std.posix.write(fd, resp) catch {};
                    }
                }
            } else if (csi.intermediate_count > 0 and csi.intermediates[0] == '"') {
                // DECSCL — Set Conformance Level (silently accept)
            }
            // CSI > p — silently ignore (XTPUSHCOLORS etc.)
        },
        'q' => {
            if (csi.intermediate_count > 0 and csi.intermediates[0] == ' ') {
                // DECSCUSR — Set Cursor Style
                term.cursor_style = if (pc > 0) @intCast(p[0]) else 0;
            } else if (csi.intermediate_count > 0 and csi.intermediates[0] == '"') {
                // DECSCA — Set Character Protection Attribute
                const ps = if (pc > 0) p[0] else 0;
                term.current_attrs.protected = (ps == 1);
            } else if (csi.private_marker == '>' and pc > 0 and p[0] == 0) {
                // XTVERSION — respond with terminal identification
                if (writer_fd) |fd| {
                    _ = std.posix.write(fd, "\x1bP>|zt(0.4.1)\x1b\\") catch {};
                }
            }
        },
        'i' => {}, // MC — Media Copy (printer control, silently accept)
        't' => {
            // Window operations (XTWINOPS) — silently accept
        },
        else => {
            // Only warn for sequences without private markers (reduce noise)
            if (csi.private_marker == 0 and csi.intermediate_count == 0) {
                std.log.warn("unhandled CSI: params={d}..{d} final={c}", .{
                    if (pc > 0) p[0] else 0,
                    if (pc > 1) p[1] else 0,
                    csi.final_byte,
                });
            }
        },
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
            5, 6 => term.current_attrs.blink = true, // slow/rapid blink
            7 => term.current_attrs.reverse = true,
            8 => term.current_attrs.invisible = true,
            9 => term.current_attrs.strikethrough = true,
            21 => term.current_attrs.underline = true, // Doubly-underlined (treated as underline)
            22 => {
                term.current_attrs.bold = false;
                term.current_attrs.dim = false;
            },
            23 => term.current_attrs.italic = false,
            24 => term.current_attrs.underline = false,
            25 => term.current_attrs.blink = false,
            27 => term.current_attrs.reverse = false,
            28 => term.current_attrs.invisible = false,
            29 => term.current_attrs.strikethrough = false,
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
            58 => {
                // Extended underline color (58;2;r;g;b or 58;5;n)
                // Must consume sub-params so they aren't misread as SGR codes
                if (i + 1 < pc) {
                    const sub = p[i + 1];
                    if (sub == 5 and i + 2 < pc) {
                        i = i + 2;
                    } else if (sub == 2 and i + 4 < pc) {
                        i = i + 4;
                    }
                }
            },
            59 => {},
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
            if (p[i + 2] > 255) return i + 2;
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
            if (p[i + 2] > 255 or p[i + 3] > 255 or p[i + 4] > 255) return i + 4;
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
            6 => { // DECOM — origin mode
                term.origin_mode = set;
                term.cursor_x = 0;
                term.cursor_y = if (set) term.scroll_top else 0;
                term.wrap_next = false;
            },
            7 => term.decawm = set,
            25 => term.cursor_visible = set,
            47, 1047 => {
                term.switchScreen(set) catch |err| {
                    std.log.err("switchScreen failed: {}", .{err});
                };
            },
            1048 => { // Save/restore cursor independently
                if (set) {
                    term.saved_cursor_x = term.cursor_x;
                    term.saved_cursor_y = term.cursor_y;
                } else {
                    term.cursor_x = term.saved_cursor_x;
                    term.cursor_y = term.saved_cursor_y;
                    term.wrap_next = false;
                }
            },
            1049 => {
                if (set) {
                    term.saved_cursor_x = term.cursor_x;
                    term.saved_cursor_y = term.cursor_y;
                    term.saved_scroll_top = term.scroll_top;
                    term.saved_scroll_bottom = term.scroll_bottom;
                    term.saved_wrap_next = term.wrap_next;
                    term.switchScreen(true) catch |err| {
                        std.log.err("switchScreen failed: {}", .{err});
                    };
                    term.scroll_top = 0;
                    term.scroll_bottom = term.rows -| 1;
                    term.wrap_next = false;
                    term.eraseDisplay(2);
                } else {
                    term.switchScreen(false) catch |err| {
                        std.log.err("switchScreen failed: {}", .{err});
                    };
                    term.cursor_x = term.saved_cursor_x;
                    term.cursor_y = term.saved_cursor_y;
                    term.scroll_top = term.saved_scroll_top;
                    term.scroll_bottom = term.saved_scroll_bottom;
                    term.wrap_next = term.saved_wrap_next;
                }
            },
            2004 => term.bracketed_paste = set,
            2026 => term.sync_update = set,
            // Mouse tracking modes (accepted but not processed — no mouse support yet)
            9, 1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016 => {},
            1004 => term.focus_events = set, // Focus events (CSI I / CSI O)
            // Alt scroll mode
            1007 => {},
            // Meta key mode
            1034 => {},
            // Backarrow key mode
            67 => term.decbkm = set,
            // Left/right margin mode
            69 => {},
            // Silently ignored DEC modes
            2 => {
                if (!set) term.vt52_mode = true;
            }, // DECANM reset → VT52 mode
            0, 3, 4, 5, 8, 12, 18, 19, 38, 42, 45, 66, 2031 => {},
            else => {
                std.log.warn("unhandled DEC mode: {d} set={}", .{ p[i], set });
            },
        }
    }
}

fn handleEsc(esc: EscAction, term: *Term, writer_fd: ?std.posix.fd_t) void {
    // Character set designation (ESC with intermediate byte)
    if (esc.intermediate != 0) {
        switch (esc.intermediate) {
            '(' => term.charsets[0] = charsetFromByte(esc.final_byte), // G0
            ')' => term.charsets[1] = charsetFromByte(esc.final_byte), // G1
            '*' => term.charsets[2] = charsetFromByte(esc.final_byte), // G2
            '+' => term.charsets[3] = charsetFromByte(esc.final_byte), // G3
            '#' => {
                if (esc.final_byte == '8') {
                    // DECALN — fill screen with 'E'
                    for (0..term.rows) |y| {
                        for (0..term.cols) |x| {
                            term.setCell(@intCast(x), @intCast(y), .{ .char = 'E', .fg = 7 });
                        }
                    }
                }
                // ESC # 3/4/5/6 (double-height/width) — silently ignore
            },
            '%' => {}, // ESC % G (UTF-8) / ESC % @ (ISO 8859-1) — always UTF-8, accept
            ' ' => {}, // ESC SP F/G (7/8-bit controls) — silently accept
            else => {},
        }
        return;
    }

    switch (esc.final_byte) {
        '7' => { // DECSC — save cursor (with attributes + TrueColor)
            term.saved_cursor_x = term.cursor_x;
            term.saved_cursor_y = term.cursor_y;
            term.saved_attrs = term.current_attrs;
            term.saved_fg = term.current_fg;
            term.saved_bg = term.current_bg;
            term.saved_fg_rgb = term.current_fg_rgb;
            term.saved_bg_rgb = term.current_bg_rgb;
            term.saved_charset = term.charset;
            term.saved_wrap_next = term.wrap_next;
            term.saved_origin_mode = term.origin_mode;
        },
        '8' => { // DECRC — restore cursor (with attributes + TrueColor)
            term.cursor_x = term.saved_cursor_x;
            term.cursor_y = term.saved_cursor_y;
            term.current_attrs = term.saved_attrs;
            term.current_fg = term.saved_fg;
            term.current_bg = term.saved_bg;
            term.current_fg_rgb = term.saved_fg_rgb;
            term.current_bg_rgb = term.saved_bg_rgb;
            term.charset = term.saved_charset;
            term.wrap_next = term.saved_wrap_next;
            term.origin_mode = term.saved_origin_mode;
        },
        'D' => { // IND — index (cursor down, scroll if at bottom)
            term.wrap_next = false;
            if (term.cursor_y == term.scroll_bottom) {
                term.scrollUp(1);
            } else if (term.cursor_y < term.rows - 1) {
                term.cursor_y += 1;
            }
        },
        'E' => { // NEL — next line (always go to first col)
            term.wrap_next = false;
            term.cursor_x = 0;
            term.insertNewline();
        },
        'H' => { // HTS — horizontal tab stop (set tab at current column)
            if (term.cursor_x < term.tabs.len) {
                term.tabs[@intCast(term.cursor_x)] = true;
            }
        },
        'M' => { // RI — reverse index
            term.wrap_next = false;
            if (term.cursor_y == term.scroll_top) {
                term.scrollDown(1);
            } else if (term.cursor_y > 0) {
                term.cursor_y -= 1;
            }
        },
        'Z' => { // DECID — identify terminal
            if (writer_fd) |fd| {
                _ = std.posix.write(fd, "\x1b[?62;22c") catch {};
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
            term.wrap_next = false;
            term.insert_mode = false;
            term.linefeed_mode = false;
            term.charset = 0;
            term.charsets = .{ .us_ascii, .us_ascii, .us_ascii, .us_ascii };
            term.deckpam = false;
            term.origin_mode = false;
            term.cursor_style = 0;
            term.focus_events = false;
            term.decbkm = false;
            term.vt52_mode = false;
            term.sync_update = false;
            term.last_printed_char = 0;
            term.saved_dec_mode_count = 0;
            term.saved_attrs = .{};
            term.saved_fg = 7;
            term.saved_bg = 0;
            term.saved_charset = 0;
            term.saved_wrap_next = false;
            term.saved_origin_mode = false;
            term.saved_fg_rgb = null;
            term.saved_bg_rgb = null;
            for (0..term.tabs.len) |c| {
                term.tabs[c] = (c % 8 == 0) and c > 0;
            }
            term.eraseDisplay(2);
        },
        'F' => { // Cursor to lower left corner
            term.cursor_x = 0;
            term.cursor_y = term.rows -| 1;
            term.wrap_next = false;
        },
        'n' => term.charset = 2, // LS2 — Locking Shift 2 (activate G2)
        'o' => term.charset = 3, // LS3 — Locking Shift 3 (activate G3)
        '=' => term.deckpam = true, // DECPAM — application keypad
        '>' => term.deckpam = false, // DECPNM — normal keypad
        '\\' => {}, // ST — String Terminator (no-op outside string context)
        else => {
            std.log.warn("unhandled ESC: intermediate={c} final={c}", .{
                if (esc.intermediate != 0) esc.intermediate else @as(u8, '-'),
                esc.final_byte,
            });
        },
    }
}

fn charsetFromByte(b: u8) term_mod.CharsetType {
    return switch (b) {
        '0' => .dec_graphics,
        else => .us_ascii, // 'B' (US ASCII) and all others default to ASCII
    };
}

fn handleNonPrivateMode(csi: CsiAction, term: *Term, set: bool) void {
    const p = csi.params;
    const pc = csi.param_count;
    var idx: u8 = 0;
    while (idx < pc) : (idx += 1) {
        switch (p[idx]) {
            4 => term.insert_mode = set, // IRM — Insert/Replace Mode
            20 => term.linefeed_mode = set, // LNM — Linefeed/Newline Mode
            else => {},
        }
    }
}

fn queryDecMode(term: *const Term, mode: u16) u8 {
    // Returns: 1=set, 2=reset, 0=not recognized
    return switch (mode) {
        1 => if (term.decckm) @as(u8, 1) else 2,
        6 => if (term.origin_mode) @as(u8, 1) else 2,
        7 => if (term.decawm) @as(u8, 1) else 2,
        25 => if (term.cursor_visible) @as(u8, 1) else 2,
        47, 1047, 1049 => if (term.is_alt_screen) @as(u8, 1) else 2,
        67 => if (term.decbkm) @as(u8, 1) else 2,
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

fn saveDECModes(csi: CsiAction, term: *Term) void {
    const pc = csi.param_count;
    term.saved_dec_mode_count = 0;
    var i: u8 = 0;
    while (i < pc and term.saved_dec_mode_count < 32) : (i += 1) {
        const mode = csi.params[i];
        const value = queryDecMode(term, mode) == 1;
        term.saved_dec_modes[term.saved_dec_mode_count] = .{ .mode = mode, .value = value };
        term.saved_dec_mode_count += 1;
    }
}

fn restoreDECModes(csi: CsiAction, term: *Term) void {
    _ = csi;
    for (0..term.saved_dec_mode_count) |idx| {
        const saved = term.saved_dec_modes[idx];
        var restore_csi = CsiAction{};
        restore_csi.params[0] = saved.mode;
        restore_csi.param_count = 1;
        handleDecSet(restore_csi, term, saved.value);
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

test "Executor: TrueColor bulk ASCII preserves RGB" {
    var t = try Term.init(testing.allocator, 80, 24);
    defer t.deinit();
    var parser = Parser{};

    const input = "\x1b[38;2;255;128;0mABCDE";
    feedBulk(&parser, input, &t, null);

    for (0..5) |x| {
        const rgb = t.getFgRgb(@intCast(x), 0);
        try testing.expect(rgb != null);
        try testing.expectEqual([3]u8{ 255, 128, 0 }, rgb.?);
    }
}

test "OSC: title set via OSC 0" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b]0;Hello\x07") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    try testing.expectEqualSlices(u8, "Hello", term.title[0..term.title_len]);
}

test "OSC: title set via OSC 2 with ST terminator" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    for ("\x1b]2;World\x1b\\") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    try testing.expectEqualSlices(u8, "World", term.title[0..term.title_len]);
}

test "Executor: malformed SGR 38;5;999 does not panic" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    // Set a known fg color first
    term.current_fg = 7;
    // Feed \e[38;5;999m — color index > 255, should be silently ignored
    for ("\x1b[38;5;999m") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // fg should remain unchanged
    try testing.expectEqual(@as(u8, 7), term.current_fg);
}

test "Executor: malformed SGR 48;2;256;0;0 does not panic" {
    var term = try Term.init(testing.allocator, 80, 24);
    defer term.deinit();
    var parser = Parser{};
    term.current_bg_rgb = null;
    // Feed \e[48;2;256;0;0m — r > 255, should be silently ignored
    for ("\x1b[48;2;256;0;0m") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // bg_rgb should remain null (not set)
    try testing.expectEqual(@as(?[3]u8, null), term.current_bg_rgb);
}

test "Executor: wide char overwrite clears orphaned dummy" {
    // Scenario: "aあいう" → delete 'a' → shell reprints あいう shifted left by 1.
    // Each wide char write at cursor_x must clear the dummy at cursor_x+2
    // when cursor_x+1 holds a wide cell (left half of the OLD pair).
    var term = try Term.init(testing.allocator, 10, 4);
    defer term.deinit();
    var parser = Parser{};

    // Write "aあいう" — a=col0, あ=col1-2, い=col3-4, う=col5-6
    for ("a") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // Write あ (U+3042 = E3 81 82)
    for ("\xe3\x81\x82") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // Write い (U+3044 = E3 81 84)
    for ("\xe3\x81\x84") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // Write う (U+3046 = E3 81 86)
    for ("\xe3\x81\x86") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }

    // Verify initial layout: a=0, あ=1-2, い=3-4, う=5-6
    const phys = term.row_map[0];
    const base = @as(usize, phys) * @as(usize, term.cols);
    try testing.expectEqual(@as(u21, 'a'), term.cells[base + 0].char);
    try testing.expectEqual(@as(u21, 0x3042), term.cells[base + 1].char);
    try testing.expect(term.cells[base + 1].attrs.wide);
    try testing.expect(term.cells[base + 2].attrs.wide_dummy);
    try testing.expectEqual(@as(u21, 0x3044), term.cells[base + 3].char);
    try testing.expect(term.cells[base + 3].attrs.wide);
    try testing.expect(term.cells[base + 4].attrs.wide_dummy);

    // Now simulate shell reprinting after deleting 'a':
    // Move cursor to col 0, then print あいう (shifted left by 1)
    // CSI 1 G = move cursor to column 1 (0-based: col 0)
    for ("\x1b[1G") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    try testing.expectEqual(@as(u32, 0), term.cursor_x);

    // Print あ at col 0 (overwrites 'a' at col 0, dummy goes to col 1)
    for ("\xe3\x81\x82") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // Print い at col 2
    for ("\xe3\x81\x84") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // Print う at col 4
    for ("\xe3\x81\x86") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }
    // Print space at col 6 to clear trailing
    for (" ") |byte| {
        const action = parser.feed(byte);
        executeAction(action, &term);
    }

    // Verify: あ=0-1, い=2-3, う=4-5, space=6
    try testing.expectEqual(@as(u21, 0x3042), term.cells[base + 0].char);
    try testing.expect(term.cells[base + 0].attrs.wide);
    try testing.expect(term.cells[base + 1].attrs.wide_dummy);

    try testing.expectEqual(@as(u21, 0x3044), term.cells[base + 2].char);
    try testing.expect(term.cells[base + 2].attrs.wide);
    try testing.expect(term.cells[base + 3].attrs.wide_dummy);

    try testing.expectEqual(@as(u21, 0x3046), term.cells[base + 4].char);
    try testing.expect(term.cells[base + 4].attrs.wide);
    try testing.expect(term.cells[base + 5].attrs.wide_dummy);

    // Col 6 must NOT be an orphaned wide_dummy
    try testing.expect(!term.cells[base + 6].attrs.wide_dummy);
}
