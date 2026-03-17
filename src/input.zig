const std = @import("std");
const testing = std.testing;

/// Linux evdev keycodes (from linux/input-event-codes.h).
/// Defined here to avoid libc dependency.
pub const KEY = struct {
    pub const ESC = 1;
    pub const @"1" = 2;
    pub const @"2" = 3;
    pub const @"3" = 4;
    pub const @"4" = 5;
    pub const @"5" = 6;
    pub const @"6" = 7;
    pub const @"7" = 8;
    pub const @"8" = 9;
    pub const @"9" = 10;
    pub const @"0" = 11;
    pub const MINUS = 12;
    pub const EQUAL = 13;
    pub const BACKSPACE = 14;
    pub const TAB = 15;
    pub const Q = 16;
    pub const W = 17;
    pub const E = 18;
    pub const R = 19;
    pub const T = 20;
    pub const Y = 21;
    pub const U = 22;
    pub const I = 23;
    pub const O = 24;
    pub const P = 25;
    pub const LEFTBRACE = 26;
    pub const RIGHTBRACE = 27;
    pub const ENTER = 28;
    pub const A = 30;
    pub const S = 31;
    pub const D = 32;
    pub const F = 33;
    pub const G = 34;
    pub const H = 35;
    pub const J = 36;
    pub const K = 37;
    pub const L = 38;
    pub const SEMICOLON = 39;
    pub const APOSTROPHE = 40;
    pub const GRAVE = 41;
    pub const BACKSLASH = 43;
    pub const Z = 44;
    pub const X = 45;
    pub const C = 46;
    pub const V = 47;
    pub const B = 48;
    pub const N = 49;
    pub const M = 50;
    pub const COMMA = 51;
    pub const DOT = 52;
    pub const SLASH = 53;
    pub const SPACE = 57;
    pub const F1 = 59;
    pub const F2 = 60;
    pub const F3 = 61;
    pub const F4 = 62;
    pub const F5 = 63;
    pub const F6 = 64;
    pub const F7 = 65;
    pub const F8 = 66;
    pub const F9 = 67;
    pub const F10 = 68;
    pub const F11 = 87;
    pub const F12 = 88;
    pub const HOME = 102;
    pub const UP = 103;
    pub const PAGEUP = 104;
    pub const LEFT = 105;
    pub const RIGHT = 106;
    pub const END = 107;
    pub const DOWN = 108;
    pub const PAGEDOWN = 109;
    pub const INSERT = 110;
    pub const DELETE = 111;
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    meta: bool = false,
    _pad: u4 = 0,
};

const KeyEntry = struct {
    normal: u8,
    shifted: u8,
};

/// US QWERTY keymap: keycode -> (normal, shifted) character.
const keymap: [256]?KeyEntry = buildKeymap();

