const std = @import("std");
const builtin = @import("builtin");
const posix = @import("../posix.zig");
const config = @import("config");
const input_mod = @import("../input.zig");

// =============================================================================
// Objective-C runtime types and helpers
// =============================================================================

const id = *anyopaque;
const SEL = *anyopaque;
const Class = *anyopaque;
const IMP = *const anyopaque;
const BOOL = i8;
const YES: BOOL = 1;
const NO: BOOL = 0;
const NSUInteger = u64;
const NSInteger = i64;

// NSRange used by NSTextInputClient protocol
const NSRange = extern struct {
    location: NSUInteger,
    length: NSUInteger,
};

// CoreGraphics geometry types
const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,

    fn make(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) CGRect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
    }
};

// Objective-C runtime externs
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_msgSend_stret() void;
extern "objc" fn objc_getClass(name: [*:0]const u8) ?id;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_allocateClassPair(superclass: ?id, name: [*:0]const u8, extra_bytes: usize) ?id;
extern "objc" fn objc_registerClassPair(cls: id) void;
extern "objc" fn class_addMethod(cls: id, name: SEL, imp: IMP, types: [*:0]const u8) bool;
extern "objc" fn class_addIvar(cls: id, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
extern "objc" fn class_addProtocol(cls: id, protocol: id) bool;
extern "objc" fn object_getInstanceVariable(obj: id, name: [*:0]const u8, out: *?*anyopaque) id;
extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?id;

// CoreGraphics externs
extern "CoreGraphics" fn CGColorSpaceCreateDeviceRGB() ?id;
extern "CoreGraphics" fn CGColorSpaceRelease(cs: id) void;
extern "CoreGraphics" fn CGBitmapContextCreate(data: ?*anyopaque, width: usize, height: usize, bpc: usize, bpr: usize, cs: id, info: u32) ?id;
extern "CoreGraphics" fn CGBitmapContextGetData(ctx: id) ?[*]u8;
extern "CoreGraphics" fn CGBitmapContextCreateImage(ctx: id) ?id;
extern "CoreGraphics" fn CGContextDrawImage(ctx: id, rect: CGRect, image: id) void;
extern "CoreGraphics" fn CGContextRelease(ctx: id) void;
extern "CoreGraphics" fn CGImageRelease(image: id) void;
extern "Foundation" fn NSHomeDirectory() id;

// CoreGraphics bitmap info constants
const kCGBitmapByteOrder32Little: u32 = 2 << 12; // 8192
const kCGImageAlphaNoneSkipFirst: u32 = 6;
const kCGBitmapInfo: u32 = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;

// NSEvent modifier flags
const NSEventModifierFlagShift: u64 = 1 << 17;
const NSEventModifierFlagControl: u64 = 1 << 18;
const NSEventModifierFlagOption: u64 = 1 << 19;
const NSEventModifierFlagCommand: u64 = 1 << 20;

// NSWindow style mask
const NSWindowStyleMask: u64 = 0xF; // Titled | Closable | Miniaturizable | Resizable
const NSBackingStoreBuffered: u64 = 2;

// NSEvent mask
const NSEventMaskAny: u64 = 0xFFFFFFFFFFFFFFFF;

// =============================================================================
// Typed objc_msgSend wrappers
//
// Each variant casts the single objc_msgSend entry point to the correct
// function pointer type for the given argument/return combination.
// =============================================================================

fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

fn cls(name: [*:0]const u8) id {
    return objc_getClass(name) orelse @panic("objc_getClass returned null");
}

// id → id (no extra args)
fn msgSend_id(target: id, _sel: SEL) id {
    const f: *const fn (id, SEL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, _sel);
}

// id → void (no extra args)
fn msgSend_void(target: id, _sel: SEL) void {
    const f: *const fn (id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel);
}

// id, BOOL → void
fn msgSend_void_bool(target: id, _sel: SEL, val: BOOL) void {
    const f: *const fn (id, SEL, BOOL) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel, val);
}

// id, i64 → void
fn msgSend_void_i64(target: id, _sel: SEL, val: i64) void {
    const f: *const fn (id, SEL, i64) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel, val);
}

// id, id → void
fn msgSend_void_id(target: id, _sel: SEL, arg: id) void {
    const f: *const fn (id, SEL, id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel, arg);
}

// id, ?id → void (for methods that accept nil, e.g. makeKeyAndOrderFront:)
fn msgSend_void_optid(target: id, _sel: SEL, arg: ?id) void {
    const f: *const fn (id, SEL, ?id) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel, arg);
}

// id, id → id
fn msgSend_id_id(target: id, _sel: SEL, arg: id) id {
    const f: *const fn (id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, _sel, arg);
}

// id → u16 (keyCode)
fn msgSend_u16(target: id, _sel: SEL) u16 {
    const f: *const fn (id, SEL) callconv(.c) u16 = @ptrCast(&objc_msgSend);
    return f(target, _sel);
}

// id → u64 (modifierFlags)
fn msgSend_u64(target: id, _sel: SEL) u64 {
    const f: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(&objc_msgSend);
    return f(target, _sel);
}

// id → [*:0]const u8 (UTF8String)
fn msgSend_cstr(target: id, _sel: SEL) ?[*:0]const u8 {
    const f: *const fn (id, SEL) callconv(.c) ?[*:0]const u8 = @ptrCast(&objc_msgSend);
    return f(target, _sel);
}

// initWithContentRect:styleMask:backing:defer:
fn msgSend_initWindow(target: id, _sel: SEL, rect: CGRect, style: u64, backing: u64, _defer: BOOL) id {
    const f: *const fn (id, SEL, CGRect, u64, u64, BOOL) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, _sel, rect, style, backing, _defer);
}

// nextEventMatchingMask:untilDate:inMode:dequeue:
fn msgSend_nextEvent(target: id, _sel: SEL, mask: u64, date: ?id, mode: id, dequeue: BOOL) ?id {
    const f: *const fn (id, SEL, u64, ?id, id, BOOL) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    return f(target, _sel, mask, date, mode, dequeue);
}

// id → CGRect (frame)
// On x86_64, structs > 16 bytes are returned via the stret convention: a hidden
// pointer to the result buffer is passed as the first argument. CGRect is 32 bytes,
// so we must use objc_msgSend_stret on x86_64 to avoid stack corruption.
// On ARM64, all return types use the regular objc_msgSend.
fn msgSend_CGRect(target: id, _sel: SEL) CGRect {
    if (builtin.cpu.arch == .x86_64) {
        const f: *const fn (*CGRect, id, SEL) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        var result: CGRect = undefined;
        f(&result, target, _sel);
        return result;
    } else {
        const f: *const fn (id, SEL) callconv(.c) CGRect = @ptrCast(&objc_msgSend);
        return f(target, _sel);
    }
}

// id, id → id (stringForType:)
fn msgSend_id_type(target: id, _sel: SEL, type_str: id) ?id {
    const f: *const fn (id, SEL, id) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    return f(target, _sel, type_str);
}

// id → id (CGContext from NSGraphicsContext)
fn msgSend_cgctx(target: id, _sel: SEL) ?id {
    const f: *const fn (id, SEL) callconv(.c) ?id = @ptrCast(&objc_msgSend);
    return f(target, _sel);
}

