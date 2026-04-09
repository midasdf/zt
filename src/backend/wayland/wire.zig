/// Wayland wire protocol: encoding, decoding, and connection management.
///
/// Wire format:
///   - All messages are 4-byte aligned
///   - Message header: [object_id: u32][size_opcode: u32]
///     where size_opcode = (total_message_size_in_bytes << 16) | opcode
///   - Arguments follow the header inline, each 4-byte aligned
///   - fd arguments occupy ZERO bytes in the payload (sent via SCM_RIGHTS only)
///   - Strings: 4-byte length (including null terminator) + bytes + null + padding
///   - Arrays: 4-byte length + data + padding to 4-byte boundary

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// cmsg header for SCM_RIGHTS ancillary data.
/// Not exposed by Zig 0.15 std.os.linux, so defined locally.
const cmsghdr = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
};

// ============================================================================
// Header encode / decode
// ============================================================================

pub const Header = struct {
    object_id: u32,
    opcode: u16,
    /// Total message size in bytes, including the 8-byte header.
    size: u16,
};

/// Encode a Wayland message header into two u32 words.
/// size must include the 8-byte header itself.
pub fn encodeHeader(object_id: u32, opcode: u16, size: u16) [2]u32 {
    return .{
        object_id,
        (@as(u32, size) << 16) | @as(u32, opcode),
    };
}

/// Decode a Wayland message header from two u32 words (little-endian host byte order).
pub fn decodeHeader(words: *const [2]u32) Header {
    return .{
        .object_id = words[0],
        .opcode = @truncate(words[1] & 0xFFFF),
        .size = @truncate(words[1] >> 16),
    };
}

/// Round n up to the nearest multiple of alignment (must be a power of 2).
pub fn alignUp(n: usize, alignment: usize) usize {
    return (n + alignment - 1) & ~(alignment - 1);
}

// ============================================================================
// Object ID allocator
// ============================================================================

