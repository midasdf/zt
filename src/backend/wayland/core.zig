/// Wayland core protocol: globals, SHM buffer management, surface helpers.
///
/// Handles wl_display, wl_registry, wl_compositor, wl_shm, wl_shm_pool,
/// wl_buffer, and wl_surface interactions.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const wire = @import("wire.zig");

// ============================================================================
// Protocol opcodes
// ============================================================================

// wl_display (object id = 1)
pub const WL_DISPLAY_SYNC: u16 = 0;
pub const WL_DISPLAY_GET_REGISTRY: u16 = 1;
pub const WL_DISPLAY_EVENT_ERROR: u16 = 0;
pub const WL_DISPLAY_EVENT_DELETE_ID: u16 = 1;

// wl_registry
pub const WL_REGISTRY_BIND: u16 = 0;
pub const WL_REGISTRY_EVENT_GLOBAL: u16 = 0;
pub const WL_REGISTRY_EVENT_GLOBAL_REMOVE: u16 = 1;

// wl_callback
pub const WL_CALLBACK_EVENT_DONE: u16 = 0;

// wl_compositor
pub const WL_COMPOSITOR_CREATE_SURFACE: u16 = 0;

// wl_surface
pub const WL_SURFACE_DESTROY: u16 = 0;
pub const WL_SURFACE_ATTACH: u16 = 1;
pub const WL_SURFACE_DAMAGE: u16 = 2;
pub const WL_SURFACE_COMMIT: u16 = 6;
pub const WL_SURFACE_SET_BUFFER_SCALE: u16 = 8;
pub const WL_SURFACE_DAMAGE_BUFFER: u16 = 9;

// wl_shm
pub const WL_SHM_CREATE_POOL: u16 = 0;
pub const WL_SHM_EVENT_FORMAT: u16 = 0;

// wl_shm_pool
pub const WL_SHM_POOL_CREATE_BUFFER: u16 = 0;
pub const WL_SHM_POOL_DESTROY: u16 = 1;
pub const WL_SHM_POOL_RESIZE: u16 = 2;

// wl_buffer
pub const WL_BUFFER_EVENT_RELEASE: u16 = 0;

// SHM pixel format
pub const SHM_FORMAT_ARGB8888: u32 = 0;
pub const SHM_FORMAT_XRGB8888: u32 = 1;

// ============================================================================
// Globals — registry names + bound object IDs
// ============================================================================

pub const Globals = struct {
    // Registry global names (numeric IDs from wl_registry.global events)
    compositor_id: u32 = 0,
    shm_id: u32 = 0,
    xdg_wm_base_id: u32 = 0,
    seat_id: u32 = 0,
    data_device_manager_id: u32 = 0,
    text_input_manager_id: u32 = 0,
    decoration_manager_id: u32 = 0,
    primary_selection_manager_id: u32 = 0,
    cursor_shape_manager_id: u32 = 0,

    // Bound object IDs (allocated via id_alloc and bound via registry.bind)
    compositor: u32 = 0,
    shm: u32 = 0,
    xdg_wm_base: u32 = 0,
    seat: u32 = 0,
    data_device_manager: u32 = 0,
    text_input_manager: u32 = 0,
    decoration_manager: u32 = 0,
    primary_selection_manager: u32 = 0,
    cursor_shape_manager: u32 = 0,

    // Surface created via compositor
    surface: u32 = 0,

    // Supported pixel formats
    argb8888_supported: bool = false,
};

// ============================================================================
// wl_display requests
// ============================================================================

/// Send wl_display.get_registry — returns the allocated registry object ID.
pub fn getRegistry(conn: *wire.Connection) !u32 {
    const registry_id = conn.id_alloc.next();
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, registry_id);
    try conn.sendMessage(1, WL_DISPLAY_GET_REGISTRY, payload[0..pos], &.{});
    return registry_id;
}

