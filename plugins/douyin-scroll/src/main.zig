//! 刷抖音 · Douyin scroller
//!
//! The plug-in never touches the network itself. It asks the host for the
//! bridge feed, ranks what comes back against the user's interests, lets the
//! pet say one line, and asks to be woken up later. Everything else - the
//! request, the pet reaction, the persisted state - belongs to the host.
const std = @import("std");
const dfy = @import("dfy.zig");

/// How many item ids we remember so we do not repeat ourselves.
const seen_limit: usize = 40;
const feed_limit: usize = 20;

fn isString(item: dfy.Value) bool {
    return item == .string;
}

fn containsId(seen: []const dfy.Value, id: []const u8) bool {
    for (seen) |entry| {
        if (!isString(entry)) continue;
        if (dfy.eql(entry.string, id)) return true;
    }
    return false;
}

/// Interests are plain substrings; a match in the title counts more than one in
/// the author name, so "编程" beats a creator whose handle merely contains it.
fn interestScore(interests: []const dfy.Value, title: []const u8, author: []const u8) f64 {
    var score: f64 = 0;
    for (interests) |interest| {
        if (!isString(interest)) continue;
        const word = interest.string;
        if (word.len == 0) continue;
        if (std.mem.indexOf(u8, title, word) != null) score += 2_000;
        if (std.mem.indexOf(u8, author, word) != null) score += 600;
    }
    return score;
}

fn findEffect(list: []const dfy.Value, id: []const u8) ?dfy.Value {
    for (list) |entry| {
        if (entry != .object) continue;
        const effect_id = dfy.getStr(entry, "id") orelse continue;
        if (dfy.eql(effect_id, id)) return entry;
    }
    return null;
}

fn clampSeconds(raw: i64) u64 {
    const bounded = if (raw < 5) 5 else if (raw > 300) 300 else raw;
    return @intCast(bounded * 1000);
}

/// Bridges report heat in wildly different ranges (a few likes, or millions),
/// so it is folded into 0..1000 before scoring: popularity still breaks ties
/// between equally relevant clips, but one very hot video can never bury an
/// interest match.
fn hotScore(item: dfy.Value) f64 {
    const raw = dfy.getFloat(item, "hot") orelse 0;
    return if (raw < 0) 0 else if (raw > 1_000) 1_000 else raw;
}