// setMarkedText:selectedRange:replacementRange:
fn msgSend_setMarked(target: id, _sel: SEL, text: id, selRange: NSRange, repRange: NSRange) void {
    const f: *const fn (id, SEL, id, NSRange, NSRange) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel, text, selRange, repRange);
}

// insertText:replacementRange:
fn msgSend_insertText(target: id, _sel: SEL, text: id, repRange: NSRange) void {
    const f: *const fn (id, SEL, id, NSRange) callconv(.c) void = @ptrCast(&objc_msgSend);
    f(target, _sel, text, repRange);
}

// =============================================================================
// Event types (shared with main.zig — keep in sync with x11.zig)
// =============================================================================

pub const MouseEvent = struct {
    x: u32, // pixel x
    y: u32, // pixel y
    button: Button,
    action: Action,
    modifiers: input_mod.Modifiers,

    pub const Button = enum(u3) {
        left = 0,
        middle = 1,
        right = 2,
        none = 3,
        wheel_up = 4,
        wheel_down = 5,
        wheel_left = 6,
        wheel_right = 7,
    };

    pub const Action = enum(u2) {
        press,
        release,
        motion,
    };
};

pub const PreeditEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,
    caret: u32 = 0,
    active: bool = false,
    // Per-byte feedback flags, indexed in lockstep with `data`.
    // Bit 0 = reverse, Bit 1 = underline, Bit 2 = highlight.
    feedback: [128]u8 = [_]u8{0} ** 128,

    pub fn slice(self: *const PreeditEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    preedit: PreeditEvent,
    mouse: MouseEvent,
    copy_selection: void,
    paste: PasteEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
};

pub const PasteEvent = struct {
    ptr: [*]const u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const PasteEvent) []const u8 {
        if (self.len == 0) return &.{};
        return self.ptr[0..self.len];
    }
};

pub const TextEvent = struct {
    data: [128]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const TextEvent) []const u8 {
        return self.data[0..self.len];
    }
};