/// Send wl_display.sync — returns the allocated callback object ID.
pub fn sync(conn: *wire.Connection) !u32 {
    const callback_id = conn.id_alloc.next();
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, callback_id);
    try conn.sendMessage(1, WL_DISPLAY_SYNC, payload[0..pos], &.{});
    return callback_id;
}

// ============================================================================
// Registry event handling
// ============================================================================

/// Parse a wl_registry.global event payload and store the name in globals.
/// Interface names recognized:
///   wl_compositor, wl_shm, xdg_wm_base, wl_seat,
///   wl_data_device_manager, zwp_text_input_manager_v3,
///   zxdg_decoration_manager_v1, zwp_primary_selection_device_manager_v1,
///   wp_cursor_shape_manager_v1
pub fn handleRegistryGlobal(
    globals: *Globals,
    payload: []const u8,
) void {
    var pos: usize = 0;
    const name = wire.getUint(payload, &pos);
    const interface = wire.getString(payload, &pos);
    // version field — consume but ignore for now
    _ = wire.getUint(payload, &pos);

    if (std.mem.eql(u8, interface, "wl_compositor")) {
        globals.compositor_id = name;
    } else if (std.mem.eql(u8, interface, "wl_shm")) {
        globals.shm_id = name;
    } else if (std.mem.eql(u8, interface, "xdg_wm_base")) {
        globals.xdg_wm_base_id = name;
    } else if (std.mem.eql(u8, interface, "wl_seat")) {
        globals.seat_id = name;
    } else if (std.mem.eql(u8, interface, "wl_data_device_manager")) {
        globals.data_device_manager_id = name;
    } else if (std.mem.eql(u8, interface, "zwp_text_input_manager_v3")) {
        globals.text_input_manager_id = name;
    } else if (std.mem.eql(u8, interface, "zxdg_decoration_manager_v1")) {
        globals.decoration_manager_id = name;
    } else if (std.mem.eql(u8, interface, "zwp_primary_selection_device_manager_v1")) {
        globals.primary_selection_manager_id = name;
    } else if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1")) {
        globals.cursor_shape_manager_id = name;
    }
}

/// Bind all discovered globals using registry.bind.
/// wl_registry.bind new_id encoding:
///   putUint(name) + putString(interface) + putUint(version) + putUint(new_id)
pub fn bindGlobals(
    conn: *wire.Connection,
    globals: *Globals,
    registry_id: u32,
) !void {
    if (globals.compositor_id != 0) {
        globals.compositor = try bindOne(conn, registry_id, globals.compositor_id, "wl_compositor", 4);
    }
    if (globals.shm_id != 0) {
        globals.shm = try bindOne(conn, registry_id, globals.shm_id, "wl_shm", 1);
    }
    if (globals.xdg_wm_base_id != 0) {
        globals.xdg_wm_base = try bindOne(conn, registry_id, globals.xdg_wm_base_id, "xdg_wm_base", 2);
    }
    if (globals.seat_id != 0) {
        globals.seat = try bindOne(conn, registry_id, globals.seat_id, "wl_seat", 7);
    }
    if (globals.data_device_manager_id != 0) {
        globals.data_device_manager = try bindOne(conn, registry_id, globals.data_device_manager_id, "wl_data_device_manager", 3);
    }
    if (globals.text_input_manager_id != 0) {
        globals.text_input_manager = try bindOne(conn, registry_id, globals.text_input_manager_id, "zwp_text_input_manager_v3", 1);
    }
    if (globals.decoration_manager_id != 0) {
        globals.decoration_manager = try bindOne(conn, registry_id, globals.decoration_manager_id, "zxdg_decoration_manager_v1", 1);
    }
    if (globals.primary_selection_manager_id != 0) {
        globals.primary_selection_manager = try bindOne(conn, registry_id, globals.primary_selection_manager_id, "zwp_primary_selection_device_manager_v1", 1);
    }
    if (globals.cursor_shape_manager_id != 0) {
        globals.cursor_shape_manager = try bindOne(conn, registry_id, globals.cursor_shape_manager_id, "wp_cursor_shape_manager_v1", 1);
    }
}