fn buildKeymap() [256]?KeyEntry {
    var map = [_]?KeyEntry{null} ** 256;
    // Letters
    map[KEY.A] = .{ .normal = 'a', .shifted = 'A' };
    map[KEY.B] = .{ .normal = 'b', .shifted = 'B' };
    map[KEY.C] = .{ .normal = 'c', .shifted = 'C' };
    map[KEY.D] = .{ .normal = 'd', .shifted = 'D' };
    map[KEY.E] = .{ .normal = 'e', .shifted = 'E' };
    map[KEY.F] = .{ .normal = 'f', .shifted = 'F' };
    map[KEY.G] = .{ .normal = 'g', .shifted = 'G' };
    map[KEY.H] = .{ .normal = 'h', .shifted = 'H' };
    map[KEY.I] = .{ .normal = 'i', .shifted = 'I' };
    map[KEY.J] = .{ .normal = 'j', .shifted = 'J' };
    map[KEY.K] = .{ .normal = 'k', .shifted = 'K' };
    map[KEY.L] = .{ .normal = 'l', .shifted = 'L' };
    map[KEY.M] = .{ .normal = 'm', .shifted = 'M' };
    map[KEY.N] = .{ .normal = 'n', .shifted = 'N' };
    map[KEY.O] = .{ .normal = 'o', .shifted = 'O' };
    map[KEY.P] = .{ .normal = 'p', .shifted = 'P' };
    map[KEY.Q] = .{ .normal = 'q', .shifted = 'Q' };
    map[KEY.R] = .{ .normal = 'r', .shifted = 'R' };
    map[KEY.S] = .{ .normal = 's', .shifted = 'S' };
    map[KEY.T] = .{ .normal = 't', .shifted = 'T' };
    map[KEY.U] = .{ .normal = 'u', .shifted = 'U' };
    map[KEY.V] = .{ .normal = 'v', .shifted = 'V' };
    map[KEY.W] = .{ .normal = 'w', .shifted = 'W' };
    map[KEY.X] = .{ .normal = 'x', .shifted = 'X' };
    map[KEY.Y] = .{ .normal = 'y', .shifted = 'Y' };
    map[KEY.Z] = .{ .normal = 'z', .shifted = 'Z' };
    // Numbers
    map[KEY.@"1"] = .{ .normal = '1', .shifted = '!' };
    map[KEY.@"2"] = .{ .normal = '2', .shifted = '@' };
    map[KEY.@"3"] = .{ .normal = '3', .shifted = '#' };
    map[KEY.@"4"] = .{ .normal = '4', .shifted = '$' };
    map[KEY.@"5"] = .{ .normal = '5', .shifted = '%' };
    map[KEY.@"6"] = .{ .normal = '6', .shifted = '^' };
    map[KEY.@"7"] = .{ .normal = '7', .shifted = '&' };
    map[KEY.@"8"] = .{ .normal = '8', .shifted = '*' };
    map[KEY.@"9"] = .{ .normal = '9', .shifted = '(' };
    map[KEY.@"0"] = .{ .normal = '0', .shifted = ')' };
    // Symbols
    map[KEY.MINUS] = .{ .normal = '-', .shifted = '_' };
    map[KEY.EQUAL] = .{ .normal = '=', .shifted = '+' };
    map[KEY.LEFTBRACE] = .{ .normal = '[', .shifted = '{' };
    map[KEY.RIGHTBRACE] = .{ .normal = ']', .shifted = '}' };
    map[KEY.SEMICOLON] = .{ .normal = ';', .shifted = ':' };
    map[KEY.APOSTROPHE] = .{ .normal = '\'', .shifted = '"' };
    map[KEY.GRAVE] = .{ .normal = '`', .shifted = '~' };
    map[KEY.BACKSLASH] = .{ .normal = '\\', .shifted = '|' };
    map[KEY.COMMA] = .{ .normal = ',', .shifted = '<' };
    map[KEY.DOT] = .{ .normal = '.', .shifted = '>' };
    map[KEY.SLASH] = .{ .normal = '/', .shifted = '?' };
    return map;
}

/// xterm-style modifier parameter value for CSI sequences.
/// shift=2, alt=3, shift+alt=4, ctrl=5, shift+ctrl=6, alt+ctrl=7, shift+alt+ctrl=8
fn modParam(mods: Modifiers) u8 {
    var val: u8 = 1;
    if (mods.shift) val += 1;
    if (mods.alt) val += 2;
    if (mods.ctrl) val += 4;
    return val;
}

/// Special key escape sequence definitions.
const SpecialKey = struct {
    /// Normal mode sequence (DECCKM off).
    normal: []const u8,
    /// Application mode sequence (DECCKM on), null = same as normal.
    app: ?[]const u8 = null,
    /// For tilde-style keys: the number before '~' (e.g., 3 for Delete = CSI 3 ~).
    /// Used to construct modified sequences like CSI 3;5~ for Ctrl+Delete.
    tilde_num: ?u8 = null,
    /// For letter-style keys: the final letter (e.g., 'A' for Up).
    /// Used to construct modified sequences like CSI 1;5A for Ctrl+Up.
    final_letter: ?u8 = null,
};

