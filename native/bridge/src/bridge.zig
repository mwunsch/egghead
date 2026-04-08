// Egghead.OpenTUI NIF bridge — Elixir <-> OpenTUI's Zig core.
//
// Lifecycle NIFs:
//   create_renderer(width, height) -> {ok, handle}
//   setup_terminal(handle)
//   destroy_renderer(handle)
//   enter_raw_mode() / leave_raw_mode()
//   tty_size() / drain_input(timeout_ms) / resize(handle, w, h)
//
// Per-frame draw NIFs:
//   begin_frame(handle)
//   clear(handle, bg_binary)
//   fill_rect(handle, x, y, w, h, bg_binary)
//   draw_text(handle, text, x, y, fg_binary, bg_binary_or_empty, attrs)
//   end_frame(handle)
//
// Invariants:
//   * Elixir NEVER holds a raw renderer pointer. Every renderer
//     lives behind an integer handle in this module's HashMap,
//     protected by a mutex. A bad handle returns badarg; it
//     cannot crash the BEAM by dereferencing random memory.
//   * begin_frame caches the back buffer pointer in the registry
//     entry. Subsequent draw NIFs reuse it without re-resolving.
//     end_frame clears the cached buffer and runs the diff render.

const std = @import("std");

const erl = @cImport({
    @cInclude("erl_nif.h");
});

const posix = @cImport({
    @cInclude("termios.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("errno.h");
});

// OpenTUI C ABI surface used by the spike. Keep minimal. Extend as needed.
extern fn createRenderer(width: u32, height: u32, testing: bool, remote: bool) ?*anyopaque;
extern fn destroyRenderer(renderer: *anyopaque) void;
extern fn setupTerminal(renderer: *anyopaque, useAlternateScreen: bool) void;
extern fn setUseThread(renderer: *anyopaque, useThread: bool) void;
extern fn getNextBuffer(renderer: *anyopaque) *anyopaque;
extern fn bufferClear(buf: *anyopaque, bg: [*]const f32) void;
extern fn bufferDrawText(
    buf: *anyopaque,
    text: [*]const u8,
    textLen: usize,
    x: u32,
    y: u32,
    fg: [*]const f32,
    bg: ?[*]const f32,
    attributes: u32,
) void;
extern fn render(renderer: *anyopaque, force: bool) void;
extern fn bufferFillRect(
    buf: *anyopaque,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bg: [*]const f32,
) void;
extern fn resizeRenderer(renderer: *anyopaque, width: u32, height: u32) void;
extern fn setCursorPosition(renderer: *anyopaque, x: i32, y: i32, visible: bool) void;

// ---- Handle registry -------------------------------------------------------

// One entry per live renderer. `current_buffer` is set by begin_frame and
// cleared by end_frame so the small per-cell draw NIFs don't have to
// re-resolve the back buffer every call.
const Entry = struct {
    renderer: *anyopaque,
    current_buffer: ?*anyopaque = null,
};

const Registry = struct {
    mutex: std.Thread.Mutex = .{},
    next_id: u64 = 1,
    map: std.AutoHashMap(u64, Entry),

    fn init(allocator: std.mem.Allocator) Registry {
        return .{ .map = std.AutoHashMap(u64, Entry).init(allocator) };
    }

    fn insert(self: *Registry, ptr: *anyopaque) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;
        try self.map.put(id, .{ .renderer = ptr });
        return id;
    }

    fn getRenderer(self: *Registry, id: u64) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(id) orelse return null;
        return e.renderer;
    }

    fn getBuffer(self: *Registry, id: u64) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(id) orelse return null;
        return e.current_buffer;
    }

    fn setBuffer(self: *Registry, id: u64, buf: ?*anyopaque) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.map.getEntry(id) orelse return false;
        gop.value_ptr.current_buffer = buf;
        return true;
    }

    fn remove(self: *Registry, id: u64) ?*anyopaque {
        self.mutex.lock();
        defer self.mutex.unlock();
        const e = self.map.get(id) orelse return null;
        _ = self.map.remove(id);
        return e.renderer;
    }
};

var registry_storage: Registry = undefined;
var registry_initialized: bool = false;
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

// Termios state for raw-mode management. We open /dev/tty directly
// inside the NIF because BEAM ports don't inherit the controlling
// terminal, so subprocess `stty` calls cannot reach it.
var raw_mode_tty_fd: c_int = -1;
var raw_mode_saved: posix.termios = undefined;
var raw_mode_active: bool = false;

fn registry() *Registry {
    if (!registry_initialized) {
        registry_storage = Registry.init(gpa.allocator());
        registry_initialized = true;
    }
    return &registry_storage;
}

// ---- NIF helpers -----------------------------------------------------------

