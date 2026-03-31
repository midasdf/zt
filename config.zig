const build_options = @import("build_options");

pub const Backend = enum {
    fbdev,
    x11,
};

pub const backend: Backend = if (build_options.use_x11) .x11 else .fbdev;

pub const default_fg: u8 = 7;
pub const default_bg: u8 = 0;

pub const font_width: u32 = 8;
pub const font_height: u32 = 16;

pub const scale: u32 = build_options.scale;
pub const cell_width: u32 = font_width * scale;
pub const cell_height: u32 = font_height * scale;

comptime {
    if (scale != 1 and scale != 2 and scale != 4) {
        @compileError("scale must be 1, 2, or 4");
    }
}

pub const Keymap = enum {
    us,
    jp,
};

pub const keymap: Keymap = if (build_options.use_jp_keymap) .jp else .us;

pub const max_fps: u32 = build_options.max_fps;

/// Minimum nanoseconds between frames. 0 = unlimited.
pub const frame_min_ns: u64 = if (max_fps == 0) 0 else 1_000_000_000 / max_fps;
pub const pty_buf_size: u32 = build_options.pty_buf_kb * 1024;

pub const shell: [:0]const u8 = @ptrCast(build_options.shell);