/// Bind a single global.  Returns the new object ID.
fn bindOne(
    conn: *wire.Connection,
    registry_id: u32,
    global_name: u32,
    interface: []const u8,
    version: u32,
) !u32 {
    const new_id = conn.id_alloc.next();
    // wl_registry.bind payload: name(u32) + interface(string) + version(u32) + new_id(u32)
    var payload: [256]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, global_name);
    wire.putString(&payload, &pos, interface);
    wire.putUint(&payload, &pos, version);
    wire.putUint(&payload, &pos, new_id);
    try conn.sendMessage(registry_id, WL_REGISTRY_BIND, payload[0..pos], &.{});
    return new_id;
}

// ============================================================================
// wl_display error event
// ============================================================================

pub const DisplayError = error{WaylandDisplayError};

/// Parse and log a wl_display.error event, then return an error.
pub fn handleDisplayError(payload: []const u8) DisplayError {
    var pos: usize = 0;
    const object_id = wire.getUint(payload, &pos);
    const code = wire.getUint(payload, &pos);
    const message = wire.getString(payload, &pos);
    std.log.err("wl_display error: object_id={d} code={d} message={s}", .{ object_id, code, message });
    return error.WaylandDisplayError;
}

// ============================================================================
// wl_compositor
// ============================================================================

/// Send wl_compositor.create_surface — returns the new surface object ID.
pub fn createSurface(conn: *wire.Connection, compositor_id: u32) !u32 {
    const surface_id = conn.id_alloc.next();
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, surface_id);
    try conn.sendMessage(compositor_id, WL_COMPOSITOR_CREATE_SURFACE, payload[0..pos], &.{});
    return surface_id;
}

// ============================================================================
// wl_surface helpers
// ============================================================================

/// wl_surface.attach(buffer_id, x=0, y=0)
pub fn surfaceAttach(conn: *wire.Connection, surface_id: u32, buffer_id: u32) !void {
    var payload: [12]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, buffer_id);
    wire.putInt(&payload, &pos, 0); // x
    wire.putInt(&payload, &pos, 0); // y
    try conn.sendMessage(surface_id, WL_SURFACE_ATTACH, payload[0..pos], &.{});
}

/// wl_surface.damage_buffer(x, y, width, height)
pub fn surfaceDamageBuffer(
    conn: *wire.Connection,
    surface_id: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
) !void {
    var payload: [16]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&payload, &pos, x);
    wire.putInt(&payload, &pos, y);
    wire.putInt(&payload, &pos, w);
    wire.putInt(&payload, &pos, h);
    try conn.sendMessage(surface_id, WL_SURFACE_DAMAGE_BUFFER, payload[0..pos], &.{});
}

/// wl_surface.commit (empty payload)
pub fn surfaceCommit(conn: *wire.Connection, surface_id: u32) !void {
    try conn.sendMessage(surface_id, WL_SURFACE_COMMIT, &.{}, &.{});
}

/// wl_surface.set_buffer_scale(scale)
pub fn surfaceSetBufferScale(conn: *wire.Connection, surface_id: u32, scale: i32) !void {
    var payload: [4]u8 = undefined;
    var pos: usize = 0;
    wire.putInt(&payload, &pos, scale);
    try conn.sendMessage(surface_id, WL_SURFACE_SET_BUFFER_SCALE, payload[0..pos], &.{});
}

// ============================================================================
// SHM buffer management
// ============================================================================