fn makeOkHandle(env: ?*erl.ErlNifEnv, id: u64) erl.ERL_NIF_TERM {
    const ok = erl.enif_make_atom(env, "ok");
    const handle_term = erl.enif_make_uint64(env, id);
    return erl.enif_make_tuple2(env, ok, handle_term);
}

fn atom(env: ?*erl.ErlNifEnv, name: [*:0]const u8) erl.ERL_NIF_TERM {
    return erl.enif_make_atom(env, name);
}

fn badarg(env: ?*erl.ErlNifEnv) erl.ERL_NIF_TERM {
    return erl.enif_make_badarg(env);
}

// ---- NIF entry points ------------------------------------------------------

fn nif_create_renderer(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 2) return badarg(env);

    var width: c_uint = 0;
    var height: c_uint = 0;
    if (erl.enif_get_uint(env, argv[0], &width) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[1], &height) == 0) return badarg(env);

    const ptr = createRenderer(@intCast(width), @intCast(height), false, false) orelse {
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "create_failed"));
    };

    // Single-threaded rendering — our NIF calls drive frame timing from BEAM.
    setUseThread(ptr, false);

    const id = registry().insert(ptr) catch {
        destroyRenderer(ptr);
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "registry_full"));
    };
    return makeOkHandle(env, id);
}

fn nif_setup_terminal(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 1) return badarg(env);

    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    const ptr = registry().getRenderer(id) orelse return badarg(env);
    setupTerminal(ptr, true); // use alternate screen
    return atom(env, "ok");
}

fn nif_enter_raw_mode(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    _: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 0) return badarg(env);
    if (raw_mode_active) return atom(env, "ok");

    const fd = posix.open("/dev/tty", posix.O_RDWR);
    if (fd < 0) {
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "open_tty_failed"));
    }

    if (posix.tcgetattr(fd, &raw_mode_saved) != 0) {
        _ = posix.close(fd);
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "tcgetattr_failed"));
    }

    var raw = raw_mode_saved;
    posix.cfmakeraw(&raw);
    if (posix.tcsetattr(fd, posix.TCSANOW, &raw) != 0) {
        _ = posix.close(fd);
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "tcsetattr_failed"));
    }

    raw_mode_tty_fd = fd;
    raw_mode_active = true;
    return atom(env, "ok");
}

fn nif_tty_size(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    _: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 0) return badarg(env);

    const fd = posix.open("/dev/tty", posix.O_RDWR);
    if (fd < 0) {
        // Fall back to env vars via BEAM if /dev/tty is not reachable.
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "open_tty_failed"));
    }
    defer _ = posix.close(fd);

    var ws: posix.winsize = undefined;
    if (posix.ioctl(fd, posix.TIOCGWINSZ, &ws) != 0) {
        return erl.enif_make_tuple2(env, atom(env, "error"), atom(env, "ioctl_failed"));
    }

    const ok = atom(env, "ok");
    const cols = erl.enif_make_uint(env, ws.ws_col);
    const rows = erl.enif_make_uint(env, ws.ws_row);
    return erl.enif_make_tuple2(env, ok, erl.enif_make_tuple2(env, cols, rows));
}

fn nif_drain_input(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    // drain_input(timeout_ms): consume and discard any bytes already on the
    // controlling terminal, used to swallow OpenTUI's capability-query
    // responses before we start reading user keypresses.
    if (argc != 1) return badarg(env);

    var timeout_ms: c_uint = 0;
    if (erl.enif_get_uint(env, argv[0], &timeout_ms) == 0) return badarg(env);

    // Open a fresh O_NONBLOCK fd for draining. A non-blocking read loop
    // is simpler and more portable than poll() — some pty stacks (observed
    // under termscope) return POLLNVAL for the raw-mode fd even when it's
    // readable, so we avoid poll() entirely.
    const fd = posix.open("/dev/tty", posix.O_RDONLY | posix.O_NONBLOCK);
    if (fd < 0) return atom(env, "ok");
    defer _ = posix.close(fd);

    const slice_ms: u32 = 20;
    const slices: u32 = @max(1, timeout_ms / slice_ms);

    var buf: [256]u8 = undefined;
    var total: usize = 0;
    var idle_slices: u32 = 0;

    var i: u32 = 0;
    while (i < slices) : (i += 1) {
        const n = posix.read(fd, &buf, buf.len);
        if (n > 0) {
            total += @intCast(n);
            idle_slices = 0;
        } else {
            idle_slices += 1;
            // Early exit: after at least one successful read, stop as soon
            // as 3 consecutive idle slices (~60ms) pass with no more data.
            if (total > 0 and idle_slices >= 3) break;
        }
        _ = posix.usleep(slice_ms * 1000);
    }

    return atom(env, "ok");
}