pub const KeyEvent = struct {
    keycode: u16,
    pressed: bool,
    modifiers: input_mod.Modifiers,
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

// =============================================================================
// MacosBackend
// =============================================================================

pub const MacosBackend = struct {
    const Self = @This();
    const QUEUE_SIZE = 64;

    buffer: []u8, // Slice over CGBitmapContext pixel data
    width: u32,
    height: u32,
    stride: u32,

    wakeup_read_fd: posix.fd_t, // Non-blocking, for kqueue
    wakeup_write_fd: posix.fd_t, // Non-blocking, written by NSView callbacks

    app: id, // NSApplication
    window: id, // NSWindow
    view: id, // Custom NSView (ZTView)
    cg_context: id, // CGContextRef

    dirty_y_min: u32 = std.math.maxInt(u32),
    dirty_y_max: u32 = 0,

    // Event ring buffer (filled by NSView callbacks, drained by pollEvents)
    event_queue: [QUEUE_SIZE]Event = undefined,
    event_head: u32 = 0,
    event_tail: u32 = 0,

    paste_buf_data: std.ArrayList(u8) = .empty,

    has_marked_text: bool = false,
    marked_length: u64 = 0,
    marked_selection: NSRange = .{ .location = 0, .length = 0 },
    ime_x: u32 = 0,
    ime_y: u32 = config.cell_height,
    autorelease_pool: id,

    // =========================================================================
    // Ring buffer helpers
    // =========================================================================

    fn pushEvent(self: *Self, event: Event) void {
        const next = (self.event_tail + 1) % QUEUE_SIZE;
        if (next == self.event_head) return; // Queue full — drop oldest would be worse; drop new
        self.event_queue[self.event_tail] = event;
        self.event_tail = next;
        // Wake up kqueue
        _ = posix.write(self.wakeup_write_fd, &[_]u8{1}) catch {};
    }

    fn popEvent(self: *Self) ?Event {
        if (self.event_head == self.event_tail) return null;
        const ev = self.event_queue[self.event_head];
        self.event_head = (self.event_head + 1) % QUEUE_SIZE;
        return ev;
    }

    // =========================================================================
    // Retrieve *Self from an NSView ivar
    // =========================================================================

    fn getBackendFromView(view_obj: id) ?*Self {
        var ptr: ?*anyopaque = null;
        _ = object_getInstanceVariable(view_obj, "_zt_backend", &ptr);
        if (ptr) |p| {
            return @ptrCast(@alignCast(p));
        }
        return null;
    }

    // =========================================================================
    // init
    // =========================================================================

    pub fn init() !Self {
        // 1. Self-pipe for waking kqueue from Cocoa callbacks
        const pipe_fds = try posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            posix.close(pipe_fds[0]);
            posix.close(pipe_fds[1]);
        }

        const pool = msgSend_id(msgSend_id(cls("NSAutoreleasePool"), sel("alloc")), sel("init"));
        errdefer msgSend_void(pool, sel("drain"));

        // 2. NSApplication setup
        const app = msgSend_id(cls("NSApplication"), sel("sharedApplication"));
        // Finder launches bundles with an unspecified working directory.
        // Start their shell at home; CLI launches retain the caller's directory.
        const bundle = msgSend_id(cls("NSBundle"), sel("mainBundle"));
        const bundle_path = msgSend_id(bundle, sel("bundlePath"));
        if (msgSend_cstr(bundle_path, sel("UTF8String"))) |path| {
            if (std.mem.endsWith(u8, std.mem.span(path), ".app")) {
                if (msgSend_cstr(NSHomeDirectory(), sel("UTF8String"))) |home| {
                    if (std.c.chdir(home) != 0) return error.HomeDirectoryUnavailable;
                }
            }
        }
        // setActivationPolicy: NSApplicationActivationPolicyRegular = 0
        msgSend_void_i64(app, sel("setActivationPolicy:"), 0);

        // 3. Window dimensions: 80x24 cells
        const width: u32 = 80 * config.cell_width;
        const height: u32 = 24 * config.cell_height;
        const stride: u32 = width * 4;

        // 4. Create CGBitmapContext
        const color_space = CGColorSpaceCreateDeviceRGB() orelse return error.CGColorSpaceFailed;
        defer CGColorSpaceRelease(color_space);

        const cg_context = CGBitmapContextCreate(
            null, // Let CG allocate the backing store
            width,
            height,
            8, // bits per component
            stride, // bytes per row
            color_space,
            kCGBitmapInfo,
        ) orelse return error.CGBitmapContextFailed;

        errdefer CGContextRelease(cg_context);
        const data_ptr = CGBitmapContextGetData(cg_context) orelse return error.CGBitmapDataNull;
        const buffer_size = @as(usize, stride) * @as(usize, height);
        const buffer = data_ptr[0..buffer_size];
        @memset(buffer, 0);

        // 5. Create NSWindow
        const content_rect = CGRect.make(100, 100, @floatFromInt(width), @floatFromInt(height));
        const window_alloc = msgSend_id(cls("NSWindow"), sel("alloc"));
        const window = msgSend_initWindow(
            window_alloc,
            sel("initWithContentRect:styleMask:backing:defer:"),
            content_rect,
            NSWindowStyleMask,
            NSBackingStoreBuffered,
            NO,
        );

        // 6. Register custom ZTView class (NSView subclass)
        const view_class = registerZTViewClass() orelse return error.ClassRegistrationFailed;

        // 7. Create view instance
        const view_alloc = msgSend_id(@as(id, view_class), sel("alloc"));
        const view_frame = CGRect.make(0, 0, @floatFromInt(width), @floatFromInt(height));
        const view = msgSend_initFrame(view_alloc, sel("initWithFrame:"), view_frame);

        // 8. Set view as contentView and configure window
        msgSend_void_id(window, sel("setContentView:"), view);
        const make_first_responder: *const fn (id, SEL, id) callconv(.c) BOOL = @ptrCast(&objc_msgSend);
        _ = make_first_responder(window, sel("makeFirstResponder:"), view);
        msgSend_void_bool(window, sel("setReleasedWhenClosed:"), NO);
        msgSend_void_bool(window, sel("setAcceptsMouseMovedEvents:"), YES);
        msgSend_void_id(window, sel("setDelegate:"), view);
        installMenu(app, view);

        // 9. Set window title
        const title_str = createNSString("zt");
        msgSend_void_id(window, sel("setTitle:"), title_str);

        // 10. Show window and activate app
        msgSend_void_optid(window, sel("makeKeyAndOrderFront:"), null);
        // finishLaunching is required for non-bundle apps to properly
        // initialize the window server connection and menu bar.
        msgSend_void(app, sel("finishLaunching"));
        msgSend_void_bool(app, sel("activateIgnoringOtherApps:"), YES);

        // NOTE: The backend pointer ivar is set in postInit() after the struct
        // is at its final memory address (init returns by value).

        return Self{
            .buffer = buffer,
            .width = width,
            .height = height,
            .stride = stride,
            .wakeup_read_fd = pipe_fds[0],
            .wakeup_write_fd = pipe_fds[1],
            .app = app,
            .window = window,
            .view = view,
            .cg_context = cg_context,
            .autorelease_pool = pool,
        };
    }

    // =========================================================================
    // postInit — store self pointer in the view's ivar
    // =========================================================================

    pub fn postInit(self: *Self) void {
        // Now that the struct is at its final address, set the ivar
        setViewBackendPtr(self.view, self);
    }

    // =========================================================================
    // deinit
    // =========================================================================

    pub fn deinit(self: *Self) void {
        self.paste_buf_data.deinit(std.heap.c_allocator);
        msgSend_void_optid(self.app, sel("setMainMenu:"), null);
        posix.close(self.wakeup_read_fd);
        posix.close(self.wakeup_write_fd);
        _ = object_setInstanceVariable(self.view, "_zt_backend", null);
        msgSend_void_optid(self.window, sel("setDelegate:"), null);
        msgSend_void(self.window, sel("close"));
        msgSend_void(self.view, sel("release"));
        msgSend_void(self.window, sel("release"));
        CGContextRelease(self.cg_context);
        msgSend_void(self.autorelease_pool, sel("drain"));
    }

    // =========================================================================
    // Buffer accessors
    // =========================================================================

    pub fn getBuffer(self: *Self) []u8 {
        return self.buffer;
    }

    pub fn getStride(self: *Self) u32 {
        return self.stride;
    }

    pub fn getWidth(self: *Self) u32 {
        return self.width;
    }

    pub fn getHeight(self: *Self) u32 {
        return self.height;
    }

    // =========================================================================
    // Dirty tracking and presentation
    // =========================================================================

    pub fn markDirtyRows(self: *Self, y_start: u32, y_end: u32) void {
        if (y_start < self.dirty_y_min) self.dirty_y_min = y_start;
        if (y_end > self.dirty_y_max) self.dirty_y_max = y_end;
    }

    pub fn present(self: *Self) void {
        if (self.dirty_y_min > self.dirty_y_max) return;
        // [view setNeedsDisplay:YES]
        msgSend_void_bool(self.view, sel("setNeedsDisplay:"), YES);
        self.dirty_y_min = std.math.maxInt(u32);
        self.dirty_y_max = 0;
    }

    pub fn flush(_: *Self) void {
        // Display is serviced by pollEvents.
    }

    // =========================================================================
    // Event polling
    // =========================================================================

    pub fn getFd(self: *Self) ?posix.fd_t {
        return self.wakeup_read_fd;
    }

    pub fn pollEvents(self: *Self) ?Event {
        // Consume queued callbacks before pumping another NSEvent. This keeps
        // paste storage alive until the dispatcher has consumed it.
        if (self.popEvent()) |ev| return ev;
        const pool = msgSend_id(msgSend_id(cls("NSAutoreleasePool"), sel("alloc")), sel("init"));
        defer msgSend_void(pool, sel("drain"));
        var drain_buf: [64]u8 = undefined;
        while (true) {
            const n = posix.read(self.wakeup_read_fd, &drain_buf) catch break;
            if (n == 0) break;
        }
        const date = msgSend_id(cls("NSDate"), sel("distantPast"));
        while (msgSend_nextEvent(self.app, sel("nextEventMatchingMask:untilDate:inMode:dequeue:"), NSEventMaskAny, date, getDefaultRunLoopMode(), YES)) |ev| {
            msgSend_void_id(self.app, sel("sendEvent:"), ev);
            if (self.event_head != self.event_tail) break;
        }
        msgSend_void(self.app, sel("updateWindows"));
        return self.popEvent();
    }

    pub fn updateTitle(self: *Self, title: []const u8) void {
        const pool = msgSend_id(msgSend_id(cls("NSAutoreleasePool"), sel("alloc")), sel("init"));
        defer msgSend_void(pool, sel("drain"));
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{s}", .{title}) catch return;
        msgSend_void_id(self.window, sel("setTitle:"), createNSString(text));
    }

    pub fn updateImeCursorPos(self: *Self, x: u32, y: u32) void {
        self.ime_x = x;
        self.ime_y = y;
    }

    // =========================================================================
    // Resize
    // =========================================================================

    pub fn resize(self: *Self, w: u32, h: u32) !void {
        if (w == self.width and h == self.height) return;

        const new_stride = w * 4;
        const color_space = CGColorSpaceCreateDeviceRGB() orelse return error.CGColorSpaceFailed;
        defer CGColorSpaceRelease(color_space);

        const new_ctx = CGBitmapContextCreate(
            null,
            w,
            h,
            8,
            new_stride,
            color_space,
            kCGBitmapInfo,
        ) orelse return error.CGBitmapContextFailed;

        const new_data = CGBitmapContextGetData(new_ctx) orelse {
            CGContextRelease(new_ctx);
            return error.CGBitmapDataNull;
        };

        const new_size = @as(usize, new_stride) * @as(usize, h);
        const new_buffer = new_data[0..new_size];
        @memset(new_buffer, 0);

        // Release old context
        CGContextRelease(self.cg_context);

        self.cg_context = new_ctx;
        self.buffer = new_buffer;
        self.width = w;
        self.height = h;
        self.stride = new_stride;
    }

    // =========================================================================
    // Geometry query
    // =========================================================================

    pub fn queryGeometry(self: *Self) struct { w: u32, h: u32 } {
        // Get contentView frame to determine actual size
        const content_view = msgSend_id(self.window, sel("contentView"));
        const frame = msgSend_CGRect(content_view, sel("frame"));
        const w: u32 = @intFromFloat(@max(frame.size.width, 1));
        const h: u32 = @intFromFloat(@max(frame.size.height, 1));
        return .{ .w = w, .h = h };
    }

    // =========================================================================
    // No-ops (fbdev/VT-specific)
    // =========================================================================

    pub fn saveConsoleState(_: *Self) !void {}
    pub fn restoreConsoleState(_: *Self) void {}
    pub fn setupVtSwitching(_: *Self) !void {}
    pub fn releaseVt(_: *Self) void {}
    pub fn acquireVt(_: *Self) void {}
};