pub const ShmBuffer = struct {
    pool_id: u32,
    buffer_ids: [2]u32,
    fd: posix.fd_t,
    data: []align(4096) u8,
    width: u32,
    height: u32,
    stride: u32,
    page_size: usize,
    pool_capacity: usize,
    current: u1 = 0,
    released: [2]bool = .{ true, true },

    /// Return the pixel data slice for the current back buffer.
    pub fn getPixels(self: *ShmBuffer) []u8 {
        const offset = @as(usize, self.current) * self.page_size;
        return self.data[offset .. offset + self.page_size];
    }

    pub fn deinit(self: *ShmBuffer) void {
        posix.munmap(self.data);
        posix.close(self.fd);
    }

    /// Destroy server-side resources (buffers + pool).
    /// Object IDs are NOT released here — they are recycled when the
    /// compositor sends wl_display.delete_id, handled in dispatchEvent.
    pub fn destroyRemote(self: *ShmBuffer, conn: *wire.Connection) void {
        for (self.buffer_ids) |buf_id| {
            conn.sendMessage(buf_id, 0, &.{}, &.{}) catch {};
        }
        conn.sendMessage(self.pool_id, WL_SHM_POOL_DESTROY, &.{}, &.{}) catch {};
    }

    /// Resize buffers in-place, reusing the existing SHM pool.
    /// Only grows the pool (via wl_shm_pool.resize) — never shrinks.
    /// This avoids pool ID churn and fd-based sendMessage (which forces
    /// a mid-resize flush that can cause protocol ordering issues).
    pub fn resizeBuffers(self: *ShmBuffer, conn: *wire.Connection, width: u32, height: u32) !void {
        const new_stride = width * 4;
        const raw_size = @as(usize, new_stride) * @as(usize, height);
        const page_sz = std.heap.pageSize();
        const new_page_size = std.mem.alignForward(usize, raw_size, page_sz);
        const new_total_size = new_page_size * 2;

        // 1. Destroy old wl_buffer objects
        for (self.buffer_ids) |buf_id| {
            conn.sendMessage(buf_id, 0, &.{}, &.{}) catch {};
        }

        // 2. Grow pool if needed
        if (new_total_size > self.pool_capacity) {
            try posix.ftruncate(self.fd, @intCast(new_total_size));
            // mmap new region BEFORE munmap to avoid dangling pointer on failure
            const new_data = try posix.mmap(
                null,
                new_total_size,
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                self.fd,
                0,
            );
            posix.munmap(self.data);
            self.data = new_data;
            var payload: [4]u8 = undefined;
            var pos: usize = 0;
            wire.putInt(&payload, &pos, @intCast(new_total_size));
            try conn.sendMessage(self.pool_id, WL_SHM_POOL_RESIZE, payload[0..pos], &.{});
            self.pool_capacity = new_total_size;
        }

        // 3. Create new buffers in the same pool
        self.buffer_ids = [2]u32{
            conn.id_alloc.next(),
            conn.id_alloc.next(),
        };
        for (self.buffer_ids, 0..) |buf_id, i| {
            const offset: i32 = @intCast(@as(usize, i) * new_page_size);
            var payload: [24]u8 = undefined;
            var pos: usize = 0;
            wire.putUint(&payload, &pos, buf_id);
            wire.putInt(&payload, &pos, offset);
            wire.putInt(&payload, &pos, @intCast(width));
            wire.putInt(&payload, &pos, @intCast(height));
            wire.putInt(&payload, &pos, @intCast(new_stride));
            wire.putUint(&payload, &pos, SHM_FORMAT_ARGB8888);
            try conn.sendMessage(self.pool_id, WL_SHM_POOL_CREATE_BUFFER, payload[0..pos], &.{});
        }

        // 4. Update state
        self.width = width;
        self.height = height;
        self.stride = new_stride;
        self.page_size = new_page_size;
        self.current = 0;
        self.released = .{ true, true };
    }
};

