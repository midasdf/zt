const std = @import("std");
const builtin = @import("builtin");
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

pub const Event = union(enum) {
    key: KeyEvent,
    text: TextEvent,
    paste: PasteEvent,
    resize: ResizeEvent,
    expose: void,
    close: void,
    focus_in: void,
    focus_out: void,
};

pub const PasteEvent = struct {
    data: [65536]u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const PasteEvent) []const u8 {
        return self.data[0..self.len];
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

    wakeup_read_fd: std.posix.fd_t, // Non-blocking, for kqueue
    wakeup_write_fd: std.posix.fd_t, // Non-blocking, written by NSView callbacks

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

    has_marked_text: bool = false,

    // =========================================================================
    // Ring buffer helpers
    // =========================================================================

    fn pushEvent(self: *Self, event: Event) void {
        const next = (self.event_tail + 1) % QUEUE_SIZE;
        if (next == self.event_head) return; // Queue full — drop oldest would be worse; drop new
        self.event_queue[self.event_tail] = event;
        self.event_tail = next;
        // Wake up kqueue
        _ = std.posix.write(self.wakeup_write_fd, &[_]u8{1}) catch {};
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
        const pipe_fds = try std.posix.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true });
        errdefer {
            std.posix.close(pipe_fds[0]);
            std.posix.close(pipe_fds[1]);
        }

        // 2. NSApplication setup
        const app = msgSend_id(cls("NSApplication"), sel("sharedApplication"));
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
        msgSend_void_id(window, sel("makeFirstResponder:"), view);
        msgSend_void_id(window, sel("setDelegate:"), view);

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
        std.posix.close(self.wakeup_read_fd);
        std.posix.close(self.wakeup_write_fd);
        CGContextRelease(self.cg_context);
        // NSWindow and NSView are autoreleased by Cocoa
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
        // No-op on macOS (Cocoa display system handles this)
    }

    // =========================================================================
    // Event polling
    // =========================================================================

    pub fn getFd(self: *Self) ?std.posix.fd_t {
        return self.wakeup_read_fd;
    }

    pub fn pollEvents(self: *Self) ?Event {
        // 1. Pump Cocoa events: dispatch all pending NSApp events.
        //    This triggers our keyDown:/drawRect:/windowDidResize: callbacks
        //    which push into the event_queue ring buffer.
        const default_mode = getDefaultRunLoopMode();
        while (true) {
            const ns_event = msgSend_nextEvent(
                self.app,
                sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                NSEventMaskAny,
                null, // untilDate:nil — don't block
                default_mode,
                YES, // dequeue
            );
            if (ns_event) |ev| {
                // Dispatch to the appropriate target (NSWindow → NSView callbacks)
                msgSend_void_id(self.app, sel("sendEvent:"), ev);
            } else break;
        }

        // 2. Drain wakeup pipe
        var drain_buf: [64]u8 = undefined;
        _ = std.posix.read(self.wakeup_read_fd, &drain_buf) catch {};

        // 3. Return next queued event
        return self.popEvent();
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
    _ = class_addMethod(new_class, sel("drawRect:"), @constCast(@ptrCast(&ztDrawRect)), "v@:{CGRect=dddd}");
    _ = class_addMethod(new_class, sel("acceptsFirstResponder"), @constCast(@ptrCast(&ztAcceptsFirstResponder)), "c@:");
    _ = class_addMethod(new_class, sel("canBecomeKeyView"), @constCast(@ptrCast(&ztCanBecomeKeyView)), "c@:");

    // --- Keyboard ---
    _ = class_addMethod(new_class, sel("keyDown:"), @constCast(@ptrCast(&ztKeyDown)), "v@:@");
    _ = class_addMethod(new_class, sel("flagsChanged:"), @constCast(@ptrCast(&ztFlagsChanged)), "v@:@");
    // doCommandBySelector: is called by interpretKeyEvents: for non-text
    // keys (Enter, Tab, arrows, Escape, etc.). Without this, the default
    // NSView implementation calls NSBeep() for every unhandled command.
    // We handle all keys through the evdev key event path, so this is a no-op.
    _ = class_addMethod(new_class, sel("doCommandBySelector:"), @constCast(@ptrCast(&ztDoCommandBySelector)), "v@::");

    // --- NSTextInputClient ---
    _ = class_addMethod(new_class, sel("insertText:replacementRange:"), @constCast(@ptrCast(&ztInsertText)), "v@:@{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("hasMarkedText"), @constCast(@ptrCast(&ztHasMarkedText)), "c@:");
    _ = class_addMethod(new_class, sel("setMarkedText:selectedRange:replacementRange:"), @constCast(@ptrCast(&ztSetMarkedText)), "v@:@{_NSRange=QQ}{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("unmarkText"), @constCast(@ptrCast(&ztUnmarkText)), "v@:");
    _ = class_addMethod(new_class, sel("validAttributesForMarkedText"), @constCast(@ptrCast(&ztValidAttributes)), "@@:");
    _ = class_addMethod(new_class, sel("firstRectForCharacterRange:actualRange:"), @constCast(@ptrCast(&ztFirstRect)), "{CGRect=dddd}@:{_NSRange=QQ}^{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("characterIndexForPoint:"), @constCast(@ptrCast(&ztCharacterIndex)), "Q@:{CGPoint=dd}");
    _ = class_addMethod(new_class, sel("attributedSubstringForProposedRange:actualRange:"), @constCast(@ptrCast(&ztAttributedSubstring)), "@@:{_NSRange=QQ}^{_NSRange=QQ}");
    _ = class_addMethod(new_class, sel("markedRange"), @constCast(@ptrCast(&ztMarkedRange)), "{_NSRange=QQ}@:");
    _ = class_addMethod(new_class, sel("selectedRange"), @constCast(@ptrCast(&ztSelectedRange)), "{_NSRange=QQ}@:");

    // --- NSWindowDelegate ---
    _ = class_addMethod(new_class, sel("windowShouldClose:"), @constCast(@ptrCast(&ztWindowShouldClose)), "c@:@");
    _ = class_addMethod(new_class, sel("windowDidBecomeKey:"), @constCast(@ptrCast(&ztWindowDidBecomeKey)), "v@:@");
    _ = class_addMethod(new_class, sel("windowDidResignKey:"), @constCast(@ptrCast(&ztWindowDidResignKey)), "v@:@");
    _ = class_addMethod(new_class, sel("windowDidResize:"), @constCast(@ptrCast(&ztWindowDidResize)), "v@:@");
    _ = class_addMethod(new_class, sel("windowDidChangeOcclusionState:"), @constCast(@ptrCast(&ztWindowDidChangeOcclusion)), "v@:@");

    // --- NSView backing properties ---
    _ = class_addMethod(new_class, sel("viewDidChangeBackingProperties"), @constCast(@ptrCast(&ztViewDidChangeBackingProperties)), "v@:");

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

fn ztDoCommandBySelector(_: id, _: SEL, _: SEL) callconv(.c) void {
    // No-op: all keys are handled through the evdev key event path.
    // Without this, NSView's default calls NSBeep() for every
    // unhandled command selector (insertNewline:, insertTab:, etc.).
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
            0x09 => { // Cmd+V — paste
                handlePaste(backend);
                return;
            },
            else => return, // Other Cmd+ combos: ignore
        }
    }

    // Translate macOS keycode → evdev keycode
    const evdev_code = input_mod.macosToEvdev(@intCast(keycode & 0x7F));
    if (evdev_code != 0) {
        backend.pushEvent(.{ .key = .{
            .keycode = evdev_code,
            .pressed = true,
            .modifiers = flagsToModifiers(flags),
        } });
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

    // Skip all single-byte ASCII — these are already handled by the key
    // event path (macosToEvdev → translateKey). Without this guard, keys
    // like Enter (0x0D) and Tab (0x09) produce duplicates: one from the
    // key event and one from insertText. Only let through multi-byte
    // sequences (IME-composed text, dead key output, etc.).
    if (len == 1 and cstr[0] < 0x80) return;

    var text_event: TextEvent = .{};
    const copy_len = @min(len, text_event.data.len);
    @memcpy(text_event.data[0..copy_len], cstr[0..copy_len]);
    text_event.len = @intCast(copy_len);
    backend.pushEvent(.{ .text = text_event });

    backend.has_marked_text = false;
}

fn ztHasMarkedText(self_view: id, _: SEL) callconv(.c) BOOL {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return NO;
    return if (backend.has_marked_text) YES else NO;
}

fn ztSetMarkedText(self_view: id, _: SEL, _: id, _: NSRange, _: NSRange) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;
    backend.has_marked_text = true;
}

fn ztUnmarkText(self_view: id, _: SEL) callconv(.c) void {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return;
    backend.has_marked_text = false;
}

fn ztValidAttributes(_: id, _: SEL) callconv(.c) id {
    // Return empty NSArray
    return msgSend_id(cls("NSArray"), sel("array"));
}

fn ztFirstRect(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) CGRect {
    return CGRect.make(0, 0, 0, 0);
}

fn ztCharacterIndex(_: id, _: SEL, _: CGPoint) callconv(.c) NSUInteger {
    return std.math.maxInt(NSUInteger); // NSNotFound
}

fn ztAttributedSubstring(_: id, _: SEL, _: NSRange, _: ?*NSRange) callconv(.c) ?id {
    return null;
}

fn ztMarkedRange(self_view: id, _: SEL) callconv(.c) NSRange {
    const backend = MacosBackend.getBackendFromView(self_view) orelse return .{ .location = 0x7FFFFFFFFFFFFFFF, .length = 0 };
    if (backend.has_marked_text) {
        return .{ .location = 0, .length = 0 };
    }
    // NSNotFound
    return .{ .location = 0x7FFFFFFFFFFFFFFF, .length = 0 };
}

fn ztSelectedRange(_: id, _: SEL) callconv(.c) NSRange {
    return .{ .location = 0, .length = 0 };
}

// =============================================================================
// NSWindowDelegate callbacks
// =============================================================================

fn ztWindowShouldClose(self_view: id, _: SEL, _: id) callconv(.c) BOOL {
    if (MacosBackend.getBackendFromView(self_view)) |backend| {
        backend.pushEvent(.close);
    }
    return YES;
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
    const cstr = msgSend_cstr(str_obj, sel("UTF8String")) orelse return;
    const len = std.mem.len(cstr);
    if (len == 0) return;

    var paste_event: PasteEvent = .{};
    const copy_len = @min(len, paste_event.data.len);
    @memcpy(paste_event.data[0..copy_len], cstr[0..copy_len]);
    paste_event.len = @intCast(copy_len);
    backend.pushEvent(.{ .paste = paste_event });
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
    const f: *const fn (id, [*:0]const u8, *anyopaque) callconv(.c) void =
        @ptrCast(&object_setInstanceVariable);
    f(view, "_zt_backend", @ptrCast(backend));
}

extern "objc" fn object_setInstanceVariable(obj: id, name: [*:0]const u8, value: *anyopaque) void;

fn getDefaultRunLoopMode() id {
    // NSDefaultRunLoopMode is an NSString constant.
    // Access it as a global symbol exported by Foundation.
    const ptr = @extern(*const id, .{ .name = "NSDefaultRunLoopMode" });
    return ptr.*;
}