fn getSpecialKey(kc: u16) ?SpecialKey {
    return switch (kc) {
        // Arrow keys
        KEY.UP => .{ .normal = "\x1b[A", .app = "\x1bOA", .final_letter = 'A' },
        KEY.DOWN => .{ .normal = "\x1b[B", .app = "\x1bOB", .final_letter = 'B' },
        KEY.RIGHT => .{ .normal = "\x1b[C", .app = "\x1bOC", .final_letter = 'C' },
        KEY.LEFT => .{ .normal = "\x1b[D", .app = "\x1bOD", .final_letter = 'D' },
        // Navigation
        KEY.HOME => .{ .normal = "\x1b[H", .app = "\x1bOH", .final_letter = 'H' },
        KEY.END => .{ .normal = "\x1b[F", .app = "\x1bOF", .final_letter = 'F' },
        KEY.INSERT => .{ .normal = "\x1b[2~", .tilde_num = 2 },
        KEY.DELETE => .{ .normal = "\x1b[3~", .tilde_num = 3 },
        KEY.PAGEUP => .{ .normal = "\x1b[5~", .tilde_num = 5 },
        KEY.PAGEDOWN => .{ .normal = "\x1b[6~", .tilde_num = 6 },
        // Function keys
        KEY.F1 => .{ .normal = "\x1bOP", .final_letter = 'P' },
        KEY.F2 => .{ .normal = "\x1bOQ", .final_letter = 'Q' },
        KEY.F3 => .{ .normal = "\x1bOR", .final_letter = 'R' },
        KEY.F4 => .{ .normal = "\x1bOS", .final_letter = 'S' },
        KEY.F5 => .{ .normal = "\x1b[15~", .tilde_num = 15 },
        KEY.F6 => .{ .normal = "\x1b[17~", .tilde_num = 17 },
        KEY.F7 => .{ .normal = "\x1b[18~", .tilde_num = 18 },
        KEY.F8 => .{ .normal = "\x1b[19~", .tilde_num = 19 },
        KEY.F9 => .{ .normal = "\x1b[20~", .tilde_num = 20 },
        KEY.F10 => .{ .normal = "\x1b[21~", .tilde_num = 21 },
        KEY.F11 => .{ .normal = "\x1b[23~", .tilde_num = 23 },
        KEY.F12 => .{ .normal = "\x1b[24~", .tilde_num = 24 },
        else => null,
    };
}