// =============================================================================
// NSView subclass registration
// =============================================================================

/// Registered once; returns the Class object for ZTView.
var zt_view_class_registered: ?id = null;

fn registerZTViewClass() ?id {
    if (zt_view_class_registered) |c| return c;

    const nsview = objc_getClass("NSView") orelse return null;
    const new_class = objc_allocateClassPair(nsview, "ZTView", 0) orelse return null;

    // Add ivar to hold *MacosBackend pointer
    _ = class_addIvar(new_class, "_zt_backend", @sizeOf(*anyopaque), 3, "^v"); // log2(8) = 3 for 64-bit pointers

    // Add NSTextInputClient protocol
    if (objc_getProtocol("NSTextInputClient")) |proto| {
        _ = class_addProtocol(new_class, proto);
    }

    // --- NSView overrides ---
    _ = class_addMethod(new_class, sel("drawRect:"), @ptrCast(@constCast(&ztDrawRect)), "v@:{CGRect=dddd}");
    _ = class_addMethod(new_class, sel("acceptsFirstResponder"), @ptrCast(@constCast(&ztAcceptsFirstResponder)), "c@:");
    _ = class_addMethod(new_class, sel("canBecomeKeyView"), @ptrCast(@constCast(&ztCanBecomeKeyView)), "c@:");
    _ = class_addMethod(new_class, sel("ztRequestClose:"), @ptrCast(&ztRequestClose), "v@:@");
    _ = class_addMethod(new_class, sel("copy:"), @ptrCast(&ztCopy), "v@:@");
    _ = class_addMethod(new_class, sel("paste:"), @ptrCast(&ztPaste), "v@:@");

    // --- Keyboard ---
    _ = class_addMethod(new_class, sel("keyDown:"), @ptrCast(@constCast(&ztKeyDown)), "v@:@");
    _ = class_addMethod(new_class, sel("flagsChanged:"), @ptrCast(@constCast(&ztFlagsChanged)), "v@:@");
    // doCommandBySelector: is called by interpretKeyEvents: for non-text
    // keys (Enter, Tab, arrows, Escape, etc.). Without this, the default
    // NSView implementation calls NSBeep() for every unhandled command.
    // We handle all keys through the evdev key event path, so this is a no-op.
    _ = class_addMethod(new_class, sel("doCommandBySelector:"), @ptrCast(@constCast(&ztDoCommandBySelector)), "v@::");

    // --- Mouse input ---
    _ = class_addMethod(new_class, sel("mouseDown:"), @ptrCast(&ztMouseDown), "v@:@");
    _ = class_addMethod(new_class, sel("mouseUp:"), @ptrCast(&ztMouseUp), "v@:@");
    _ = class_addMethod(new_class, sel("rightMouseDown:"), @ptrCast(&ztMouseDown), "v@:@");
    _ = class_addMethod(new_class, sel("rightMouseUp:"), @ptrCast(&ztMouseUp), "v@:@");
    _ = class_addMethod(new_class, sel("otherMouseDown:"), @ptrCast(&ztMouseDown), "v@:@");
    _ = class_addMethod(new_class, sel("otherMouseUp:"), @ptrCast(&ztMouseUp), "v@:@");
    _ = class_addMethod(new_class, sel("mouseDragged:"), @ptrCast(&ztMouseDragged), "v@:@");
    _ = class_addMethod(new_class, sel("rightMouseDragged:"), @ptrCast(&ztMouseDragged), "v@:@");
    _ = class_addMethod(new_class, sel("otherMouseDragged:"), @ptrCast(&ztMouseDragged), "v@:@");
    _ = class_addMethod(new_class, sel("mouseMoved:"), @ptrCast(&ztMouseMoved), "v@:@");
    _ = class_addMethod(new_class, sel("scrollWheel:"), @ptrCast(&ztScrollWheel), "v@:@");

    // --- NSTextInputClient ---
    _ = class_addMethod(new_class, sel("insertText:replacementRange:"), @ptrCast(@constCast(&ztInsertText)), "v@:@{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("hasMarkedText"), @ptrCast(@constCast(&ztHasMarkedText)), "c@:");
    _ = class_addMethod(new_class, sel("setMarkedText:selectedRange:replacementRange:"), @ptrCast(@constCast(&ztSetMarkedText)), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("unmarkText"), @ptrCast(@constCast(&ztUnmarkText)), "v@:");
    _ = class_addMethod(new_class, sel("validAttributesForMarkedText"), @ptrCast(@constCast(&ztValidAttributes)), "@@:");
    _ = class_addMethod(new_class, sel("firstRectForCharacterRange:actualRange:"), @ptrCast(@constCast(&ztFirstRect)), "{CGRect=dddd}@:{_NSRange=QQ}^{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("characterIndexForPoint:"), @ptrCast(@constCast(&ztCharacterIndex)), "Q@:{CGPoint=dd}");
    _ = class_addMethod(new_class, sel("attributedSubstringForProposedRange:actualRange:"), @ptrCast(@constCast(&ztAttributedSubstring)), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("markedRange"), @ptrCast(@constCast(&ztMarkedRange)), "{_NSRange=QQ}@:");
    _ = class_addMethod(new_class, sel("selectedRange"), @ptrCast(@constCast(&ztSelectedRange)), "{_NSRange=QQ}@:");

    // --- NSWindowDelegate ---
    _ = class_addMethod(new_class, sel("windowShouldClose:"), @ptrCast(@constCast(&ztWindowShouldClose)), "c@:@");
    _ = class_addMethod(new_class, sel("windowDidBecomeKey:"), @ptrCast(@constCast(&ztWindowDidBecomeKey)), "v@:@");
    _ = class_addMethod(new_class, sel("windowDidResignKey:"), @ptrCast(@constCast(&ztWindowDidResignKey)), "v@:@");
    _ = class_addMethod(new_class, sel("windowDidResize:"), @ptrCast(@constCast(&ztWindowDidResize)), "v@:@");
    _ = class_addMethod(new_class, sel("windowDidChangeOcclusionState:"), @ptrCast(@constCast(&ztWindowDidChangeOcclusion)), "v@:@");

    // --- NSView backing properties ---
    _ = class_addMethod(new_class, sel("viewDidChangeBackingProperties"), @ptrCast(@constCast(&ztViewDidChangeBackingProperties)), "v@:");

    objc_registerClassPair(new_class);
    zt_view_class_registered = new_class;
    return new_class;
}

// =============================================================================
// NSView callback implementations (callconv(.c))
// =============================================================================

fn ztDrawRect(self_view: id, _: SEL, _: CGRect) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;

    // Create CGImage from bitmap context
    const image = CGBitmapContextCreateImage(backend.cg_context) orelse return;
    defer CGImageRelease(image);

    // Get current NSGraphicsContext → CGContext
    const gfx_ctx = msgSend_id(cls("NSGraphicsContext"), sel("currentContext"));
    const cg_ctx = msgSend_cgctx(gfx_ctx, sel("CGContext")) orelse return;

    // Get view bounds
    const bounds = msgSend_CGRect(self_view, sel("bounds"));

    // Draw the image
    CGContextDrawImage(cg_ctx, bounds, image);
}

fn ztAcceptsFirstResponder(_: id, _: SEL) callconv(.c) BOOL {
    return YES;
}

fn ztCanBecomeKeyView(_: id, _: SEL) callconv(.c) BOOL {
    return YES;
}

fn ztRequestClose(view: id, _: SEL, _: ?id) callconv(.c) void {
    if (MacosBackend.getBackendFromView(view)) |backend| backend.pushEvent(.close);
}

fn ztCopy(view: id, _: SEL, _: ?id) callconv(.c) void {
    if (MacosBackend.getBackendFromView(view)) |backend| backend.pushEvent(.copy_selection);
}

fn ztPaste(view: id, _: SEL, _: ?id) callconv(.c) void {
    if (MacosBackend.getBackendFromView(view)) |backend| handlePaste(backend);
}

fn menuItem(title: [*:0]const u8, action: SEL, key: [*:0]const u8, target: id) id {
    const init: *const fn (id, SEL, id, SEL, id) callconv(.c) id = @ptrCast(&objc_msgSend);
    const item = init(msgSend_id(cls("NSMenuItem"), sel("alloc")), sel("initWithTitle:action:keyEquivalent:"), createNSString(title), action, createNSString(key));
    msgSend_void_id(item, sel("setTarget:"), target);
    return msgSend_id(item, sel("autorelease"));
}

fn installMenu(app: id, view: id) void {
    const menu = msgSend_id(msgSend_id(cls("NSMenu"), sel("alloc")), sel("init"));
    defer msgSend_void(menu, sel("release"));
    const app_menu = msgSend_id(msgSend_id(cls("NSMenu"), sel("alloc")), sel("init"));
    defer msgSend_void(app_menu, sel("release"));
    const app_item = menuItem("zt", sel("ztRequestClose:"), "", view);
    msgSend_void_id(app_item, sel("setSubmenu:"), app_menu);
    msgSend_void_id(app_menu, sel("addItem:"), menuItem("Close Window", sel("ztRequestClose:"), "w", view));
    msgSend_void_id(app_menu, sel("addItem:"), menuItem("Quit zt", sel("ztRequestClose:"), "q", view));
    msgSend_void_id(menu, sel("addItem:"), app_item);
    const edit_menu = msgSend_id(msgSend_id(cls("NSMenu"), sel("alloc")), sel("init"));
    defer msgSend_void(edit_menu, sel("release"));
    const edit_item = menuItem("Edit", sel("copy:"), "", view);
    msgSend_void_id(edit_item, sel("setSubmenu:"), edit_menu);
    msgSend_void_id(edit_menu, sel("addItem:"), menuItem("Copy", sel("copy:"), "c", view));
    msgSend_void_id(edit_menu, sel("addItem:"), menuItem("Paste", sel("paste:"), "v", view));
    msgSend_void_id(menu, sel("addItem:"), edit_item);
    msgSend_void_id(app, sel("setMainMenu:"), menu);
}

fn ztDoCommandBySelector(_: id, _: SEL, _: SEL) callconv(.c) void {
    // Special keys are dispatched by keyDown when no IME composition is active.
}

fn ztKeyDown(self_view: id, _: SEL, ns_event: id) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;

    const keycode = msgSend_u16(ns_event, sel("keyCode"));
    const flags = msgSend_u64(ns_event, sel("modifierFlags"));

    const has_cmd = (flags & NSEventModifierFlagCommand) != 0;

    // Handle Cmd+key shortcuts
    if (has_cmd) {
        switch (keycode) {
            0x0C => { // Cmd+Q
                backend.pushEvent(.close);
                return;
            },
            0x0D => { // Cmd+W
                backend.pushEvent(.close);
                return;
            },
            0x08 => { // Cmd+C — copy selected text
                backend.pushEvent(.copy_selection);
                return;
            },
            0x09 => { // Cmd+V — paste
                handlePaste(backend);
                return;
            },
            else => return, // Other Cmd+ combos: ignore
        }
    }

    // Translate macOS keycode → evdev keycode
    const evdev_code = input_mod.macosToEvdev(@intCast(keycode & 0x7F));

    // Determine if this key produces text (will be handled by insertText via IME path)
    // or is a special key (arrows, F-keys, etc.) that must go through KeyEvent.
    // Only emit KeyEvent for non-text keys to avoid double output with insertText.
    const is_special = evdev_code != 0 and switch (evdev_code) {
        input_mod.KEY.ESC,
        input_mod.KEY.ENTER,
        input_mod.KEY.BACKSPACE,
        input_mod.KEY.TAB,
        input_mod.KEY.UP,
        input_mod.KEY.DOWN,
        input_mod.KEY.LEFT,
        input_mod.KEY.RIGHT,
        input_mod.KEY.HOME,
        input_mod.KEY.END,
        input_mod.KEY.PAGEUP,
        input_mod.KEY.PAGEDOWN,
        input_mod.KEY.INSERT,
        input_mod.KEY.DELETE,
        input_mod.KEY.F1,
        input_mod.KEY.F2,
        input_mod.KEY.F3,
        input_mod.KEY.F4,
        input_mod.KEY.F5,
        input_mod.KEY.F6,
        input_mod.KEY.F7,
        input_mod.KEY.F8,
        input_mod.KEY.F9,
        input_mod.KEY.F10,
        input_mod.KEY.F11,
        input_mod.KEY.F12,
        => true,
        else => false,
    };

    if (is_special and !backend.has_marked_text) {
        backend.pushEvent(.{ .key = .{
            .keycode = evdev_code,
            .pressed = true,
            .modifiers = flagsToModifiers(flags),
        } });
        return; // Special keys don't go through IME
    }

    // Text-producing keys: let IME path handle via interpretKeyEvents → insertText.
    // Ctrl+key combos still need KeyEvent since insertText filters single-byte ASCII.
    const mods = flagsToModifiers(flags);
    if ((mods.ctrl or mods.alt) and !backend.has_marked_text) {
        if (evdev_code != 0) {
            backend.pushEvent(.{ .key = .{
                .keycode = evdev_code,
                .pressed = true,
                .modifiers = mods,
            } });
        }
        return;
    }

    // Forward to input method for IME handling:
    // [self interpretKeyEvents:[NSArray arrayWithObject:event]]
    const array_cls = cls("NSArray");
    const event_array = msgSend_id_id(array_cls, sel("arrayWithObject:"), ns_event);
    msgSend_void_id(self_view, sel("interpretKeyEvents:"), event_array);
}