fn nif_leave_raw_mode(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    _: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 0) return badarg(env);
    if (!raw_mode_active) return atom(env, "ok");

    _ = posix.tcsetattr(raw_mode_tty_fd, posix.TCSANOW, &raw_mode_saved);
    _ = posix.close(raw_mode_tty_fd);
    raw_mode_tty_fd = -1;
    raw_mode_active = false;
    return atom(env, "ok");
}

// ---- Per-frame draw NIFs ---------------------------------------------------
//
// The pattern from Elixir is:
//
//   begin_frame(handle)
//   clear(handle, bg_binary)
//   draw_text(handle, text, x, y, fg_binary, bg_binary | <<>>, attrs)
//   ... more draw calls ...
//   end_frame(handle)   // calls render(force=false)
//
// Colors are 16-byte little-endian binaries holding 4 f32s (r, g, b, a).
// Building them in Elixir is one `<<r::float-32-little, ...>>` per palette
// entry, done at compile time, so the loop never allocates.

fn readColorBinary(env: ?*erl.ErlNifEnv, term: erl.ERL_NIF_TERM, out: *[4]f32) bool {
    var bin: erl.ErlNifBinary = undefined;
    if (erl.enif_inspect_binary(env, term, &bin) == 0) return false;
    if (bin.size != 16) return false;
    const src: [*]const u8 = @ptrCast(bin.data);
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var f: f32 = 0;
        const dst: [*]u8 = @ptrCast(&f);
        var j: usize = 0;
        while (j < 4) : (j += 1) dst[j] = src[i * 4 + j];
        out[i] = f;
    }
    return true;
}

fn nif_begin_frame(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 1) return badarg(env);
    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    const ptr = registry().getRenderer(id) orelse return badarg(env);
    const buf = getNextBuffer(ptr);
    if (!registry().setBuffer(id, buf)) return badarg(env);
    return atom(env, "ok");
}

fn nif_clear(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 2) return badarg(env);
    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    var bg: [4]f32 = .{ 0, 0, 0, 1 };
    if (!readColorBinary(env, argv[1], &bg)) return badarg(env);

    const buf = registry().getBuffer(id) orelse return badarg(env);
    bufferClear(buf, &bg);
    return atom(env, "ok");
}

fn nif_draw_text(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    // draw_text(handle, text, x, y, fg, bg_or_empty, attrs)
    if (argc != 7) return badarg(env);

    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    var text_bin: erl.ErlNifBinary = undefined;
    if (erl.enif_inspect_binary(env, argv[1], &text_bin) == 0) return badarg(env);

    var x: c_uint = 0;
    var y: c_uint = 0;
    if (erl.enif_get_uint(env, argv[2], &x) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[3], &y) == 0) return badarg(env);

    var fg: [4]f32 = .{ 1, 1, 1, 1 };
    if (!readColorBinary(env, argv[4], &fg)) return badarg(env);

    // bg may be an empty binary meaning "transparent"
    var bg_bin: erl.ErlNifBinary = undefined;
    if (erl.enif_inspect_binary(env, argv[5], &bg_bin) == 0) return badarg(env);
    var bg: [4]f32 = .{ 0, 0, 0, 0 };
    var bg_ptr: ?[*]const f32 = null;
    if (bg_bin.size == 16) {
        if (!readColorBinary(env, argv[5], &bg)) return badarg(env);
        bg_ptr = &bg;
    } else if (bg_bin.size != 0) {
        return badarg(env);
    }

    var attrs: c_uint = 0;
    if (erl.enif_get_uint(env, argv[6], &attrs) == 0) return badarg(env);

    const buf = registry().getBuffer(id) orelse return badarg(env);

    bufferDrawText(
        buf,
        @ptrCast(text_bin.data),
        text_bin.size,
        @intCast(x),
        @intCast(y),
        &fg,
        bg_ptr,
        @intCast(attrs),
    );
    return atom(env, "ok");
}

fn nif_end_frame(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 1) return badarg(env);
    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    const ptr = registry().getRenderer(id) orelse return badarg(env);
    // Hit the diff renderer path; force=true is reserved for spike debugging.
    render(ptr, false);
    _ = registry().setBuffer(id, null);
    return atom(env, "ok");
}

fn nif_fill_rect(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    // fill_rect(handle, x, y, w, h, bg_binary)
    if (argc != 6) return badarg(env);

    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    var x: c_uint = 0;
    var y: c_uint = 0;
    var w: c_uint = 0;
    var h: c_uint = 0;
    if (erl.enif_get_uint(env, argv[1], &x) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[2], &y) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[3], &w) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[4], &h) == 0) return badarg(env);

    var bg: [4]f32 = .{ 0, 0, 0, 1 };
    if (!readColorBinary(env, argv[5], &bg)) return badarg(env);

    const buf = registry().getBuffer(id) orelse return badarg(env);
    bufferFillRect(buf, @intCast(x), @intCast(y), @intCast(w), @intCast(h), &bg);
    return atom(env, "ok");
}