fn onEvent(ctx: *dfy.Context) anyerror!void {
    const reply = ctx.reply;
    const kind = dfy.getStr(ctx.event, "type") orelse "tick";

    const options = dfy.get(ctx.config, "options") orelse .null;
    const bridge = dfy.getStr(options, "bridgeUrl") orelse "";
    const interval = dfy.getInt(options, "intervalSeconds") orelse 20;
    const boost = dfy.getBool(options, "interestBoost") orelse true;
    const interests = dfy.getList(ctx.config, "interests");

    const counter = dfy.getInt(ctx.state, "counter") orelse 0;
    const seen = dfy.getList(ctx.state, "seen");
    try reply.stateInt("counter", counter);

    if (dfy.eql(kind, "install")) {
        reply.status("刷抖音插件已就绪", null, counter);
        return;
    }

    if (dfy.eql(kind, "deactivate")) {
        reply.status("已暂停刷抖音", null, counter);
        return;
    }

    if (dfy.eql(kind, "activate")) {
        if (bridge.len == 0) {
            try reply.say("还没配置抖音桥接地址，先在面板里填上吧。");
            reply.status("等待配置桥接地址", null, counter);
            return;
        }
        reply.status("准备刷抖音…", null, counter);
        reply.schedule(1200);
        return;
    }

    if (dfy.eql(kind, "command")) {
        const name = dfy.getStr(ctx.event, "name") orelse "";
        if (dfy.eql(name, "reset")) {
            try reply.stateInt("counter", 0);
            try reply.say("计数清零，重新开始刷。");
            reply.status("已重置刷抖音计数", null, 0);
            reply.schedule(1500);
            return;
        }
        if (dfy.eql(name, "stats")) {
            var buffer: [160]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "累计刷了 {d} 条，记录了 {d} 个视频。", .{ counter, seen.len }) catch "统计好了。";
            try reply.say(line);
            reply.status(line, null, counter);
            return;
        }
        // "next" falls through and behaves like a tick.
    }

    if (bridge.len == 0) {
        reply.status("等待配置桥接地址", null, counter);
        reply.schedule(60_000);
        return;
    }

    if (dfy.eql(kind, "effect-result")) {
        const results = dfy.getList(ctx.event, "effects");
        const feed = findEffect(results, "feed") orelse {
            reply.status("等待桥接响应", null, counter);
            reply.schedule(clampSeconds(interval));
            return;
        };
        const ok = dfy.getBool(feed, "ok") orelse false;
        if (!ok) {
            const reason = dfy.getStr(feed, "error") orelse "桥接没有响应";
            var buffer: [200]u8 = undefined;
            const line = std.fmt.bufPrint(&buffer, "刷不动了：{s}", .{reason}) catch "刷不动了。";
            reply.status(line, null, counter);
            try reply.stateInt("available", 0);
            reply.schedule(clampSeconds(interval * 3));
            return;
        }
        const body = dfy.getStr(feed, "body") orelse "";
        const parsed = std.json.parseFromSlice(dfy.Value, ctx.alloc, body, .{}) catch {
            reply.status("桥接返回的内容不是 JSON", null, counter);
            reply.schedule(clampSeconds(interval));
            return;
        };
        defer parsed.deinit();

        const items = dfy.getList(parsed.value, "items");
        var best: ?dfy.Value = null;
        var best_score: f64 = -1e18;
        for (items) |item| {
            if (item != .object) continue;
            const id = dfy.getStr(item, "id") orelse continue;
            if (id.len == 0) continue;
            if (containsId(seen, id)) continue;
            const title = dfy.getStr(item, "title") orelse "";
            const author = dfy.getStr(item, "author") orelse "";
            var score = hotScore(item);
            if (boost) score += interestScore(interests, title, author);
            if (score > best_score) {
                best_score = score;
                best = item;
            }
        }

        const picked = best orelse {
            try reply.stateInt("seenCount", 0);
            reply.status("这波推荐都刷过了，等一会儿再来。", null, counter);
            reply.schedule(clampSeconds(interval * 3));
            return;
        };

        const item_id = dfy.getStr(picked, "id") orelse "";
        const title = dfy.getStr(picked, "title") orelse "（无标题）";
        const author = dfy.getStr(picked, "author") orelse "未知作者";
        const url = dfy.getStr(picked, "url") orelse "";

        var line_buffer: [460]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "刷到：{s} @{s}", .{ title, author }) catch "刷到一个视频。";
        try reply.say(line);
        if (@rem(counter, 3) == 2) try reply.play("吃Token");

        // Newest first, capped, and never storing the same id twice.
        const writer = reply.stateWriter();
        try writer.key("seen");
        try writer.beginArray();
        try writer.str(item_id);
        var kept: usize = 1;
        for (seen) |entry| {
            if (!isString(entry)) continue;
            if (dfy.eql(entry.string, item_id)) continue;
            if (kept >= seen_limit) break;
            try writer.str(entry.string);
            kept += 1;
        }
        try writer.endArray();

        try reply.stateInt("counter", counter + 1);
        try reply.stateStr("lastTitle", title);
        if (url.len <= 300) try reply.stateStr("lastUrl", url);
        try reply.stateInt("lastFetchAt", ctx.now);
        try reply.stateInt("available", @intCast(items.len));

        reply.status(line, null, counter + 1);
        return;
    }

    // tick / next: ask the bridge for the current feed.
    var url_buffer: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}/feed?limit={d}", .{ bridge, feed_limit }) catch {
        reply.status("桥接地址过长", null, counter);
        reply.schedule(60_000);
        return;
    };
    try reply.httpGet("feed", url);
    reply.status("正在从桥接拉取推荐…", null, counter);
    reply.schedule(clampSeconds(interval));
}

comptime {
    dfy.install(onEvent);
}