/// Create a double-buffered SHM buffer.
///
/// Layout in the memfd:
///   [page 0: buffer 0 pixels][page 1: buffer 1 pixels]
///
/// Each page is page_size = stride * height, rounded up to a page boundary.
pub fn createShmBuffers(
    conn: *wire.Connection,
    globals: *Globals,
    width: u32,
    height: u32,
) !ShmBuffer {
    const stride = width * 4; // ARGB8888 = 4 bytes per pixel
    const raw_size = @as(usize, stride) * @as(usize, height);
    const page_sz = std.heap.pageSize();
    const page_size = std.mem.alignForward(usize, raw_size, page_sz);
    const total_size = page_size * 2;

    // Create anonymous shared memory via memfd_create
    const memfd_name = "zt-shm";
    const fd_rc = linux.syscall2(
        linux.SYS.memfd_create,
        @intFromPtr(memfd_name.ptr),
        linux.MFD.CLOEXEC,
    );
    const fd_isize: isize = @bitCast(fd_rc);
    if (fd_isize < 0) return error.MemfdCreateFailed;
    const fd: posix.fd_t = @intCast(fd_isize);
    errdefer posix.close(fd);

    // Size the memfd
    try posix.ftruncate(fd, @intCast(total_size));

    // mmap both pages
    const data_ptr = try posix.mmap(
        null,
        total_size,
        posix.PROT.READ | posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer posix.munmap(data_ptr);

    // wl_shm.create_pool(new_id, fd, size)
    // fd is sent via SCM_RIGHTS — zero bytes in payload for the fd argument
    const pool_id = conn.id_alloc.next();
    {
        var payload: [8]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&payload, &pos, pool_id);
        wire.putInt(&payload, &pos, @intCast(total_size));
        try conn.sendMessage(globals.shm, WL_SHM_CREATE_POOL, payload[0..pos], &[_]posix.fd_t{fd});
    }

    // wl_shm_pool.create_buffer for each page
    const buf_ids = [2]u32{
        conn.id_alloc.next(),
        conn.id_alloc.next(),
    };
    for (buf_ids, 0..) |buf_id, i| {
        const offset: i32 = @intCast(@as(usize, i) * page_size);
        var payload: [24]u8 = undefined;
        var pos: usize = 0;
        wire.putUint(&payload, &pos, buf_id);
        wire.putInt(&payload, &pos, offset);
        wire.putInt(&payload, &pos, @intCast(width));
        wire.putInt(&payload, &pos, @intCast(height));
        wire.putInt(&payload, &pos, @intCast(stride));
        wire.putUint(&payload, &pos, SHM_FORMAT_ARGB8888);
        try conn.sendMessage(pool_id, WL_SHM_POOL_CREATE_BUFFER, payload[0..pos], &.{});
    }

    return ShmBuffer{
        .pool_id = pool_id,
        .buffer_ids = buf_ids,
        .fd = fd,
        .data = data_ptr,
        .width = width,
        .height = height,
        .stride = stride,
        .page_size = page_size,
        .pool_capacity = total_size,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "handleRegistryGlobal — compositor" {
    var globals = Globals{};
    // Encode a synthetic global event: name=5, interface="wl_compositor", version=4
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, 5);
    wire.putString(&payload, &pos, "wl_compositor");
    wire.putUint(&payload, &pos, 4);
    handleRegistryGlobal(&globals, payload[0..pos]);
    try std.testing.expectEqual(@as(u32, 5), globals.compositor_id);
}

test "handleRegistryGlobal — xdg_wm_base" {
    var globals = Globals{};
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, 7);
    wire.putString(&payload, &pos, "xdg_wm_base");
    wire.putUint(&payload, &pos, 2);
    handleRegistryGlobal(&globals, payload[0..pos]);
    try std.testing.expectEqual(@as(u32, 7), globals.xdg_wm_base_id);
}

test "handleRegistryGlobal — unknown interface is ignored" {
    var globals = Globals{};
    var payload: [64]u8 = undefined;
    var pos: usize = 0;
    wire.putUint(&payload, &pos, 99);
    wire.putString(&payload, &pos, "wl_unknown_v42");
    wire.putUint(&payload, &pos, 1);
    handleRegistryGlobal(&globals, payload[0..pos]);
    // Nothing should be set
    try std.testing.expectEqual(@as(u32, 0), globals.compositor_id);
}
