const std = @import("std");

pub fn main() !void {
    std.debug.print("zt: starting\n", .{});
}

test {
    _ = @import("font.zig");
    _ = @import("term.zig");
}
