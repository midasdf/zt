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

pub const Keymap = enum {
    us,
    jp,
};

pub const keymap: Keymap = if (build_options.use_jp_keymap) .jp else .us;

pub const shell = "/bin/fish";