fn ztFlagsChanged(self_view: id, _: SEL, ns_event: id) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;

    const keycode = msgSend_u16(ns_event, sel("keyCode"));
    const flags = msgSend_u64(ns_event, sel("modifierFlags"));

    // Determine which modifier key and whether it was pressed or released
    const evdev_code = input_mod.macosToEvdev(@intCast(keycode & 0x7F));
    if (evdev_code == 0) return;

    // Determine press/release from the current modifier flags
    const pressed: bool = switch (keycode) {
        0x38, 0x3C => (flags & NSEventModifierFlagShift) != 0, // L/R Shift
        0x3B, 0x3E => (flags & NSEventModifierFlagControl) != 0, // L/R Control
        0x3A, 0x3D => (flags & NSEventModifierFlagOption) != 0, // L/R Option
        0x37, 0x36 => (flags & NSEventModifierFlagCommand) != 0, // L/R Command
        else => true,
    };

    backend.pushEvent(.{ .key = .{
        .keycode = evdev_code,
        .pressed = pressed,
        .modifiers = flagsToModifiers(flags),
    } });
}

// =============================================================================
// NSTextInputClient callbacks
// =============================================================================

fn ztInsertText(self_view: id, _: SEL, text_obj: id, _: NSRange) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;

    // text_obj may be NSString or NSAttributedString; get plain string
    const str_obj = if (msgSend_bool(text_obj, sel("isKindOfClass:"), cls("NSAttributedString")))
        msgSend_id(text_obj, sel("string"))
    else
        text_obj;

    const cstr = msgSend_cstr(str_obj, sel("UTF8String")) orelse return;
    const len = std.mem.len(cstr);
    if (len == 0) return;

    backend.has_marked_text = false;
    backend.marked_length = 0;
    backend.pushEvent(.{ .preedit = .{} });
    // Printable ASCII comes through insertText too. Preserve layout and avoid
    // splitting a UTF-8 character across the fixed-size event payload.
    var rest = cstr[0..len];
    while (rest.len > 0) {
        const n = utf8PrefixLen(rest, 128);
        var event: TextEvent = .{};
        @memcpy(event.data[0..n], rest[0..n]);
        event.len = @intCast(n);
        backend.pushEvent(.{ .text = event });
        rest = rest[n..];
    }
}

