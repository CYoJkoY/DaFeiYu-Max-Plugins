//! DaFeiYu authored-code plug-in SDK (ABI v1).
//!
//! A plug-in is one Zig file compiled to a freestanding `wasm32` reactor. It
//! exports four functions (`dfy_abi_version`, `dfy_alloc`, `dfy_free`,
//! `dfy_invoke`) and writes exactly one JSON response per event. This file is
//! the whole plumbing so a plug-in only implements an event handler.
//!
//! Minimal plug-in (`src/main.zig` next to a copy of this file):
//!
//! ```zig
//! const std = @import("std");
//! const dfy = @import("dfy.zig");
//!
//! fn onEvent(ctx: *dfy.Context) !void {
//!     if (dfy.getStr(ctx.event, "type")) |kind| {
//!         if (std.mem.eql(u8, kind, "tick")) {
//!             try ctx.reply.stateStr("ticks", "1");
//!             try ctx.reply.say("咕噜咕噜");
//!         }
//!     }
//!     ctx.reply.status("在线", null, null);
//! }
//!
//! comptime { dfy.install(onEvent); }
//! ```
//!
//! The host owns every side effect: the module never opens a socket, never
//! touches the disk and never calls the pet directly. It only describes what it
//! wants in the response envelope, and the host validates and performs it.

const std = @import("std");

/// The ABI this SDK implements. Must match `SCRIPT_ABI_VERSION` in the host.
pub const ABI_VERSION: i32 = 1;

const Allocator = std.mem.Allocator;

/// A parsed JSON value, re-exported so plug-ins need only import this file.
pub const Value = std.json.Value;

// ---------------------------------------------------------------------------
// JSON writer
// ---------------------------------------------------------------------------

const Level = struct {
    object: bool = true,
    count: usize = 0,
};