pub const ObjectIdAllocator = struct {
    /// Next fresh ID to hand out. ID 1 is reserved for wl_display.
    next_id: u32 = 2,
    free_list: [128]u32 = [_]u32{0} ** 128,
    free_count: u32 = 0,

    /// Allocate a new object ID. Reuses freed IDs when available.
    pub fn next(self: *ObjectIdAllocator) u32 {
        if (self.free_count > 0) {
            self.free_count -= 1;
            return self.free_list[self.free_count];
        }
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Return an object ID to the free list (silently drops if list is full).
    pub fn release(self: *ObjectIdAllocator, id: u32) void {
        if (self.free_count < self.free_list.len) {
            self.free_list[self.free_count] = id;
            self.free_count += 1;
        }
    }
};

// ============================================================================
// Argument serialization helpers
// ============================================================================

pub fn putUint(buf: []u8, pos: *usize, value: u32) void {
    std.mem.writeInt(u32, buf[pos.*..][0..4], value, .little);
    pos.* += 4;
}

pub fn putInt(buf: []u8, pos: *usize, value: i32) void {
    std.mem.writeInt(i32, buf[pos.*..][0..4], value, .little);
    pos.* += 4;
}

/// Serialize a Wayland string argument.
/// Format: 4-byte length (including null terminator) | bytes | '\0' | padding to 4-byte boundary.
pub fn putString(buf: []u8, pos: *usize, str: []const u8) void {
    const len_with_null: u32 = @intCast(str.len + 1);
    putUint(buf, pos, len_with_null);
    @memcpy(buf[pos.*..][0..str.len], str);
    pos.* += str.len;
    buf[pos.*] = 0; // null terminator
    pos.* += 1;
    const padded = alignUp(str.len + 1, 4);
    const padding = padded - (str.len + 1);
    @memset(buf[pos.*..][0..padding], 0);
    pos.* += padding;
}

pub fn getUint(buf: []const u8, pos: *usize) u32 {
    if (pos.* + 4 > buf.len) return 0; // bounds check
    const value = std.mem.readInt(u32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return value;
}

pub fn getInt(buf: []const u8, pos: *usize) i32 {
    if (pos.* + 4 > buf.len) return 0; // bounds check
    const value = std.mem.readInt(i32, buf[pos.*..][0..4], .little);
    pos.* += 4;
    return value;
}

/// Read a Wayland string argument.
/// Returns a slice into buf (without the null terminator).
/// Advances pos past the padded end of the string.
pub fn getString(buf: []const u8, pos: *usize) []const u8 {
    const len = getUint(buf, pos);
    if (len == 0) return buf[0..0]; // empty/null string
    const padded = alignUp(len, 4);
    if (pos.* + padded > buf.len or len - 1 > buf.len - pos.*) {
        pos.* = buf.len; // skip to end on malformed
        return buf[0..0];
    }
    const str = buf[pos.*..][0 .. len - 1]; // exclude null terminator
    pos.* += padded;
    return str;
}

/// Read a Wayland array argument.
/// Returns a slice into buf containing the raw array data.
/// Advances pos past the padded end.
pub fn getArray(buf: []const u8, pos: *usize) []const u8 {
    const len = getUint(buf, pos);
    const padded = alignUp(len, 4);
    if (pos.* + padded > buf.len or len > buf.len - pos.*) {
        pos.* = buf.len; // skip to end on malformed
        return buf[0..0];
    }
    const data = buf[pos.*..][0..len];
    pos.* += padded;
    return data;
}

// ============================================================================
// Connection
// ============================================================================

pub const Connection = struct {
    fd: posix.fd_t,
    id_alloc: ObjectIdAllocator = .{},
    recv_buf: [4096]u8 align(4) = undefined,
    recv_len: usize = 0,
    /// Cursor into recv_buf: how many bytes have been consumed by nextEvent/consumeEvent.
    recv_consumed: usize = 0,
    send_buf: [4096]u8 = undefined,
    send_len: usize = 0,
    recv_fds: [4]posix.fd_t = .{ -1, -1, -1, -1 },
    recv_fd_count: usize = 0,
    recv_fd_consumed: usize = 0,

    /// Connect to the Wayland compositor's UNIX socket.
    /// Reads $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY (defaults to "wayland-0").
    /// If WAYLAND_DISPLAY is an absolute path, it is used directly (per Wayland spec).
    pub fn connect() !Connection {
        const display = std.posix.getenv("WAYLAND_DISPLAY") orelse "wayland-0";

        var path_buf: [256]u8 = undefined;
        const path = if (display.len > 0 and display[0] == '/')
            std.fmt.bufPrintZ(&path_buf, "{s}", .{display}) catch return error.PathTooLong
        else blk: {
            const runtime_dir = std.posix.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntimeDir;
            break :blk std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ runtime_dir, display }) catch return error.PathTooLong;
        };

        const sock_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, 0);
        errdefer posix.close(sock_fd);

        var addr = std.mem.zeroes(posix.sockaddr.un);
        addr.family = posix.AF.UNIX;
        if (path.len >= addr.path.len) return error.PathTooLong;
        @memcpy(addr.path[0..path.len], path);

        try posix.connect(sock_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        return Connection{ .fd = sock_fd };
    }

    pub fn deinit(self: *Connection) void {
        posix.close(self.fd);
        // Close any unconsumed received fds
        for (self.recv_fds[self.recv_fd_consumed..self.recv_fd_count]) |rfd| {
            if (rfd >= 0) posix.close(rfd);
        }
    }

    /// Write a Wayland message to the send buffer (flushed lazily).
    /// fds are sent via SCM_RIGHTS and do NOT contribute to message size.
    pub fn sendMessage(
        self: *Connection,
        object_id: u32,
        opcode: u16,
        payload: []const u8,
        fds: []const posix.fd_t,
    ) !void {
        const msg_size: u16 = @intCast(8 + payload.len);
        const header = encodeHeader(object_id, opcode, msg_size);

        if (fds.len == 0) {
            // Fast path: no fds — buffer into send_buf, flush when full
            const total = 8 + payload.len;
            if (self.send_len + total > self.send_buf.len) {
                try self.flush();
            }
            std.mem.writeInt(u32, self.send_buf[self.send_len..][0..4], header[0], .little);
            std.mem.writeInt(u32, self.send_buf[self.send_len + 4 ..][0..4], header[1], .little);
            self.send_len += 8;
            @memcpy(self.send_buf[self.send_len..][0..payload.len], payload);
            self.send_len += payload.len;
        } else {
            // Flush pending data first so ordering is preserved
            if (self.send_len > 0) {
                try self.flush();
            }
            // Send header + payload with SCM_RIGHTS fds in one sendmsg call
            var hdr_bytes: [8]u8 = undefined;
            std.mem.writeInt(u32, hdr_bytes[0..4], header[0], .little);
            std.mem.writeInt(u32, hdr_bytes[4..8], header[1], .little);

            const iov = [2]posix.iovec_const{
                .{ .base = &hdr_bytes, .len = 8 },
                .{ .base = payload.ptr, .len = payload.len },
            };

            // Build ancillary data buffer for SCM_RIGHTS
            const fd_bytes = std.mem.sliceAsBytes(fds);
            const cmsg_space = std.mem.alignForward(usize, @sizeOf(cmsghdr) + fd_bytes.len, @alignOf(cmsghdr));
            var cmsg_buf: [std.mem.alignForward(usize, @sizeOf(cmsghdr) + 4 * @sizeOf(posix.fd_t), @alignOf(cmsghdr))]u8 align(@alignOf(cmsghdr)) = undefined;

            const cmsg: *cmsghdr = @alignCast(@ptrCast(&cmsg_buf));
            cmsg.len = @intCast(@sizeOf(cmsghdr) + fd_bytes.len);
            cmsg.level = posix.SOL.SOCKET;
            cmsg.type = 1; // SCM_RIGHTS
            @memcpy(cmsg_buf[@sizeOf(cmsghdr)..][0..fd_bytes.len], fd_bytes);

            const msghdr = linux.msghdr_const{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = if (payload.len > 0) 2 else 1,
                .control = &cmsg_buf,
                .controllen = @intCast(cmsg_space),
                .flags = 0,
            };

            while (true) {
                const rc = linux.sendmsg(self.fd, &msghdr, linux.MSG.NOSIGNAL);
                const rc_isize: isize = @bitCast(rc);
                if (rc_isize < 0) {
                    const err: u32 = @intCast(-@as(i32, @intCast(rc_isize)));
                    if (err == @intFromEnum(posix.E.AGAIN)) {
                        var pfd = [1]linux.pollfd{.{
                            .fd = self.fd,
                            .events = linux.POLL.OUT,
                            .revents = 0,
                        }};
                        _ = linux.poll(&pfd, 1, 100);
                        continue;
                    }
                    return error.SendFailed;
                }
                break;
            }
        }
    }

    /// Receive available data (and any ancillary fds) into recv_buf.
    /// Returns the number of new bytes received.
    pub fn recvEvents(self: *Connection) !usize {
        // Compact: move unconsumed data to front
        if (self.recv_consumed > 0) {
            const remaining = self.recv_len - self.recv_consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.recv_buf[0..remaining], self.recv_buf[self.recv_consumed..self.recv_len]);
            }
            self.recv_len = remaining;
            self.recv_consumed = 0;
        }

        // Compact fd array
        if (self.recv_fd_consumed > 0) {
            const fd_remaining = self.recv_fd_count - self.recv_fd_consumed;
            if (fd_remaining > 0) {
                std.mem.copyForwards(posix.fd_t, self.recv_fds[0..fd_remaining], self.recv_fds[self.recv_fd_consumed..self.recv_fd_count]);
            }
            self.recv_fd_count = fd_remaining;
            self.recv_fd_consumed = 0;
        }

        const space = self.recv_buf.len - self.recv_len;
        if (space == 0) return error.RecvBufferFull;

        var iov = [1]posix.iovec{
            .{ .base = self.recv_buf[self.recv_len..].ptr, .len = space },
        };

        // Ancillary buffer for up to 4 received fds
        const max_fds = 4;
        const cmsg_buf_size = comptime std.mem.alignForward(usize, @sizeOf(cmsghdr) + max_fds * @sizeOf(posix.fd_t), @alignOf(cmsghdr));
        var cmsg_buf: [cmsg_buf_size]u8 align(@alignOf(cmsghdr)) = undefined;

        var msg = linux.msghdr{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &cmsg_buf,
            .controllen = @intCast(cmsg_buf_size),
            .flags = 0,
        };

        const rc = linux.recvmsg(self.fd, &msg, 0);
        const rc_isize: isize = @bitCast(rc);
        if (rc_isize < 0) {
            const err: i32 = @intCast(-rc_isize);
            return switch (err) {
                @intFromEnum(posix.E.AGAIN) => error.WouldBlock,
                @intFromEnum(posix.E.CONNRESET) => error.ConnectionReset,
                else => error.RecvFailed,
            };
        }
        const bytes_recv: usize = @intCast(rc_isize);
        if (bytes_recv == 0) return error.ConnectionClosed;
        self.recv_len += bytes_recv;

        // Extract received fds from ancillary data
        if (msg.controllen > 0) {
            var cmsg_ptr: usize = 0;
            while (cmsg_ptr + @sizeOf(cmsghdr) <= msg.controllen) {
                const cmsg: *const cmsghdr = @alignCast(@ptrCast(&cmsg_buf[cmsg_ptr]));
                if (cmsg.level == posix.SOL.SOCKET and cmsg.type == 1) { // SCM_RIGHTS
                    const data_len = cmsg.len - @sizeOf(cmsghdr);
                    const n_fds = data_len / @sizeOf(posix.fd_t);
                    const fd_ptr: [*]const posix.fd_t = @alignCast(@ptrCast(&cmsg_buf[cmsg_ptr + @sizeOf(cmsghdr)]));
                    var i: usize = 0;
                    while (i < n_fds and self.recv_fd_count < self.recv_fds.len) : (i += 1) {
                        self.recv_fds[self.recv_fd_count] = fd_ptr[i];
                        self.recv_fd_count += 1;
                    }
                    // Close fds that overflow the buffer
                    while (i < n_fds) : (i += 1) {
                        posix.close(fd_ptr[i]);
                    }
                }
                const next = std.mem.alignForward(usize, cmsg.len, @alignOf(cmsghdr));
                if (next == 0) break;
                cmsg_ptr += next;
            }
        }

        return bytes_recv;
    }

    /// Return the header of the next complete message, or null if not enough data.
    /// Does NOT advance recv_consumed — call consumeEvent() to do that.
    pub fn nextEvent(self: *Connection) ?Header {
        const avail = self.recv_len - self.recv_consumed;
        if (avail < 8) return null;
        const words: *const [2]u32 = @alignCast(@ptrCast(self.recv_buf[self.recv_consumed..].ptr));
        const hdr = decodeHeader(words);
        if (hdr.size < 8) return null; // malformed
        // Check aligned size so consumeEvent can safely advance to next
        // 4-byte boundary without overrunning the receive buffer.
        if (avail < alignUp(hdr.size, 4)) return null; // incomplete
        return hdr;
    }

    /// Consume a message with the given size, returning its payload (after the 8-byte header).
    /// Must be called after nextEvent() returns a valid header.
    pub fn consumeEvent(self: *Connection, size: u16) []const u8 {
        const start = self.recv_consumed + 8;
        const end = self.recv_consumed + size;
        const payload = self.recv_buf[start..end];
        // Align to 4-byte boundary (Wayland wire protocol requirement).
        // Sizes should always be 4-aligned per spec, but guard against
        // malformed messages to prevent misaligned pointer in nextEvent.
        self.recv_consumed += alignUp(size, 4);
        return payload;
    }

    /// Pop the next received fd (sent via SCM_RIGHTS), or null if none available.
    pub fn consumeFd(self: *Connection) ?posix.fd_t {
        if (self.recv_fd_consumed >= self.recv_fd_count) return null;
        const fd = self.recv_fds[self.recv_fd_consumed];
        self.recv_fd_consumed += 1;
        return fd;
    }

    /// Flush the send buffer to the socket.
    /// Handles EAGAIN from non-blocking socket by polling for writability.
    pub fn flush(self: *Connection) !void {
        if (self.send_len == 0) return;
        var sent: usize = 0;
        while (sent < self.send_len) {
            const iov = [1]posix.iovec_const{
                .{ .base = self.send_buf[sent..].ptr, .len = self.send_len - sent },
            };
            const msghdr = linux.msghdr_const{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = 1,
                .control = null,
                .controllen = 0,
                .flags = 0,
            };
            const rc = linux.sendmsg(self.fd, &msghdr, linux.MSG.NOSIGNAL);
            const rc_isize: isize = @bitCast(rc);
            if (rc_isize < 0) {
                const err: u32 = @intCast(-@as(i32, @intCast(rc_isize)));
                if (err == @intFromEnum(posix.E.AGAIN)) {
                    // Socket buffer full — poll for writability (up to 100ms)
                    var pfd = [1]linux.pollfd{.{
                        .fd = self.fd,
                        .events = linux.POLL.OUT,
                        .revents = 0,
                    }};
                    _ = linux.poll(&pfd, 1, 100);
                    continue;
                }
                return error.SendFailed;
            }
            sent += @intCast(rc_isize);
        }
        self.send_len = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "encodeHeader / decodeHeader round-trip" {
    const encoded = encodeHeader(1, 0, 8);
    const decoded = decodeHeader(&encoded);
    try std.testing.expectEqual(@as(u32, 1), decoded.object_id);
    try std.testing.expectEqual(@as(u16, 0), decoded.opcode);
    try std.testing.expectEqual(@as(u16, 8), decoded.size);
}

test "encodeHeader with payload size" {
    const encoded = encodeHeader(42, 3, 12);
    const decoded = decodeHeader(&encoded);
    try std.testing.expectEqual(@as(u32, 42), decoded.object_id);
    try std.testing.expectEqual(@as(u16, 3), decoded.opcode);
    try std.testing.expectEqual(@as(u16, 12), decoded.size);
}

test "alignUp" {
    try std.testing.expectEqual(@as(usize, 0), alignUp(0, 4));
    try std.testing.expectEqual(@as(usize, 4), alignUp(1, 4));
    try std.testing.expectEqual(@as(usize, 4), alignUp(4, 4));
    try std.testing.expectEqual(@as(usize, 8), alignUp(5, 4));
    try std.testing.expectEqual(@as(usize, 8), alignUp(8, 4));
    try std.testing.expectEqual(@as(usize, 12), alignUp(9, 4));
}

test "putUint / getUint round-trip" {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    putUint(&buf, &pos, 0xDEADBEEF);
    try std.testing.expectEqual(@as(usize, 4), pos);
    pos = 0;
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), getUint(&buf, &pos));
    try std.testing.expectEqual(@as(usize, 4), pos);
}