fn ztHasMarkedText(self_view: id, _: SEL) callconv(.c) BOOL {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return NO;
    return if (backend.has_marked_text) YES else NO;
}

fn ztSetMarkedText(self_view: id, _: SEL, text: id, selected: NSRange, _: NSRange) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;
    const str = if (msgSend_bool(text, sel("isKindOfClass:"), cls("NSAttributedString")))
        msgSend_id(text, sel("string"))
    else
        text;
    const bytes = std.mem.span(msgSend_cstr(str, sel("UTF8String")) orelse return);
    backend.marked_length = msgSend_u64(str, sel("length")); // Cocoa uses UTF-16 units
    backend.marked_selection = selected;
    backend.has_marked_text = bytes.len > 0;
    var event: PreeditEvent = .{ .active = backend.has_marked_text };
    const n = utf8PrefixLen(bytes, event.data.len);
    @memcpy(event.data[0..n], bytes[0..n]);
    @memset(event.feedback[0..n], 2); // underline composition
    event.len = @intCast(n);
    // The inline preview is bounded like the other backends. Clamp only its
    // rendered caret; AppKit still sees the full UTF-16 selection below.
    event.caret = utf16Caret(bytes[0..n], selected.location);
    backend.pushEvent(.{ .preedit = event });
}

fn ztUnmarkText(self_view: id, _: SEL) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;
    backend.has_marked_text = false;
    backend.marked_length = 0;
    backend.pushEvent(.{ .preedit = .{} });
}

fn ztValidAttributes(_: id, _: SEL) callconv(.c) id {
    // Return empty NSArray
    return msgSend_id(cls("NSArray"), sel("array"));
}

fn ztFirstRect(view: id, _: SEL, range: NSRange, actual: ?*NSRange) callconv(.c) CGRect {
    const backend = MacosBackend.getBackendFromView(view) orelse return CGRect.make(0, 0, 0, 0);
    if (actual) |out| out.* = range;
    const bounds = msgSend_CGRect(view, sel("bounds"));
    const rect = CGRect.make(@floatFromInt(backend.ime_x), @max(0, bounds.size.height - @as(f64, @floatFromInt(backend.ime_y))), @floatFromInt(config.cell_width), @floatFromInt(config.cell_height));
    if (builtin.cpu.arch == .x86_64) {
        const convert_view: *const fn (*CGRect, id, SEL, CGRect, ?id) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        var in_window: CGRect = undefined;
        convert_view(&in_window, view, sel("convertRect:toView:"), rect, null);
        const convert_screen: *const fn (*CGRect, id, SEL, CGRect) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        var result: CGRect = undefined;
        convert_screen(&result, backend.window, sel("convertRectToScreen:"), in_window);
        return result;
    }
    const convert_view: *const fn (id, SEL, CGRect, ?id) callconv(.c) CGRect = @ptrCast(&objc_msgSend);
    const in_window = convert_view(view, sel("convertRect:toView:"), rect, null);
    const convert_screen: *const fn (id, SEL, CGRect) callconv(.c) CGRect = @ptrCast(&objc_msgSend);
    return convert_screen(backend.window, sel("convertRectToScreen:"), in_window);
}

fn ztCharacterIndex(_: id, _: SEL, _: CGPoint) callconv(.c) NSUInteger {
    return 0x7FFFFFFFFFFFFFFF; // NSNotFound
}

fn ztAttributedSubstring(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) ?id {
    return null;
}

fn ztMarkedRange(self_view: id, _: SEL) callconv(.c) NSRange {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return .{ .location = 0x7FFFFFFFFFFFFFFF, .length = 0 };
    if (backend.has_marked_text) {
        return .{ .location = 0, .length = backend.marked_length };
    }
    // NSNotFound
    return .{ .location = 0x7FFFFFFFFFFFFFFF, .length = 0 };
}

fn ztSelectedRange(view: id, _: SEL) callconv(.c) NSRange {
    if (MacosBackend.getBackendFromView(view)) |backend| {
        if (backend.has_marked_text) return backend.marked_selection;
    }
    return .{ .location = 0, .length = 0 };
}

// =============================================================================
// NSWindowDelegate callbacks
// =============================================================================

fn ztWindowShouldClose(self_view: id, _: SEL, _: id) callconv(.c) BOOL {
    if (MacosBackend.getBackendFromView(self_view)) |backend| {
        backend.pushEvent(.close);
    }
    // Return NO to prevent Cocoa from destroying the window before our
    // event loop processes the .close event. The event loop will exit
    // and cleanup happens via defer chains.
    return NO;
}

fn ztWindowDidBecomeKey(self_view: id, _: SEL, _: id) callconv(.c) void {
    if (MacosBackend.getBackendFromView(self_view)) |backend| {
        backend.pushEvent(.focus_in);
    }
}