/// Translate a Linux evdev keycode + modifiers into bytes to write to the PTY.
/// Returns a slice into a static buffer (valid until the next call).
pub fn translateKey(keycode: u16, mods: Modifiers, decckm: bool) []const u8 {
    const S = struct {
        var buf: [32]u8 = undefined;
    };

    // --- Simple special keys (Enter, Backspace, Tab, Esc, Space) ---
    switch (keycode) {
        KEY.ENTER => {
            if (mods.alt) {
                S.buf[0] = 0x1b;
                S.buf[1] = '\r';
                return S.buf[0..2];
            }
            S.buf[0] = '\r';
            return S.buf[0..1];
        },
        KEY.BACKSPACE => {
            if (mods.alt) {
                S.buf[0] = 0x1b;
                S.buf[1] = 0x7f;
                return S.buf[0..2];
            }
            S.buf[0] = 0x7f;
            return S.buf[0..1];
        },
        KEY.TAB => {
            if (mods.shift) {
                // Shift+Tab = reverse tab (CSI Z)
                S.buf[0] = 0x1b;
                S.buf[1] = '[';
                S.buf[2] = 'Z';
                return S.buf[0..3];
            }
            S.buf[0] = '\t';
            return S.buf[0..1];
        },
        KEY.ESC => {
            S.buf[0] = 0x1b;
            return S.buf[0..1];
        },
        KEY.SPACE => {
            if (mods.ctrl) {
                // Ctrl+Space = NUL
                S.buf[0] = 0x00;
                return S.buf[0..1];
            }
            if (mods.alt) {
                S.buf[0] = 0x1b;
                S.buf[1] = ' ';
                return S.buf[0..2];
            }
            S.buf[0] = ' ';
            return S.buf[0..1];
        },
        else => {},
    }

    // --- Special keys (arrows, function keys, navigation) ---
    if (getSpecialKey(keycode)) |sk| {
        const mp = modParam(mods);
        if (mp > 1) {
            // Modified special key: need to construct modified sequence
            if (sk.final_letter) |letter| {
                // CSI 1 ; {mod} {letter}
                S.buf[0] = 0x1b;
                S.buf[1] = '[';
                S.buf[2] = '1';
                S.buf[3] = ';';
                const n = writeU8(S.buf[4..], mp);
                S.buf[4 + n] = letter;
                return S.buf[0 .. 5 + n];
            } else if (sk.tilde_num) |num| {
                // CSI {num} ; {mod} ~
                S.buf[0] = 0x1b;
                S.buf[1] = '[';
                const n1 = writeU8(S.buf[2..], num);
                S.buf[2 + n1] = ';';
                const n2 = writeU8(S.buf[3 + n1 ..], mp);
                S.buf[3 + n1 + n2] = '~';
                return S.buf[0 .. 4 + n1 + n2];
            }
        }
        // Unmodified: use app or normal sequence
        const seq = if (decckm and sk.app != null) sk.app.? else sk.normal;
        @memcpy(S.buf[0..seq.len], seq);
        return S.buf[0..seq.len];
    }

    // --- Printable keys from keymap ---
    if (keycode < 256) {
        if (keymap[keycode]) |entry| {
            // Ctrl+letter (A-Z only)
            if (mods.ctrl and entry.normal >= 'a' and entry.normal <= 'z') {
                const ctrl_char: u8 = entry.normal - 'a' + 1; // 0x01..0x1A
                if (mods.alt) {
                    S.buf[0] = 0x1b;
                    S.buf[1] = ctrl_char;
                    return S.buf[0..2];
                }
                S.buf[0] = ctrl_char;
                return S.buf[0..1];
            }

            const ch: u8 = if (mods.shift) entry.shifted else entry.normal;
            if (mods.alt) {
                S.buf[0] = 0x1b;
                S.buf[1] = ch;
                return S.buf[0..2];
            }
            S.buf[0] = ch;
            return S.buf[0..1];
        }
    }

    // Unknown keycode: return empty
    return S.buf[0..0];
}

/// Write a u8 value as decimal digits into buf. Returns number of bytes written.
fn writeU8(buf: []u8, val: u8) usize {
    if (val >= 100) {
        buf[0] = '0' + val / 100;
        buf[1] = '0' + (val / 10) % 10;
        buf[2] = '0' + val % 10;
        return 3;
    } else if (val >= 10) {
        buf[0] = '0' + val / 10;
        buf[1] = '0' + val % 10;
        return 2;
    } else {
        buf[0] = '0' + val;
        return 1;
    }
}

// ============================================================
// Tests
// ============================================================

test "Input: KEY_A with no mods produces 'a'" {
    const result = translateKey(KEY.A, .{}, false);
    try testing.expectEqualSlices(u8, "a", result);
}

test "Input: KEY_A with shift produces 'A'" {
    const result = translateKey(KEY.A, .{ .shift = true }, false);
    try testing.expectEqualSlices(u8, "A", result);
}

test "Input: KEY_A with ctrl produces 0x01" {
    const result = translateKey(KEY.A, .{ .ctrl = true }, false);
    try testing.expectEqualSlices(u8, &[_]u8{0x01}, result);
}

test "Input: KEY_A with alt produces ESC + 'a'" {
    const result = translateKey(KEY.A, .{ .alt = true }, false);
    try testing.expectEqualSlices(u8, "\x1ba", result);
}