test "putInt / getInt round-trip" {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    putInt(&buf, &pos, -1);
    pos = 0;
    try std.testing.expectEqual(@as(i32, -1), getInt(&buf, &pos));
}

test "putString / getString round-trip — exact 4-byte boundary" {
    // "abc" -> len=4 (3 chars + null), 4 bytes body -> 8 bytes total
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    putString(&buf, &pos, "abc");
    try std.testing.expectEqual(@as(usize, 8), pos); // 4-byte len + 4 bytes (3 + null, already 4-aligned)
    pos = 0;
    const s = getString(&buf, &pos);
    try std.testing.expectEqualStrings("abc", s);
    try std.testing.expectEqual(@as(usize, 8), pos);
}

test "putString / getString round-trip — needs padding" {
    // "a" -> len=2 (1 char + null), padded to 4 -> 4+4=8 bytes total
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    putString(&buf, &pos, "a");
    try std.testing.expectEqual(@as(usize, 8), pos); // 4-byte len + 4 bytes (1 + null + 2 pad)
    pos = 0;
    const s = getString(&buf, &pos);
    try std.testing.expectEqualStrings("a", s);
}

test "getArray round-trip" {
    var buf: [16]u8 = undefined;
    var pos: usize = 0;
    // manually write array: length=3, data=[1,2,3], pad=1
    putUint(&buf, &pos, 3);
    buf[4] = 1;
    buf[5] = 2;
    buf[6] = 3;
    buf[7] = 0; // padding
    pos = 0;
    const arr = getArray(&buf, &pos);
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(u8, 1), arr[0]);
    try std.testing.expectEqual(@as(u8, 2), arr[1]);
    try std.testing.expectEqual(@as(u8, 3), arr[2]);
    try std.testing.expectEqual(@as(usize, 8), pos);
}

test "ObjectIdAllocator sequential allocation" {
    var alloc = ObjectIdAllocator{};
    try std.testing.expectEqual(@as(u32, 2), alloc.next());
    try std.testing.expectEqual(@as(u32, 3), alloc.next());
    try std.testing.expectEqual(@as(u32, 4), alloc.next());
}

test "ObjectIdAllocator reuse after release" {
    var alloc = ObjectIdAllocator{};
    const id1 = alloc.next();
    const id2 = alloc.next();
    alloc.release(id1);
    const id3 = alloc.next();
    try std.testing.expectEqual(id1, id3);
    _ = id2;
}

test "ObjectIdAllocator free list overflow" {
    var alloc = ObjectIdAllocator{};
    // Fill the free list
    var i: u32 = 0;
    while (i < alloc.free_list.len + 5) : (i += 1) {
        alloc.release(100 + i); // silently drops beyond capacity
    }
    try std.testing.expectEqual(@as(u32, alloc.free_list.len), alloc.free_count);
}