/// A tiny streaming JSON writer that owns its buffer.
///
/// The writer tracks one container level per nesting depth so it can emit the
/// separating commas and, for objects, the `key: value` colon. It never
/// re-encodes a child document: `raw` splices pre-rendered JSON so the host's
/// response can compose sub-documents (`state`, `effects`, `pet`) without a
/// second parse.
pub const Json = struct {
    alloc: Allocator,
    buf: std.ArrayList(u8) = .empty,
    levels: std.ArrayList(Level) = .empty,
    pending_key: bool = false,

    pub fn init(alloc: Allocator) Json {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Json) void {
        self.buf.deinit(self.alloc);
        self.levels.deinit(self.alloc);
    }

    pub fn slice(self: Json) []const u8 {
        return self.buf.items;
    }

    fn put(self: *Json, byte: u8) !void {
        try self.buf.append(self.alloc, byte);
    }

    fn putBytes(self: *Json, bytes: []const u8) !void {
        try self.buf.appendSlice(self.alloc, bytes);
    }

    fn beforeValue(self: *Json) !void {
        if (self.pending_key) {
            self.pending_key = false;
            return;
        }
        if (self.levels.items.len == 0) return;
        const top = &self.levels.items[self.levels.items.len - 1];
        if (top.count > 0) try self.put(',');
        top.count += 1;
    }

    pub fn beginObject(self: *Json) !void {
        try self.beforeValue();
        try self.put('{');
        try self.levels.append(self.alloc, .{ .object = true, .count = 0 });
    }

    pub fn endObject(self: *Json) !void {
        _ = self.levels.pop();
        self.pending_key = false;
        try self.put('}');
    }

    pub fn beginArray(self: *Json) !void {
        try self.beforeValue();
        try self.put('[');
        try self.levels.append(self.alloc, .{ .object = false, .count = 0 });
    }

    pub fn endArray(self: *Json) !void {
        _ = self.levels.pop();
        self.pending_key = false;
        try self.put(']');
    }

    /// Start an object member. The next value written must not add a comma.
    pub fn key(self: *Json, name: []const u8) !void {
        try self.beforeValue();
        try self.writeString(name);
        try self.put(':');
        self.pending_key = true;
    }

    fn writeString(self: *Json, text: []const u8) !void {
        const hex = "0123456789abcdef";
        try self.put('"');
        for (text) |byte| {
            switch (byte) {
                '"' => try self.putBytes("\\\""),
                '\\' => try self.putBytes("\\\\"),
                '\n' => try self.putBytes("\\n"),
                '\r' => try self.putBytes("\\r"),
                '\t' => try self.putBytes("\\t"),
                0x08 => try self.putBytes("\\b"),
                0x0c => try self.putBytes("\\f"),
                else => {
                    if (byte < 0x20) {
                        const escape = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };
                        try self.putBytes(&escape);
                    } else {
                        try self.put(byte);
                    }
                },
            }
        }
        try self.put('"');
    }

    pub fn str(self: *Json, text: []const u8) !void {
        try self.beforeValue();
        try self.writeString(text);
    }

    pub fn int(self: *Json, number: i64) !void {
        try self.beforeValue();
        var tmp: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "{d}", .{number}) catch return error.OutOfMemory;
        try self.putBytes(text);
    }

    pub fn float(self: *Json, number: f64) !void {
        try self.beforeValue();
        if (!std.math.isFinite(number)) {
            try self.putBytes("null");
            return;
        }
        var tmp: [40]u8 = undefined;
        const text = std.fmt.bufPrint(&tmp, "{d}", .{number}) catch return error.OutOfMemory;
        try self.putBytes(text);
    }

    pub fn boolean(self: *Json, flag: bool) !void {
        try self.beforeValue();
        try self.putBytes(if (flag) "true" else "false");
    }

    pub fn nul(self: *Json) !void {
        try self.beforeValue();
        try self.putBytes("null");
    }

    /// Splice an already-rendered JSON fragment.
    pub fn raw(self: *Json, json: []const u8) !void {
        try self.beforeValue();
        try self.putBytes(json);
    }

    /// Re-encode a parsed value (used by plug-ins that echo state back).
    pub fn value(self: *Json, item: Value) !void {
        switch (item) {
            .null => try self.nul(),
            .bool => |flag| try self.boolean(flag),
            .integer => |number| try self.int(number),
            .float => |number| try self.float(number),
            .number_string => |text| {
                try self.beforeValue();
                try self.putBytes(text);
            },
            .string => |text| try self.str(text),
            .array => |list| {
                try self.beginArray();
                for (list.items) |child| try self.value(child);
                try self.endArray();
            },
            .object => |map| {
                try self.beginObject();
                var it = map.iterator();
                while (it.next()) |entry| {
                    try self.key(entry.key_ptr.*);
                    try self.value(entry.value_ptr.*);
                }
                try self.endObject();
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Input helpers
// ---------------------------------------------------------------------------

/// Read `key` from an object value; `null` when absent or when `item` is not an object.
pub fn get(item: Value, key_name: []const u8) ?Value {
    return switch (item) {
        .object => |map| map.get(key_name),
        else => null,
    };
}

pub fn getStr(item: Value, key_name: []const u8) ?[]const u8 {
    const found = get(item, key_name) orelse return null;
    return switch (found) {
        .string => |text| text,
        else => null,
    };
}

pub fn getInt(item: Value, key_name: []const u8) ?i64 {
    const found = get(item, key_name) orelse return null;
    return switch (found) {
        .integer => |number| number,
        .float => |number| blk: {
            if (!std.math.isFinite(number) or number < -9.2e18 or number > 9.2e18) break :blk null;
            break :blk @intFromFloat(number);
        },
        else => null,
    };
}

pub fn getFloat(item: Value, key_name: []const u8) ?f64 {
    const found = get(item, key_name) orelse return null;
    return switch (found) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => null,
    };
}

pub fn getBool(item: Value, key_name: []const u8) ?bool {
    const found = get(item, key_name) orelse return null;
    return switch (found) {
        .bool => |flag| flag,
        else => null,
    };
}

/// The items of an array value, or an empty slice.
pub fn getItems(item: Value) []const Value {
    return switch (item) {
        .array => |list| list.items,
        else => &[_]Value{},
    };
}

/// The items of `key` when it holds an array, or an empty slice.
pub fn getList(item: Value, key_name: []const u8) []const Value {
    return getItems(get(item, key_name) orelse .null);
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
// ---------------------------------------------------------------------------
// Response builder
// ---------------------------------------------------------------------------

/// One invocation's outgoing envelope, built up by the handler.
///
/// `state` and the two effect lists are rendered separately and spliced at the
/// end, so a handler can append pet reactions and HTTP requests in any order.
pub const Reply = struct {
    alloc: Allocator,
    state: Json,
    effects: Json,
    pet: Json,
    status_text: ?[]const u8 = null,
    status_progress: ?f64 = null,
    status_counter: ?i64 = null,
    log_text: ?[]const u8 = null,
    schedule_ms: ?u64 = null,
    disable_flag: bool = false,

    pub fn init(alloc: Allocator) !Reply {
        var reply = Reply{
            .alloc = alloc,
            .state = Json.init(alloc),
            .effects = Json.init(alloc),
            .pet = Json.init(alloc),
        };
        // The two effect lists are always emitted, so open their arrays up
        // front; each entry is then appended as an object.
        try reply.effects.beginArray();
        try reply.pet.beginArray();
        // The state object is always open: flat keys are the common case, and a
        // handler that needs nesting uses `stateWriter()` to append containers.
        try reply.state.beginObject();
        return reply;
    }

    pub fn deinit(self: *Reply) void {
        self.state.deinit();
        self.effects.deinit();
        self.pet.deinit();
    }

    /// Kept for readability; the state object is always open, so this is a no-op.
    pub fn stateBegin(self: *Reply) void {
        _ = self;
    }

    /// Kept for readability; the host closes the state object when composing.
    pub fn stateEnd(self: *Reply) void {
        _ = self;
    }

    /// The underlying state writer, for nested containers
    /// (`key` → `beginArray` → … → `endArray`, or `key` → `value`).
    pub fn stateWriter(self: *Reply) *Json {
        return &self.state;
    }

    pub fn stateStr(self: *Reply, key_name: []const u8, value_text: []const u8) !void {
        try self.state.key(key_name);
        try self.state.str(value_text);
    }

    pub fn stateInt(self: *Reply, key_name: []const u8, value_number: i64) !void {
        try self.state.key(key_name);
        try self.state.int(value_number);
    }

    pub fn stateFloat(self: *Reply, key_name: []const u8, value_number: f64) !void {
        try self.state.key(key_name);
        try self.state.float(value_number);
    }

    pub fn stateBool(self: *Reply, key_name: []const u8, value_flag: bool) !void {
        try self.state.key(key_name);
        try self.state.boolean(value_flag);
    }

    pub fn stateValue(self: *Reply, key_name: []const u8, value_item: Value) !void {
        try self.state.key(key_name);
        try self.state.value(value_item);
    }

    /// Ask the host to perform one HTTP request. Results arrive in the next
    /// `effect-result` event under the same `id`.
    pub fn httpRequest(
        self: *Reply,
        id: []const u8,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
    ) !void {
        try self.effects.beginObject();
        try self.effects.key("id");
        try self.effects.str(id);
        try self.effects.key("type");
        try self.effects.str("http");
        try self.effects.key("method");
        try self.effects.str(method);
        try self.effects.key("url");
        try self.effects.str(url);
        if (body) |payload| {
            try self.effects.key("body");
            try self.effects.str(payload);
        }
        try self.effects.endObject();
    }

    pub fn httpGet(self: *Reply, id: []const u8, url: []const u8) !void {
        try self.httpRequest(id, "GET", url, null);
    }

    pub fn say(self: *Reply, text: []const u8) !void {
        try self.pet.beginObject();
        try self.pet.key("type");
        try self.pet.str("say");
        try self.pet.key("text");
        try self.pet.str(text);
        try self.pet.endObject();
    }

    pub fn play(self: *Reply, clip: []const u8) !void {
        try self.pet.beginObject();
        try self.pet.key("type");
        try self.pet.str("play");
        try self.pet.key("clip");
        try self.pet.str(clip);
        try self.pet.endObject();
    }

    pub fn notify(self: *Reply, title: []const u8, body: []const u8) !void {
        try self.pet.beginObject();
        try self.pet.key("type");
        try self.pet.str("notify");
        try self.pet.key("title");
        try self.pet.str(title);
        try self.pet.key("body");
        try self.pet.str(body);
        try self.pet.endObject();
    }

    /// Report a one-line status the panel can show. `progress` is 0..1.
    pub fn status(self: *Reply, message: []const u8, progress: ?f64, counter: ?i64) void {
        self.status_text = message;
        self.status_progress = progress;
        self.status_counter = counter;
    }

    /// Attach a diagnostic line to the response (separate from `log()` streaming).
    pub fn logText(self: *Reply, text: []const u8) void {
        self.log_text = text;
    }

    /// Ask the host to fire another `tick` after `after_ms`.
    pub fn schedule(self: *Reply, after_ms: u64) void {
        self.schedule_ms = if (after_ms < 500) 500 else after_ms;
    }

    /// Ask the host to switch this plug-in off.
    pub fn disable(self: *Reply) void {
        self.disable_flag = true;
    }

    /// Render the full envelope into `out`.
    pub fn compose(self: *Reply, out: *Json) !void {
        try self.state.endObject();
        try self.effects.endArray();
        try self.pet.endArray();
        try out.beginObject();
        try out.key("state");
        try out.raw(self.state.buf.items);
        try out.key("effects");
        try out.raw(self.effects.buf.items);
        try out.key("pet");
        try out.raw(self.pet.buf.items);
        if (self.status_text) |message| {
            try out.key("status");
            try out.beginObject();
            try out.key("message");
            try out.str(message);
            try out.key("progress");
            if (self.status_progress) |progress| try out.float(progress) else try out.nul();
            try out.key("counter");
            if (self.status_counter) |counter| try out.int(counter) else try out.nul();
            try out.endObject();
        }
        if (self.log_text) |text| {
            try out.key("log");
            try out.str(text);
        }
        if (self.schedule_ms) |milliseconds| {
            try out.key("schedule");
            try out.beginObject();
            try out.key("afterMs");
            try out.int(@intCast(milliseconds));
            try out.endObject();
        }
        if (self.disable_flag) {
            try out.key("disable");
            try out.boolean(true);
        }
        try out.endObject();
    }
};
// ---------------------------------------------------------------------------
// Event handler plumbing
// ---------------------------------------------------------------------------

/// Everything a handler may read, plus the reply it fills in.
pub const Context = struct {
    alloc: Allocator,
    /// The whole envelope: `{ abi, plugin, event, config, state, now }`.
    input: Value,
    /// `input.event` - what just happened (`install`, `activate`, `tick`, ...).
    event: Value,
    /// `input.config` - bridge URL, interests, per-plugin options, locale.
    config: Value,
    /// `input.state` - the plug-in's own persisted state from the last call.
    state: Value,
    /// Milliseconds since the Unix epoch.
    now: i64,
    out: *Json,
    reply: *Reply,
};

pub const Handler = *const fn (*Context) anyerror!void;

/// Stream one log line to the host (imported as `env.dfy_log`).
extern "env" fn dfy_log(level: u32, ptr: u32, len: u32) void;

/// `level` is advisory: 0 = debug, 1 = info, 2 = warn, 3 = error.
pub fn log(level: u32, message: []const u8) void {
    dfy_log(level, @intCast(@intFromPtr(message.ptr)), @intCast(message.len));
}

pub fn info(message: []const u8) void {
    log(1, message);
}

// ---------------------------------------------------------------------------
// ABI entry points
// ---------------------------------------------------------------------------

fn wasmAlloc(len: u32) u32 {
    const size: usize = @max(@as(usize, len), 1);
    const buf = std.heap.wasm_allocator.alloc(u8, size) catch return 0;
    return @intCast(@intFromPtr(buf.ptr));
}

fn wasmFree(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const size: usize = @max(@as(usize, len), 1);
    const slice: []u8 = @as([*]u8, @ptrFromInt(ptr))[0..size];
    std.heap.wasm_allocator.free(slice);
}

fn region(ptr: u32, len: u32) []u8 {
    if (ptr == 0 or len == 0) return &[_]u8{};
    return @as([*]u8, @ptrFromInt(ptr))[0..len];
}

fn copyOut(out_ptr: u32, out_cap: u32, bytes: []const u8) u32 {
    if (bytes.len > out_cap) return @intCast(bytes.len);
    const dest = region(out_ptr, @intCast(bytes.len));
    @memcpy(dest, bytes);
    return @intCast(bytes.len);
}

const FALLBACK = "{\"state\":{},\"effects\":[],\"pet\":[]}";

fn invokeWith(
    comptime handler: Handler,
    in_ptr: u32,
    in_len: u32,
    out_ptr: u32,
    out_cap: u32,
) u32 {
    const alloc = std.heap.wasm_allocator;
    const input_bytes: []const u8 = region(in_ptr, in_len);
    const parsed = std.json.parseFromSlice(Value, alloc, input_bytes, .{}) catch {
        return copyOut(out_ptr, out_cap, FALLBACK);
    };
    defer parsed.deinit();

    var reply = Reply.init(alloc) catch {
        return copyOut(out_ptr, out_cap, FALLBACK);
    };
    defer reply.deinit();
    var out = Json.init(alloc);
    defer out.deinit();
    var ctx = Context{
        .alloc = alloc,
        .input = parsed.value,
        .event = get(parsed.value, "event") orelse .null,
        .config = get(parsed.value, "config") orelse .null,
        .state = get(parsed.value, "state") orelse .null,
        .now = getInt(parsed.value, "now") orelse 0,
        .out = &out,
        .reply = &reply,
    };
    handler(&ctx) catch {
        return copyOut(out_ptr, out_cap, FALLBACK);
    };
    reply.compose(&out) catch {
        return copyOut(out_ptr, out_cap, FALLBACK);
    };
    return copyOut(out_ptr, out_cap, out.slice());
}

/// Wire a plug-in handler into the ABI. Call once from a `comptime` block:
///
/// ```zig
/// comptime { dfy.install(onEvent); }
/// ```
///
/// The four exports are generated here because Zig's linker drops plain
/// `export fn`s from a `-fno-entry` reactor; `@export` at comptime is the form
/// that reliably survives into the module's export section.
pub fn install(comptime handler: Handler) void {
    const Exports = struct {
        fn abiVersion() callconv(.c) i32 {
            return ABI_VERSION;
        }

        fn allocate(len: u32) callconv(.c) u32 {
            return wasmAlloc(len);
        }

        fn release(ptr: u32, len: u32) callconv(.c) void {
            wasmFree(ptr, len);
        }

        fn invoke(in_ptr: u32, in_len: u32, out_ptr: u32, out_cap: u32) callconv(.c) u32 {
            return invokeWith(handler, in_ptr, in_len, out_ptr, out_cap);
        }
    };
    @export(&Exports.abiVersion, .{ .name = "dfy_abi_version" });
    @export(&Exports.allocate, .{ .name = "dfy_alloc" });
    @export(&Exports.release, .{ .name = "dfy_free" });
    @export(&Exports.invoke, .{ .name = "dfy_invoke" });
}