test "Input: KEY_UP with DECCKM off produces CSI A" {
    const result = translateKey(KEY.UP, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[A", result);
}

test "Input: KEY_UP with DECCKM on produces SS3 A" {
    const result = translateKey(KEY.UP, .{}, true);
    try testing.expectEqualSlices(u8, "\x1bOA", result);
}

test "Input: KEY_ENTER produces CR" {
    const result = translateKey(KEY.ENTER, .{}, false);
    try testing.expectEqualSlices(u8, "\r", result);
}

test "Input: KEY_F1 produces SS3 P" {
    const result = translateKey(KEY.F1, .{}, false);
    try testing.expectEqualSlices(u8, "\x1bOP", result);
}

test "Input: KEY_BACKSPACE produces DEL" {
    const result = translateKey(KEY.BACKSPACE, .{}, false);
    try testing.expectEqualSlices(u8, "\x7f", result);
}

test "Input: KEY_HOME produces CSI H" {
    const result = translateKey(KEY.HOME, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[H", result);
}

test "Input: KEY_DELETE produces CSI 3~" {
    const result = translateKey(KEY.DELETE, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[3~", result);
}

test "Input: number key 1 produces '1'" {
    const result = translateKey(KEY.@"1", .{}, false);
    try testing.expectEqualSlices(u8, "1", result);
}

test "Input: number key 1 with shift produces '!'" {
    const result = translateKey(KEY.@"1", .{ .shift = true }, false);
    try testing.expectEqualSlices(u8, "!", result);
}

test "Input: Ctrl+C produces 0x03" {
    const result = translateKey(KEY.C, .{ .ctrl = true }, false);
    try testing.expectEqualSlices(u8, &[_]u8{0x03}, result);
}

test "Input: Ctrl+Space produces NUL" {
    const result = translateKey(KEY.SPACE, .{ .ctrl = true }, false);
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, result);
}

test "Input: Shift+Tab produces CSI Z" {
    const result = translateKey(KEY.TAB, .{ .shift = true }, false);
    try testing.expectEqualSlices(u8, "\x1b[Z", result);
}

test "Input: Ctrl+Up produces modified arrow" {
    const result = translateKey(KEY.UP, .{ .ctrl = true }, false);
    try testing.expectEqualSlices(u8, "\x1b[1;5A", result);
}

test "Input: Shift+Delete produces modified tilde" {
    const result = translateKey(KEY.DELETE, .{ .shift = true }, false);
    try testing.expectEqualSlices(u8, "\x1b[3;2~", result);
}

test "Input: KEY_PAGEUP produces CSI 5~" {
    const result = translateKey(KEY.PAGEUP, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[5~", result);
}

test "Input: KEY_END produces CSI F" {
    const result = translateKey(KEY.END, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[F", result);
}

test "Input: KEY_F5 produces CSI 15~" {
    const result = translateKey(KEY.F5, .{}, false);
    try testing.expectEqualSlices(u8, "\x1b[15~", result);
}

test "Input: Alt+Ctrl+A produces ESC + 0x01" {
    const result = translateKey(KEY.A, .{ .alt = true, .ctrl = true }, false);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x1b, 0x01 }, result);
}

test "Input: symbol keys" {
    try testing.expectEqualSlices(u8, "-", translateKey(KEY.MINUS, .{}, false));
    try testing.expectEqualSlices(u8, "_", translateKey(KEY.MINUS, .{ .shift = true }, false));
    try testing.expectEqualSlices(u8, "=", translateKey(KEY.EQUAL, .{}, false));
    try testing.expectEqualSlices(u8, "+", translateKey(KEY.EQUAL, .{ .shift = true }, false));
    try testing.expectEqualSlices(u8, "[", translateKey(KEY.LEFTBRACE, .{}, false));
    try testing.expectEqualSlices(u8, "{", translateKey(KEY.LEFTBRACE, .{ .shift = true }, false));
    try testing.expectEqualSlices(u8, ";", translateKey(KEY.SEMICOLON, .{}, false));
    try testing.expectEqualSlices(u8, ":", translateKey(KEY.SEMICOLON, .{ .shift = true }, false));
}

test "Input: HOME with DECCKM on produces SS3 H" {
    const result = translateKey(KEY.HOME, .{}, true);
    try testing.expectEqualSlices(u8, "\x1bOH", result);
}

test "Input: unknown keycode returns empty" {
    const result = translateKey(255, .{}, false);
    try testing.expectEqualSlices(u8, "", result);
}
