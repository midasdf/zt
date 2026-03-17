pub const backend: Backend = .fbdev;

pub const Backend = enum {
    fbdev,
    x11,
};

pub const default_fg: u8 = 7;
pub const default_bg: u8 = 0;

pub const font_path = "fonts/default.bdf";
pub const font_width: u32 = 8;
pub const font_height: u32 = 16;

pub const shell = "/bin/sh";