fn ztWindowDidResignKey(self_view: id, _: SEL, _: id) callconv(.c) void {
    if (MacosBackend.getBackendFromView(self_view)) |backend| {
        backend.pushEvent(.focus_out);
    }
}

fn ztWindowDidResize(self_view: id, _: SEL, _: id) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;

    // Get the contentView frame (not the window frame — excludes title bar)
    const window = msgSend_id(self_view, sel("window"));
    const content_view = msgSend_id(window, sel("contentView"));
    const frame = msgSend_CGRect(content_view, sel("frame"));

    const w: u32 = @intFromFloat(@max(frame.size.width, 1));
    const h: u32 = @intFromFloat(@max(frame.size.height, 1));

    if (w != backend.width or h != backend.height) {
        backend.pushEvent(.{ .resize = .{ .width = w, .height = h } });
    }
}

fn ztWindowDidChangeOcclusion(self_view: id, _: SEL, _: id) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;
    // Check if window is now visible (NSWindowOcclusionStateVisible = 1 << 1)
    const window = msgSend_id(self_view, sel("window"));
    const getOcclusion: *const fn (id, SEL) callconv(.c) u64 = @ptrCast(&objc_msgSend);
    const state = getOcclusion(window, sel("occlusionState"));
    if (state & (1 << 1) != 0) { // NSWindowOcclusionStateVisible
        backend.pushEvent(.expose);
    }
}

fn ztViewDidChangeBackingProperties(self_view: id, _: SEL) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;
    // Trigger full redraw on scale change (e.g. moving window between Retina/non-Retina displays)
    backend.pushEvent(.expose);
}

// =============================================================================
// Helper functions
// =============================================================================

fn flagsToModifiers(flags: u64) input_mod.Modifiers {
    return .{
        .shift = (flags & NSEventModifierFlagShift) != 0,
        .ctrl = (flags & NSEventModifierFlagControl) != 0,
        .alt = (flags & NSEventModifierFlagOption) != 0,
        .meta = (flags & NSEventModifierFlagCommand) != 0,
    };
}

fn handlePaste(backend: *MacosBackend) void {
    // [NSPasteboard generalPasteboard]
    const pasteboard = msgSend_id(cls("NSPasteboard"), sel("generalPasteboard"));
    // NSPasteboardTypeString
    const type_string = createNSString("public.utf8-plain-text");
    // [pasteboard stringForType:NSPasteboardTypeString]
    const str_obj = msgSend_id_type(pasteboard, sel("stringForType:"), type_string) orelse return;
    queuePaste(backend, str_obj);
}

fn queuePaste(backend: *MacosBackend, str_obj: id) void {
    const cstr = msgSend_cstr(str_obj, sel("UTF8String")) orelse return;
    const len = std.mem.len(cstr);
    if (len == 0) return;

    if (len > std.math.maxInt(u32)) return;
    backend.paste_buf_data.resize(std.heap.c_allocator, len) catch return;
    @memcpy(backend.paste_buf_data.items, cstr[0..len]);
    backend.pushEvent(.{ .paste = .{ .ptr = backend.paste_buf_data.items.ptr, .len = @intCast(len) } });
}

fn createNSString(str: [*:0]const u8) id {
    const ns_string = cls("NSString");
    return msgSend_id_cstr(ns_string, sel("stringWithUTF8String:"), str);
}

fn msgSend_id_cstr(target: id, _sel: SEL, str: [*:0]const u8) id {
    const f: *const fn (id, SEL, [*:0]const u8) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, _sel, str);
}

fn msgSend_initFrame(target: id, _sel: SEL, frame: CGRect) id {
    const f: *const fn (id, SEL, CGRect) callconv(.c) id = @ptrCast(&objc_msgSend);
    return f(target, _sel, frame);
}

fn msgSend_bool(target: id, _sel: SEL, arg: id) bool {
    const f: *const fn (id, SEL, id) callconv(.c) BOOL = @ptrCast(&objc_msgSend);
    return f(target, _sel, arg) != 0;
}

fn setViewBackendPtr(view: id, backend: *MacosBackend) void {
    // object_setInstanceVariable is simpler but we use the
    // runtime-safe pattern: get the ivar offset and write directly.
    // However, object_setInstanceVariable is fine for our use case.
    _ = object_setInstanceVariable(view, "_zt_backend", @ptrCast(backend));
}

extern "objc" fn object_setInstanceVariable(obj: id, name: [*:0]const u8, value: ?*anyopaque) ?*anyopaque;

fn getDefaultRunLoopMode() id {
    // NSDefaultRunLoopMode is an NSString constant.
    // Access it as a global symbol exported by Foundation.
    const ptr = @extern(*const id, .{ .name = "NSDefaultRunLoopMode" });
    return ptr.*;
}

fn utf8PrefixLen(bytes: []const u8, capacity: usize) usize {
    var n = @min(bytes.len, capacity);
    if (n < bytes.len) {
        while (n > 0 and (bytes[n] & 0xC0) == 0x80) n -= 1;
    }
    return n;
}

/// Renderer carets use UTF-8 byte offsets; AppKit ranges count UTF-16 units.
fn utf16Caret(bytes: []const u8, units: u64) u32 {
    var offset: usize = 0;
    var used: u64 = 0;
    while (offset < bytes.len and used < units) {
        const n = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch break;
        if (offset + n > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[offset..][0..n]) catch break;
        const width: u64 = if (cp > 0xFFFF) 2 else 1;
        if (used + width > units) break;
        used += width;
        offset += n;
    }
    return @intCast(offset);
}

fn mouseEvent(view: id, event: id, action: MouseEvent.Action, button: MouseEvent.Button) void {
    const backend = MacosBackend.getBackendFromView(view) orelse return;
    const location: *const fn (id, SEL) callconv(.c) CGPoint = @ptrCast(&objc_msgSend);
    const convert: *const fn (id, SEL, CGPoint, ?id) callconv(.c) CGPoint = @ptrCast(&objc_msgSend);
    const point = convert(view, sel("convertPoint:fromView:"), location(event, sel("locationInWindow")), null);
    const bounds = msgSend_CGRect(view, sel("bounds"));
    backend.pushEvent(.{ .mouse = .{
        .x = @intFromFloat(@max(0, point.x)),
        .y = @intFromFloat(@max(0, bounds.size.height - point.y)),
        .button = button,
        .action = action,
        .modifiers = flagsToModifiers(msgSend_u64(event, sel("modifierFlags"))),
    } });
}

fn mouseButton(event: id) MouseEvent.Button {
    return switch (msgSend_u64(event, sel("buttonNumber"))) {
        0 => .left,
        1 => .right,
        2 => .middle,
        else => .none,
    };
}

fn ztMouseDown(view: id, _: SEL, event: id) callconv(.c) void {
    const button = mouseButton(event);
    if (button != .none) mouseEvent(view, event, .press, button);
}

fn ztMouseUp(view: id, _: SEL, event: id) callconv(.c) void {
    const button = mouseButton(event);
    if (button != .none) mouseEvent(view, event, .release, button);
}