fn nif_resize(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 3) return badarg(env);

    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    var w: c_uint = 0;
    var h: c_uint = 0;
    if (erl.enif_get_uint(env, argv[1], &w) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[2], &h) == 0) return badarg(env);

    const ptr = registry().getRenderer(id) orelse return badarg(env);
    resizeRenderer(ptr, @intCast(w), @intCast(h));
    return atom(env, "ok");
}

fn nif_set_cursor_position(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    // set_cursor_position(handle, x, y, visible)
    //
    // Our entire bridge API is 0-indexed (draw_text, fill_rect,
    // etc. all use top-left = (0, 0)). OpenTUI's setCursorPosition
    // is 1-indexed (ANSI-style; it clamps coordinates to
    // max(1, ...) internally), so we add 1 here at the boundary
    // to keep callers consistent.
    if (argc != 4) return badarg(env);

    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    var x: c_uint = 0;
    var y: c_uint = 0;
    if (erl.enif_get_uint(env, argv[1], &x) == 0) return badarg(env);
    if (erl.enif_get_uint(env, argv[2], &y) == 0) return badarg(env);

    // visible arg is :true or :false atom
    const visible_atom = argv[3];
    const true_atom = atom(env, "true");
    const visible = erl.enif_compare(visible_atom, true_atom) == 0;

    const ptr = registry().getRenderer(id) orelse return badarg(env);
    setCursorPosition(ptr, @intCast(x + 1), @intCast(y + 1), visible);
    return atom(env, "ok");
}

fn nif_destroy_renderer(
    env: ?*erl.ErlNifEnv,
    argc: c_int,
    argv: [*c]const erl.ERL_NIF_TERM,
) callconv(.c) erl.ERL_NIF_TERM {
    if (argc != 1) return badarg(env);

    var id: u64 = 0;
    if (erl.enif_get_uint64(env, argv[0], &id) == 0) return badarg(env);

    const ptr = registry().remove(id) orelse return badarg(env);
    destroyRenderer(ptr);
    return atom(env, "ok");
}

// ---- NIF registration ------------------------------------------------------

const nif_funcs = [_]erl.ErlNifFunc{
    .{ .name = "create_renderer", .arity = 2, .fptr = nif_create_renderer, .flags = 0 },
    .{ .name = "setup_terminal", .arity = 1, .fptr = nif_setup_terminal, .flags = 0 },
    .{ .name = "destroy_renderer", .arity = 1, .fptr = nif_destroy_renderer, .flags = 0 },
    .{ .name = "enter_raw_mode", .arity = 0, .fptr = nif_enter_raw_mode, .flags = 0 },
    .{ .name = "leave_raw_mode", .arity = 0, .fptr = nif_leave_raw_mode, .flags = 0 },
    .{ .name = "tty_size", .arity = 0, .fptr = nif_tty_size, .flags = 0 },
    .{ .name = "drain_input", .arity = 1, .fptr = nif_drain_input, .flags = 0 },
    .{ .name = "begin_frame", .arity = 1, .fptr = nif_begin_frame, .flags = 0 },
    .{ .name = "clear", .arity = 2, .fptr = nif_clear, .flags = 0 },
    .{ .name = "draw_text", .arity = 7, .fptr = nif_draw_text, .flags = 0 },
    .{ .name = "end_frame", .arity = 1, .fptr = nif_end_frame, .flags = 0 },
    .{ .name = "fill_rect", .arity = 6, .fptr = nif_fill_rect, .flags = 0 },
    .{ .name = "resize", .arity = 3, .fptr = nif_resize, .flags = 0 },
    .{ .name = "set_cursor_position", .arity = 4, .fptr = nif_set_cursor_position, .flags = 0 },
};

fn on_load(
    _: ?*erl.ErlNifEnv,
    _: [*c]?*anyopaque,
    _: erl.ERL_NIF_TERM,
) callconv(.c) c_int {
    return 0;
}

var entry: erl.ErlNifEntry = .{
    .major = erl.ERL_NIF_MAJOR_VERSION,
    .minor = erl.ERL_NIF_MINOR_VERSION,
    .name = "Elixir.Egghead.OpenTUI.Bridge",
    .num_of_funcs = nif_funcs.len,
    .funcs = @constCast(&nif_funcs[0]),
    .load = on_load,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = "beam.vanilla",
    // The `options` field is unused by the runtime except to distinguish
    // dirty NIF entry configs. 1 matches what the ERL_NIF_INIT macro emits.
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = @sizeOf(erl.ErlNifResourceTypeInit),
    .min_erts = "erts-16.0",
};

export fn nif_init() *erl.ErlNifEntry {
    return &entry;
}