fn ztMouseDragged(view: id, _: SEL, event: id) callconv(.c) void {
    const button = mouseButton(event);
    if (button != .none) mouseEvent(view, event, .motion, button);
}

fn ztMouseMoved(view: id, _: SEL, event: id) callconv(.c) void {
    mouseEvent(view, event, .motion, .none);
}

fn ztScrollWheel(view: id, _: SEL, event: id) callconv(.c) void {
    const delta: *const fn (id, SEL) callconv(.c) f64 = @ptrCast(&objc_msgSend);
    const dy = delta(event, sel("scrollingDeltaY"));
    if (dy != 0) mouseEvent(view, event, .press, if (dy > 0) .wheel_up else .wheel_down);
    const dx = delta(event, sel("scrollingDeltaX"));
    if (dx != 0) mouseEvent(view, event, .press, if (dx > 0) .wheel_left else .wheel_right);
}

test "macOS text chunks preserve UTF-8 boundaries" {
    try std.testing.expectEqual(@as(usize, 1), utf8PrefixLen("a日本", 3));
    try std.testing.expectEqual(@as(usize, 4), utf8PrefixLen("a日本", 4));
    try std.testing.expectEqual(@as(usize, 7), utf8PrefixLen("a日本", 128));
}

test "macOS composition caret converts UTF-16 to UTF-8 offsets" {
    try std.testing.expectEqual(@as(u32, 5), utf16Caret("a😀日", 3));
    try std.testing.expectEqual(@as(u32, 1), utf16Caret("a😀日", 2));
    try std.testing.expectEqual(@as(u32, 8), utf16Caret("a😀日", 4));
}

test "macOS Cocoa window, text composition, geometry and close integration" {
    if (!config.macos_gui_tests) return error.SkipZigTest;
    var backend = try MacosBackend.init();
    backend.postInit();
    defer backend.deinit();
    // Service the real AppKit run loop and drawing before examining callbacks.
    for (0..10) |_| {
        while (backend.pollEvents()) |_| {}
        posix.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u32, 80 * config.cell_width), backend.queryGeometry().w);
    backend.updateTitle("zt Cocoa integration test");
    const title = msgSend_id(backend.window, sel("title"));
    try std.testing.expectEqualStrings("zt Cocoa integration test", std.mem.span(msgSend_cstr(title, sel("UTF8String")).?));

    const range: NSRange = .{ .location = 0, .length = 0 };
    ztInsertText(backend.view, sel("insertText:replacementRange:"), createNSString("ASCII 日本😀"), range);
    _ = backend.popEvent(); // Cleared preedit
    const text = backend.popEvent().?.text;
    try std.testing.expectEqualStrings("ASCII 日本😀", text.slice());
    ztSetMarkedText(backend.view, sel("setMarkedText:selectedRange:replacementRange:"), createNSString("a😀日"), .{ .location = 3, .length = 0 }, range);
    const preedit = backend.popEvent().?.preedit;
    try std.testing.expect(preedit.active);
    try std.testing.expectEqual(@as(u32, 5), preedit.caret);
    try std.testing.expectEqual(@as(u64, 4), ztMarkedRange(backend.view, sel("markedRange")).length);
    try std.testing.expectEqual(@as(u64, 3), ztSelectedRange(backend.view, sel("selectedRange")).location);
    backend.updateImeCursorPos(config.cell_width, config.cell_height);
    const candidate = ztFirstRect(backend.view, sel("firstRectForCharacterRange:actualRange:"), range, null);
    try std.testing.expect(candidate.size.width > 0 and std.math.isFinite(candidate.origin.x));
    ztUnmarkText(backend.view, sel("unmarkText"));
    try std.testing.expect(!backend.popEvent().?.preedit.active);
    try backend.resize(100 * config.cell_width, 30 * config.cell_height);
    try std.testing.expectEqual(@as(usize, backend.stride) * backend.height, backend.buffer.len);
    backend.markDirtyRows(0, backend.height);
    backend.present();
    msgSend_void(backend.view, sel("displayIfNeeded"));
    try std.testing.expectEqual(NO, ztWindowShouldClose(backend.view, sel("windowShouldClose:"), backend.window));
    try std.testing.expect(backend.popEvent().? == .close);

    // Construct actual NSEvents without requiring Accessibility permissions.
    const key_event: *const fn (id, SEL, u64, CGPoint, u64, f64, i64, ?id, id, id, BOOL, u16) callconv(.c) id = @ptrCast(&objc_msgSend);
    const characters = createNSString("c");
    const event = key_event(cls("NSEvent"), sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"), 10, .{ .x = 0, .y = 0 }, NSEventModifierFlagControl, 0, 0, null, characters, characters, NO, 0x08);
    ztKeyDown(backend.view, sel("keyDown:"), event);
    const key = backend.popEvent().?.key;
    try std.testing.expectEqual(input_mod.KEY.C, key.keycode);
    try std.testing.expect(key.modifiers.ctrl);
    const copy_event = key_event(cls("NSEvent"), sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"), 10, .{ .x = 0, .y = 0 }, NSEventModifierFlagCommand, 0, 0, null, characters, characters, NO, 0x08);
    const menu = msgSend_id(backend.app, sel("mainMenu"));
    try std.testing.expect(msgSend_bool(menu, sel("performKeyEquivalent:"), copy_event));
    try std.testing.expect(backend.popEvent().? == .copy_selection);

    const mouse_event: *const fn (id, SEL, u64, CGPoint, u64, f64, i64, ?id, i64, i64, f32) callconv(.c) id = @ptrCast(&objc_msgSend);
    const drag = mouse_event(cls("NSEvent"), sel("mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"), 6, .{ .x = 10, .y = 10 }, 0, 0, @intCast(msgSend_u64(backend.window, sel("windowNumber"))), null, 1, 1, 1);
    ztMouseDragged(backend.view, sel("mouseDragged:"), drag);
    const motion = backend.popEvent().?.mouse;
    try std.testing.expectEqual(MouseEvent.Action.motion, motion.action);
    try std.testing.expectEqual(MouseEvent.Button.left, motion.button);
    ztMouseMoved(backend.view, sel("mouseMoved:"), drag);
    try std.testing.expectEqual(MouseEvent.Button.none, backend.popEvent().?.mouse.button);

    // Large pastes must survive in full, including a multibyte final character.
    const large = try std.testing.allocator.allocSentinel(u8, 20003, 0);
    defer std.testing.allocator.free(large);
    @memset(large[0..20000], 'x');
    @memcpy(large[20000..20003], "日");
    ztSetMarkedText(backend.view, sel("setMarkedText:selectedRange:replacementRange:"), createNSString(large), .{ .location = 20001, .length = 0 }, range);
    const preview = backend.popEvent().?.preedit;
    try std.testing.expectEqual(@as(u32, 128), preview.caret);
    try std.testing.expectEqual(@as(u64, 20001), ztSelectedRange(backend.view, sel("selectedRange")).location);
    ztUnmarkText(backend.view, sel("unmarkText"));
    _ = backend.popEvent();
    queuePaste(&backend, createNSString(large));
    const paste = backend.popEvent().?.paste;
    try std.testing.expectEqualStrings(large, paste.slice());
}
