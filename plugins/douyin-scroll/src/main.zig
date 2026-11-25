//! 刷抖音 · Douyin scroller
//!
//! The plug-in never touches the network itself. It asks the host for the
//! bridge feed, ranks what comes back against the user's interests, lets the
//! pet say one line, and asks to be woken up later. Everything else - the
//! request, the pet reaction, the persisted state - belongs to the host.
//!
//! ## 强制守门（这里写死，用户关不掉）
//!
//! 推荐流、评论、回复全部是陌生人写的文本。它们可以进入桌宠嘴里，但**永远
//! 不能变成动作**：不能决定写什么、写给谁、写不写。写请求只有一条合法路径：
//!
//!   `command`（或明确开启的自动收藏） → `writeGate` 通过 → 用户手写原文。
//!
//! 守门规则见 `WriteContext`：开关、目标来源、文本来源、冷却、每日上限。
//! 只要有一项不满足就拒绝，并且拒绝理由会念给用户听，不做静默降级。
//!
//! ## 提示词注入的两道防线
//!
//! 1. 结构上：写请求的目标 id 必须同时「格式合法」且「在最近一次抓取的快照里」
//!    出现过——`videoIds` / `commentIds` / `replyIds` 就是来源证明，桥接文本
//!    伪造不出一个写目标。发送文本只能来自设置项里用户自己敲的原文，逐字发送，
//!    绝不拼接 feed 内容。`browse` / `pick` / `comments` 这些选择命令只认编号，
//!    不认内容。
//! 2. 文本上：所有来自桥接的文本在交给桌宠之前都过 `sanitize` —— 去掉控制
//!    字符、零宽字符、双向覆盖、Unicode 标签字符，空白压成单空格并按字符数
//!    截断；再过 `looksLikeInjection` 打「疑似注入」标记。带标记的内容只会被
//!    引述展示，永远不能触发自动收藏或自动回复。
const std = @import("std");
const dfy = @import("dfy.zig");

/// How many item ids we remember so we do not repeat ourselves.
const seen_limit: usize = 40;
const feed_limit: usize = 20;

/// 每次抓取留在 state 里的快照上限。快照有双重身份：既是 `browse` / `pick`
/// 的候选来源，也是写操作的来源证明——不在快照里的 id 不能成为写目标。
/// 这些数字写死，避免 state 被一条超长 feed 撑爆。
const Snapshot = struct {
    const videos: usize = 6;
    const comments: usize = 3;
    const replies: usize = 2;
    /// 每次 `browse` 念几条。
    const page: usize = 3;
    /// 一条评论原文超过这个字节数就不进快照：念不出来，也最容易藏东西。
    const max_comment_bytes: usize = 300;
};

const SayBuilder = struct {
    buffer: [1_600]u8 = undefined,
    used: usize = 0,
    chars: usize = 0,

    fn append(self: *SayBuilder, text: []const u8) void {
        if (text.len == 0) return;
        var view = std.unicode.Utf8View.init(text) catch return;
        var iterator = view.iterator();
        var count: usize = 0;
        while (iterator.nextCodepoint() != null) count += 1;
        if (self.chars + count > 400 or self.used + text.len > self.buffer.len) return;
        @memcpy(self.buffer[self.used .. self.used + text.len], text);
        self.used += text.len;
        self.chars += count;
    }

    fn slice(self: *const SayBuilder) []const u8 {
        return self.buffer[0..self.used];
    }
};

/// Hard limits of the write guard. None of these is read from settings.
const Guard = struct {
    /// Target ids: the bridge's own identifier alphabet, nothing else.
    const max_id: usize = 64;
    /// 用户手写的评论文本上限（字符）。
    const max_user_text: usize = 200;
    /// 桥接文本进入桌宠嘴里之前的截断（字符）。
    const max_feed_text: usize = 60;
    const max_author: usize = 24;
    const max_url: usize = 300;
    const max_error: usize = 60;
    const daily_min: i64 = 1;
    const daily_max: i64 = 50;
    const cooldown_min_s: i64 = 10;
    const cooldown_max_s: i64 = 600;
    /// 自动收藏只认「命中兴趣」的视频，热度高不算。
    const auto_interest_score: f64 = 2_000;
};

fn isString(item: dfy.Value) bool {
    return item == .string;
}

fn clampInt(raw: i64, low: i64, high: i64) i64 {
    return if (raw < low) low else if (raw > high) high else raw;
}

fn containsId(seen: []const dfy.Value, id: []const u8) bool {
    for (seen) |entry| {
        if (!isString(entry)) continue;
        if (dfy.eql(entry.string, id)) return true;
    }
    return false;
}

fn stateContainsId(state: dfy.Value, key: []const u8, id: []const u8) bool {
    return containsId(dfy.getList(state, key), id);
}

fn containsIgnoreCase(text: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > text.len) return false;
    var start: usize = 0;
    while (start + needle.len <= text.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |expected, offset| {
            if (std.ascii.toLower(text[start + offset]) != std.ascii.toLower(expected)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn looksLikeInjection(text: []const u8) bool {
    var view = std.unicode.Utf8View.init(text) catch return true;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |cp| {
        if (isInvisible(cp)) return true;
    }
    const markers = [_][]const u8{
        "忽略之前", "忽略以上", "忽略前面", "忽略上述", "无视之前", "系统提示", "系统指令",
        "新的指令", "你现在是", "覆盖之前", "泄露提示", "ignore previous", "disregard",
        "forget previous", "system prompt", "assistant:", "system:", "developer:",
        "javascript:", "data:text/html", "http://", "https://", "<script", "tool_call",
        "function_call", "```", "post /", "get /",
    };
    for (markers) |marker| {
        if (containsIgnoreCase(text, marker)) return true;
    }
    return false;
}

fn findById(items: []const dfy.Value, id: []const u8) ?dfy.Value {
    for (items) |item| {
        if (item != .object) continue;
        const candidate = dfy.getStr(item, "id") orelse continue;
        if (dfy.eql(candidate, id)) return item;
    }
    return null;
}

fn snapshotItems(state: dfy.Value) []const dfy.Value {
    return dfy.getList(state, "feed");
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

// ---------------------------------------------------------------------------
// 文本清洗：桥接内容进入桌宠嘴里的唯一通道
// ---------------------------------------------------------------------------

/// Characters that carry no visible glyph but can carry meaning: C0/C1
/// controls, zero-width joiners, bidi overrides (the classic "hide the real
/// sentence" trick) and Unicode tag characters (a whole ASCII payload can ride
/// in them invisibly).
fn isInvisible(cp: u21) bool {
    return switch (cp) {
        0x00...0x1F, 0x7F...0x9F => true,
        0x200B...0x200F => true,
        0x202A...0x202E => true,
        0x2060...0x206F => true,
        0xFEFF => true,
        0xFFF9...0xFFFB => true,
        0xE0000...0xE007F => true,
        else => false,
    };
}

fn isBlank(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r' or cp == 0x3000 or cp == 0x00A0;
}

/// Normalise one piece of bridge text: drop invisible characters, fold any run
/// of whitespace into a single space, trim the ends, and cut at `max_chars`
/// (counted in code points, so a multi-byte character is never split).
///
/// `dest` must hold at least `max_chars * 4` bytes. Returns the slice to use -
/// an empty slice means "nothing safe to show".
fn sanitize(dest: []u8, text: []const u8, max_chars: usize) []const u8 {
    if (text.len == 0 or max_chars == 0) return dest[0..0];
    var view = std.unicode.Utf8View.init(text) catch return dest[0..0];
    var it = view.iterator();
    var out: usize = 0;
    var chars: usize = 0;
    var pending_space = false;
    while (it.nextCodepoint()) |cp| {
        if (isInvisible(cp)) continue;
        if (isBlank(cp)) {
            if (out > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (chars + 1 >= max_chars) break;
            if (out + 1 > dest.len) break;
            dest[out] = ' ';
            out += 1;
            chars += 1;
            pending_space = false;
        }
        if (chars >= max_chars) break;
        var encoded: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(cp, &encoded) catch continue;
        const size: usize = written;
        if (out + size > dest.len) break;
        @memcpy(dest[out .. out + size], encoded[0..size]);
        out += size;
        chars += 1;
    }
    return dest[0..out];
}

/// A target id is usable only if it looks like an id and nothing else: no
/// spaces, no punctuation, no query syntax. This is what keeps a hostile feed
/// from steering a write to another endpoint or another account.
fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > Guard.max_id) return false;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Escape one already-sanitised string into a JSON string body. Sanitising
/// first means there are no control characters left to escape, so only the two
/// structural characters need work - and a quote in the user's own text can
/// never break out of the JSON document.
fn appendJsonString(dest: []u8, at: *usize, text: []const u8) bool {
    for (text) |c| {
        const needed: usize = if (c == '"' or c == '\\') 2 else 1;
        if (at.* + needed > dest.len) return false;
        if (needed == 2) {
            dest[at.*] = '\\';
            at.* += 1;
        }
        dest[at.*] = c;
        at.* += 1;
    }
    return true;
}

/// Only a plain `https://` URL with no spaces or control characters is worth
/// remembering. Anything else - a relative path, `javascript:`, `data:` - gets
/// dropped instead of being handed on to the host.
fn isHttpsUrl(url: []const u8) bool {
    if (url.len == 0 or url.len > Guard.max_url) return false;
    if (!std.mem.startsWith(u8, url, "https://")) return false;
    for (url) |c| {
        if (c <= 0x20 or c == 0x7F) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// 写操作：种类与强制守门
// ---------------------------------------------------------------------------

const WriteKind = enum {
    like,
    favorite,
    comment,
    reply,
    comment_like,

    fn path(self: WriteKind) []const u8 {
        return switch (self) {
            .like => "/like",
            .favorite => "/favorite",
            .comment => "/comment",
            .reply => "/reply",
            .comment_like => "/comment-like",
        };
    }

    fn effectId(self: WriteKind) []const u8 {
        return switch (self) {
            .like => "write:like",
            .favorite => "write:favorite",
            .comment => "write:comment",
            .reply => "write:reply",
            .comment_like => "write:comment-like",
        };
    }

    /// 写完之后告诉用户「什么好了」。
    fn doneLabel(self: WriteKind) []const u8 {
        return switch (self) {
            .like => "点赞",
            .favorite => "收藏",
            .comment => "评论",
            .reply => "回复",
            .comment_like => "评论点赞",
        };
    }

    /// 发送文本是用户手写的，还是本次为空。
    fn needsText(self: WriteKind) bool {
        return self == .comment or self == .reply;
    }

    /// `reply` 针对一条评论或回复，其余针对视频本身。
    fn targetKey(self: WriteKind) []const u8 {
        return if (self == .reply) "target" else "id";
    }
};

fn parseWriteKind(name: []const u8) ?WriteKind {
    if (dfy.eql(name, "like")) return .like;
    if (dfy.eql(name, "favorite")) return .favorite;
    if (dfy.eql(name, "comment")) return .comment;
    if (dfy.eql(name, "reply")) return .reply;
    if (dfy.eql(name, "comment-like")) return .comment_like;
    return null;
}

fn kindFromEffectId(id: []const u8) ?WriteKind {
    if (dfy.eql(id, "write:like")) return .like;
    if (dfy.eql(id, "write:favorite")) return .favorite;
    if (dfy.eql(id, "write:comment")) return .comment;
    if (dfy.eql(id, "write:reply")) return .reply;
    if (dfy.eql(id, "write:comment-like")) return .comment_like;
    return null;
}

/// Everything the guard is allowed to look at. Every field is either a fixed
/// setting, a value the host persisted from the last fetch, or the clock - so
/// the decision is deterministic and testable without a network.
const WriteContext = struct {
    allow: bool,
    /// 目标 id 是否格式合法（`validId`）。
    target_valid: bool,
    /// 目标 id 是否在最近一次抓取的 `videoIds` / `commentIds` / `replyIds` 里。
    target_proven: bool,
    target_len: usize,
    needs_text: bool,
    text_len: usize,
    cooldown_ms: i64,
    daily_limit: i64,
    now: i64,
    last_write_at: i64,
    writes_today: i64,
};

/// The guard. Returns null when the write may go out, otherwise the reason it
/// must not - which is always shown to the user, never swallowed.
fn writeRefusal(ctx: WriteContext) ?[]const u8 {
    if (!ctx.allow) return "写操作总开关是关的，先设置里勾「允许写入」";
    if (ctx.target_len == 0) return "还没有选中目标，先 browse / pick 选一条视频";
    if (!ctx.target_valid) return "选中的目标格式不对，拒绝写入";
    if (!ctx.target_proven) return "选中的目标不在最近一次抓取里，重新刷一次再选";
    if (ctx.needs_text and ctx.text_len == 0) return "设置里还没写要发送的原文";
    if (ctx.writes_today >= ctx.daily_limit) return "今天的写入次数用完了";
    if (ctx.last_write_at > 0 and ctx.now - ctx.last_write_at < ctx.cooldown_ms) return "写入冷却中，晚点再试";
    return null;
}

/// One UTC day bucket, so the daily quota cannot be reset by moving the clock
/// back a few hours.
fn dayOf(now: i64) i64 {
    return @divFloor(now, 86_400_000);
}

fn writesToday(state: dfy.Value, now: i64) i64 {
    const day = dayOf(now);
    const saved_day = dfy.getInt(state, "writeDay") orelse -1;
    if (saved_day != day) return 0;
    return dfy.getInt(state, "writesToday") orelse 0;
}

// ---------------------------------------------------------------------------
// 快照：本次抓取留下的候选与来源证明
// ---------------------------------------------------------------------------

fn writeSnapshotReply(writer: *dfy.Json, item: dfy.Value) !void {
    const raw_text = dfy.getStr(item, "text") orelse "";
    const raw_author = dfy.getStr(item, "author") orelse "";
    var text_buffer: [Guard.max_feed_text * 4]u8 = undefined;
    var author_buffer: [Guard.max_author * 4]u8 = undefined;
    try writer.beginObject();
    try writer.key("id");
    try writer.str(dfy.getStr(item, "id") orelse "");
    try writer.key("author");
    try writer.str(sanitize(&author_buffer, raw_author, Guard.max_author));
    try writer.key("text");
    try writer.str(sanitize(&text_buffer, raw_text, Guard.max_feed_text));
    try writer.key("suspect");
    try writer.boolean(looksLikeInjection(raw_text) or looksLikeInjection(raw_author));
    try writer.endObject();
}

fn writeSnapshotComment(writer: *dfy.Json, item: dfy.Value) !void {
    const raw_text = dfy.getStr(item, "text") orelse "";
    const raw_author = dfy.getStr(item, "author") orelse "";
    var text_buffer: [Guard.max_feed_text * 4]u8 = undefined;
    var author_buffer: [Guard.max_author * 4]u8 = undefined;
    try writer.beginObject();
    try writer.key("id");
    try writer.str(dfy.getStr(item, "id") orelse "");
    try writer.key("author");
    try writer.str(sanitize(&author_buffer, raw_author, Guard.max_author));
    try writer.key("text");
    try writer.str(sanitize(&text_buffer, raw_text, Guard.max_feed_text));
    try writer.key("suspect");
    try writer.boolean(looksLikeInjection(raw_text) or looksLikeInjection(raw_author));
    try writer.key("replies");
    try writer.beginArray();
    var kept: usize = 0;
    for (dfy.getList(item, "replies")) |child| {
        if (child != .object) continue;
        if (!validId(dfy.getStr(child, "id") orelse "")) continue;
        if (kept >= Snapshot.replies) break;
        const raw_child_text = dfy.getStr(child, "text") orelse "";
        if (raw_child_text.len == 0 or raw_child_text.len > Snapshot.max_comment_bytes) continue;
        try writeSnapshotReply(writer, child);
        kept += 1;
    }
    try writer.endArray();
    try writer.endObject();
}

/// 一条视频进快照：只保留可用 id、可念文本与一个「疑似注入」标记。
/// 标题/作者不可疑不代表评论区可信，所以标记是逐条算的。
fn writeSnapshotItem(writer: *dfy.Json, item: dfy.Value) !void {
    const raw_title = dfy.getStr(item, "title") orelse "";
    const raw_author = dfy.getStr(item, "author") orelse "";
    var title_buffer: [Guard.max_feed_text * 4]u8 = undefined;
    var author_buffer: [Guard.max_author * 4]u8 = undefined;
    try writer.beginObject();
    try writer.key("id");
    try writer.str(dfy.getStr(item, "id") orelse "");
    try writer.key("title");
    try writer.str(sanitize(&title_buffer, raw_title, Guard.max_feed_text));
    try writer.key("author");
    try writer.str(sanitize(&author_buffer, raw_author, Guard.max_author));
    if (dfy.getStr(item, "url")) |url| {
        if (isHttpsUrl(url)) {
            try writer.key("url");
            try writer.str(url);
        }
    }
    try writer.key("suspect");
    try writer.boolean(looksLikeInjection(raw_title) or looksLikeInjection(raw_author));
    try writer.key("comments");
    try writer.beginArray();
    var kept: usize = 0;
    for (dfy.getList(item, "comments")) |comment| {
        if (comment != .object) continue;
        if (!validId(dfy.getStr(comment, "id") orelse "")) continue;
        if (kept >= Snapshot.comments) break;
        const raw_text = dfy.getStr(comment, "text") orelse "";
        if (raw_text.len == 0 or raw_text.len > Snapshot.max_comment_bytes) continue;
        try writeSnapshotComment(writer, comment);
        kept += 1;
    }
    try writer.endArray();
    try writer.endObject();
}

/// 把解析出来的推荐流压成快照并写进 state。快照同时是 `browse` / `pick` 的
/// 候选池与写操作的来源证明：写请求只认这里出现过的 id。
fn writeSnapshot(writer: *dfy.Json, items: []const dfy.Value) !void {
    try writer.key("videoIds");
    try writer.beginArray();
    var kept_video_ids: usize = 0;
    for (items) |item| {
        if (kept_video_ids >= Snapshot.videos) break;
        if (item != .object) continue;
        const id = dfy.getStr(item, "id") orelse continue;
        if (!validId(id)) continue;
        try writer.str(id);
        kept_video_ids += 1;
    }
    try writer.endArray();

    try writer.key("commentIds");
    try writer.beginArray();
    var comment_videos: usize = 0;
    for (items) |item| {
        if (comment_videos >= Snapshot.videos) break;
        if (item != .object) continue;
        if (!validId(dfy.getStr(item, "id") orelse "")) continue;
        comment_videos += 1;
        var kept_comments: usize = 0;
        for (dfy.getList(item, "comments")) |comment| {
            if (kept_comments >= Snapshot.comments) break;
            if (comment != .object) continue;
            const id = dfy.getStr(comment, "id") orelse continue;
            if (!validId(id)) continue;
            const raw_text = dfy.getStr(comment, "text") orelse "";
            if (raw_text.len == 0 or raw_text.len > Snapshot.max_comment_bytes) continue;
            try writer.str(id);
            kept_comments += 1;
        }
    }
    try writer.endArray();

    try writer.key("replyIds");
    try writer.beginArray();
    var reply_videos: usize = 0;
    for (items) |item| {
        if (reply_videos >= Snapshot.videos) break;
        if (item != .object) continue;
        if (!validId(dfy.getStr(item, "id") orelse "")) continue;
        reply_videos += 1;
        var reply_comments: usize = 0;
        for (dfy.getList(item, "comments")) |comment| {
            if (reply_comments >= Snapshot.comments) break;
            if (comment != .object) continue;
            if (!validId(dfy.getStr(comment, "id") orelse "")) continue;
            const raw_text = dfy.getStr(comment, "text") orelse "";
            if (raw_text.len == 0 or raw_text.len > Snapshot.max_comment_bytes) continue;
            reply_comments += 1;
            var kept_replies: usize = 0;
            for (dfy.getList(comment, "replies")) |child| {
                if (kept_replies >= Snapshot.replies) break;
                if (child != .object) continue;
                const id = dfy.getStr(child, "id") orelse continue;
                if (!validId(id)) continue;
                const raw_child_text = dfy.getStr(child, "text") orelse "";
                if (raw_child_text.len == 0 or raw_child_text.len > Snapshot.max_comment_bytes) continue;
                try writer.str(id);
                kept_replies += 1;
            }
        }
    }
    try writer.endArray();

    try writer.key("feed");
    try writer.beginArray();
    var written: usize = 0;
    for (items) |item| {
        if (written >= Snapshot.videos) break;
        if (item != .object) continue;
        if (!validId(dfy.getStr(item, "id") orelse "")) continue;
        try writeSnapshotItem(writer, item);
        written += 1;
    }
    try writer.endArray();
}

/// 本次抓取里，前 `Snapshot.videos` 个合法 id 就是快照的 videoIds。
fn provenVideo(items: []const dfy.Value, id: []const u8) bool {
    var counted: usize = 0;
    for (items) |item| {
        if (counted >= Snapshot.videos) break;
        if (item != .object) continue;
        const candidate = dfy.getStr(item, "id") orelse continue;
        if (!validId(candidate)) continue;
        counted += 1;
        if (dfy.eql(candidate, id)) return true;
    }
    return false;
}

/// 快照里的 commentIds 来自前 `Snapshot.videos` 条视频、每条前
/// `Snapshot.comments` 条可念评论——这里用同一套过滤重算一遍。
fn provenComment(items: []const dfy.Value, id: []const u8) bool {
    var videos: usize = 0;
    for (items) |item| {
        if (videos >= Snapshot.videos) break;
        if (item != .object) continue;
        if (!validId(dfy.getStr(item, "id") orelse "")) continue;
        videos += 1;
        var kept: usize = 0;
        for (dfy.getList(item, "comments")) |comment| {
            if (kept >= Snapshot.comments) break;
            if (comment != .object) continue;
            const candidate = dfy.getStr(comment, "id") orelse continue;
            if (!validId(candidate)) continue;
            const text = dfy.getStr(comment, "text") orelse "";
            if (text.len == 0 or text.len > Snapshot.max_comment_bytes) continue;
            kept += 1;
            if (dfy.eql(candidate, id)) return true;
        }
    }
    return false;
}

fn provenReply(items: []const dfy.Value, id: []const u8) bool {
    var videos: usize = 0;
    for (items) |item| {
        if (videos >= Snapshot.videos) break;
        if (item != .object) continue;
        if (!validId(dfy.getStr(item, "id") orelse "")) continue;
        videos += 1;
        var comments: usize = 0;
        for (dfy.getList(item, "comments")) |comment| {
            if (comments >= Snapshot.comments) break;
            if (comment != .object) continue;
            if (!validId(dfy.getStr(comment, "id") orelse "")) continue;
            const text = dfy.getStr(comment, "text") orelse "";
            if (text.len == 0 or text.len > Snapshot.max_comment_bytes) continue;
            comments += 1;
            var kept: usize = 0;
            for (dfy.getList(comment, "replies")) |child| {
                if (kept >= Snapshot.replies) break;
                if (child != .object) continue;
                const candidate = dfy.getStr(child, "id") orelse continue;
                if (!validId(candidate)) continue;
                const child_text = dfy.getStr(child, "text") orelse "";
                if (child_text.len == 0 or child_text.len > Snapshot.max_comment_bytes) continue;
                kept += 1;
                if (dfy.eql(candidate, id)) return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// 选择：browse / pick / comments / pick-comment / pick-reply
// ---------------------------------------------------------------------------

fn writeSuspectNote(builder: *SayBuilder, suspect: bool) void {
    if (suspect) builder.append("（疑似注入，仅展示）");
}

/// 游标从 -1 起步，每次 +1 取模：第一次 `pick` 落在第 1 条，重复调用就是
/// 「下一条」。带 `args.index`（1 起）则直接定位，越界返回 null 而不是绕回，
/// 免得一次手滑点到不相干的东西上。
fn advanceCursor(state: dfy.Value, key: []const u8, len: usize, index_arg: ?i64) ?usize {
    if (len == 0) return null;
    if (index_arg) |raw| {
        const bound: i64 = @intCast(len);
        if (raw < 1 or raw > bound) return null;
        return @intCast(raw - 1);
    }
    const previous = dfy.getInt(state, key) orelse -1;
    const bound: i64 = @intCast(len);
    const next: i64 = if (previous < 0 or previous >= bound) 0 else previous + 1;
    return @intCast(next);
}

fn argIndex(event: dfy.Value) ?i64 {
    return dfy.getInt(dfy.get(event, "args") orelse .null, "index");
}

fn clearReplySelection(reply: *dfy.Reply) !void {
    try reply.stateRemove("lastReplyId");
    try reply.stateRemove("lastReplyAuthor");
    try reply.stateRemove("lastReplyText");
    try reply.stateRemove("lastReplySuspect");
    try reply.stateRemove("replyIndex");
}

fn clearCommentSelection(reply: *dfy.Reply) !void {
    try reply.stateRemove("lastCommentId");
    try reply.stateRemove("lastCommentAuthor");
    try reply.stateRemove("lastCommentText");
    try reply.stateRemove("lastCommentSuspect");
    try reply.stateRemove("commentIndex");
    try clearReplySelection(reply);
}

fn commandBrowse(ctx: *dfy.Context, counter: i64, index_arg: ?i64) !void {
    const reply = ctx.reply;
    const videos = snapshotItems(ctx.state);
    if (videos.len == 0) {
        try reply.say("还没有推荐快照，先让插件刷一次。");
        reply.status("没有可浏览的推荐", null, counter);
        return;
    }
    const pages = (videos.len + Snapshot.page - 1) / Snapshot.page;
    var page: usize = 0;
    if (index_arg) |raw| {
        const bound: i64 = @intCast(videos.len);
        if (raw < 1 or raw > bound) {
            try reply.say("编号越界，先 browse 看一下。");
            reply.status("编号越界", null, counter);
            return;
        }
        const per_page: i64 = @intCast(Snapshot.page);
        page = @intCast(@divTrunc(raw - 1, per_page));
    } else {
        const previous = dfy.getInt(ctx.state, "browsePage") orelse -1;
        const bound: i64 = @intCast(pages);
        const next: i64 = if (previous < 0 or previous + 1 >= bound) 0 else previous + 1;
        page = @intCast(next);
    }
    const start = page * Snapshot.page;
    const stop = @min(start + Snapshot.page, videos.len);

    var builder = SayBuilder{};
    var head_buffer: [64]u8 = undefined;
    if (std.fmt.bufPrint(&head_buffer, "推荐流 {d}-{d}/{d}：", .{ start + 1, stop, videos.len })) |head| {
        builder.append(head);
    } else |_| {}
    var index = start;
    while (index < stop) : (index += 1) {
        const item = videos[index];
        const title = dfy.getStr(item, "title") orelse "";
        const author = dfy.getStr(item, "author") orelse "";
        var entry_buffer: [240]u8 = undefined;
        const entry = std.fmt.bufPrint(
            &entry_buffer,
            "{d}.「{s}」@{s}",
            .{
                index + 1,
                if (title.len == 0) @as([]const u8, "（无标题）") else title,
                if (author.len == 0) @as([]const u8, "未知作者") else author,
            },
        ) catch continue;
        builder.append(entry);
        if (dfy.getBool(item, "suspect") orelse false) builder.append("（疑似注入，仅展示）");
        if (index + 1 < stop) builder.append("；");
    }
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, counter);
    try reply.stateInt("browsePage", @intCast(page));
}

fn commandComments(ctx: *dfy.Context, counter: i64) !void {
    const reply = ctx.reply;
    const video = selectedVideo(ctx.state) orelse {
        try reply.say("还没有选中视频，先 pick 一条。");
        reply.status("没有选中的视频", null, counter);
        return;
    };
    const comments = dfy.getList(video, "comments");
    if (comments.len == 0) {
        try reply.say("这条视频没有能念的评论。");
        reply.status("没有评论", null, counter);
        try clearCommentSelection(reply);
        return;
    }
    var builder = SayBuilder{};
    builder.append("评论区：");
    var index: usize = 0;
    while (index < comments.len) : (index += 1) {
        const item = comments[index];
        const text = dfy.getStr(item, "text") orelse "";
        const author = dfy.getStr(item, "author") orelse "";
        var entry_buffer: [280]u8 = undefined;
        const entry = std.fmt.bufPrint(
            &entry_buffer,
            "{d}.「{s}」@{s}",
            .{
                index + 1,
                if (text.len == 0) @as([]const u8, "（空）") else text,
                if (author.len == 0) @as([]const u8, "未知作者") else author,
            },
        ) catch continue;
        builder.append(entry);
        if (dfy.getBool(item, "suspect") orelse false) builder.append("（疑似注入，仅展示）");
        if (index + 1 < comments.len) builder.append("；");
    }
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, counter);
    try clearCommentSelection(reply);
}

/// 命令入口：只认命令名与编号。命令的 `args` 里除了 1 起的 `index` 之外
/// 没有别的东西可被喂进来。
fn handleCommand(
    ctx: *dfy.Context,
    name: []const u8,
    counter: i64,
    bridge: []const u8,
    allow_writes: bool,
    daily_limit: i64,
    cooldown_ms: i64,
    user_comment: []const u8,
    user_reply: []const u8,
) !bool {
    const reply = ctx.reply;
    if (dfy.eql(name, "reset")) {
        // The reply merges over persisted state, so deleting means naming
        // the key without writing a value.
        try reply.stateInt("counter", 0);
        try reply.stateRemove("seen");
        try reply.stateRemove("seenCount");
        try reply.stateRemove("lastTitle");
        try reply.stateRemove("lastUrl");
        try reply.stateRemove("lastFetchAt");
        try reply.stateRemove("available");
        try reply.stateRemove("lastId");
        try reply.stateRemove("lastAuthor");
        try reply.stateRemove("lastSuspect");
        try reply.stateRemove("feed");
        try reply.stateRemove("videoIds");
        try reply.stateRemove("commentIds");
        try reply.stateRemove("replyIds");
        try reply.stateRemove("pickIndex");
        try reply.stateRemove("browsePage");
        try clearCommentSelection(reply);
        try reply.stateRemove("pendingWrite");
        try reply.stateRemove("lastWriteAt");
        try reply.stateRemove("writesToday");
        try reply.stateRemove("writeDay");
        try reply.say("计数清零，重新开始刷。");
        reply.status("已重置刷抖音计数", null, 0);
        reply.schedule(1500);
        return true;
    }
    if (dfy.eql(name, "stats")) {
        var buffer: [200]u8 = undefined;
        const today = writesToday(ctx.state, ctx.now);
        const snapshot_len = snapshotItems(ctx.state).len;
        const line = std.fmt.bufPrint(
            &buffer,
            "累计刷了 {d} 条，记了 {d} 个视频，快照里有 {d} 条，今天写入 {d} 次。",
            .{ counter, dfy.getList(ctx.state, "seen").len, snapshot_len, today },
        ) catch "统计好了。";
        try reply.say(line);
        reply.status(line, null, counter);
        return true;
    }
    if (dfy.eql(name, "browse")) {
        try commandBrowse(ctx, counter, argIndex(ctx.event));
        return true;
    }
    if (dfy.eql(name, "pick")) {
        const videos = snapshotItems(ctx.state);
        if (videos.len == 0) {
            try reply.say("还没有推荐快照，先让插件刷一次。");
            reply.status("没有可选的推荐", null, counter);
            return true;
        }
        if (advanceCursor(ctx.state, "pickIndex", videos.len, argIndex(ctx.event))) |index| {
            try selectVideo(ctx, index);
        } else {
            try reply.say("编号越界，先 browse 看一下。");
            reply.status("编号越界", null, counter);
        }
        return true;
    }
    if (dfy.eql(name, "comments")) {
        try commandComments(ctx, counter);
        return true;
    }
    if (dfy.eql(name, "pick-comment")) {
        const comments = selectedComments(ctx.state);
        if (comments.len == 0) {
            try reply.say("还没有可选的评论，先 pick 一条视频再 comments。");
            reply.status("没有可选的评论", null, counter);
            return true;
        }
        if (advanceCursor(ctx.state, "commentIndex", comments.len, argIndex(ctx.event))) |index| {
            try selectComment(ctx, index, comments);
        } else {
            try reply.say("评论编号超出范围，先 comments 看一下。");
            reply.status("评论编号越界", null, counter);
        }
        return true;
    }
    if (dfy.eql(name, "pick-reply")) {
        const comment = selectedComment(ctx.state) orelse {
            try reply.say("还没有选中评论，先 pick-comment 一条。");
            reply.status("没有选中的评论", null, counter);
            return true;
        };
        const replies = dfy.getList(comment, "replies");
        if (replies.len == 0) {
            try reply.say("这条评论没有回复可选。");
            reply.status("没有回复", null, counter);
            return true;
        }
        if (advanceCursor(ctx.state, "replyIndex", replies.len, argIndex(ctx.event))) |index| {
            try selectReply(ctx, index, replies);
        } else {
            try reply.say("回复编号超出范围。");
            reply.status("回复编号越界", null, counter);
        }
        return true;
    }
    if (parseWriteKind(name)) |write_kind| {
        const text = switch (write_kind) {
            .comment => user_comment,
            .reply => user_reply,
            else => "",
        };
        try requestWrite(
            ctx,
            write_kind,
            bridge,
            counter,
            allow_writes,
            daily_limit,
            cooldown_ms,
            text,
        );
        return true;
    }
    return false;
}

fn selectVideo(ctx: *dfy.Context, index: usize) !void {
    const reply = ctx.reply;
    const videos = snapshotItems(ctx.state);
    const item = videos[index];
    const id = dfy.getStr(item, "id") orelse "";
    const title = dfy.getStr(item, "title") orelse "";
    const author = dfy.getStr(item, "author") orelse "";
    const suspect = dfy.getBool(item, "suspect") orelse false;

    var builder = SayBuilder{};
    var head_buffer: [64]u8 = undefined;
    if (std.fmt.bufPrint(&head_buffer, "选中第 {d}/{d} 条：", .{ index + 1, videos.len })) |head| {
        builder.append(head);
    } else |_| {}
    builder.append("「");
    builder.append(if (title.len == 0) "（无标题）" else title);
    builder.append("」@");
    builder.append(if (author.len == 0) "未知作者" else author);
    writeSuspectNote(&builder, suspect);
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, dfy.getInt(ctx.state, "counter") orelse 0);

    try reply.stateStr("lastId", id);
    if (title.len > 0) try reply.stateStr("lastTitle", title);
    if (author.len > 0) try reply.stateStr("lastAuthor", author);
    try reply.stateBool("lastSuspect", suspect);
    if (dfy.getStr(item, "url")) |url| {
        if (isHttpsUrl(url)) try reply.stateStr("lastUrl", url);
    }
    try reply.stateInt("pickIndex", @intCast(index));
    try clearCommentSelection(reply);
}

fn selectedVideo(state: dfy.Value) ?dfy.Value {
    const id = dfy.getStr(state, "lastId") orelse "";
    if (id.len == 0) return null;
    return findById(snapshotItems(state), id);
}

fn selectedComments(state: dfy.Value) []const dfy.Value {
    const video = selectedVideo(state) orelse return &[_]dfy.Value{};
    return dfy.getList(video, "comments");
}

fn selectedComment(state: dfy.Value) ?dfy.Value {
    const id = dfy.getStr(state, "lastCommentId") orelse "";
    if (id.len == 0) return null;
    return findById(selectedComments(state), id);
}

fn selectComment(ctx: *dfy.Context, index: usize, comments: []const dfy.Value) !void {
    const reply = ctx.reply;
    const item = comments[index];
    const id = dfy.getStr(item, "id") orelse "";
    const author = dfy.getStr(item, "author") orelse "";
    const text = dfy.getStr(item, "text") orelse "";
    const suspect = dfy.getBool(item, "suspect") orelse false;

    var builder = SayBuilder{};
    var head_buffer: [64]u8 = undefined;
    if (std.fmt.bufPrint(&head_buffer, "选中第 {d}/{d} 条评论：", .{ index + 1, comments.len })) |head| {
        builder.append(head);
    } else |_| {}
    builder.append("「");
    builder.append(text);
    builder.append("」@");
    builder.append(if (author.len == 0) "未知作者" else author);
    writeSuspectNote(&builder, suspect);
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, dfy.getInt(ctx.state, "counter") orelse 0);

    try reply.stateStr("lastCommentId", id);
    if (author.len > 0) try reply.stateStr("lastCommentAuthor", author);
    if (text.len > 0) try reply.stateStr("lastCommentText", text);
    try reply.stateBool("lastCommentSuspect", suspect);
    try reply.stateInt("commentIndex", @intCast(index));
    try clearReplySelection(reply);
}

fn selectReply(ctx: *dfy.Context, index: usize, replies: []const dfy.Value) !void {
    const reply = ctx.reply;
    const item = replies[index];
    const id = dfy.getStr(item, "id") orelse "";
    const author = dfy.getStr(item, "author") orelse "";
    const text = dfy.getStr(item, "text") orelse "";
    const suspect = dfy.getBool(item, "suspect") orelse false;

    var builder = SayBuilder{};
    var head_buffer: [64]u8 = undefined;
    if (std.fmt.bufPrint(&head_buffer, "选中第 {d}/{d} 条回复：", .{ index + 1, replies.len })) |head| {
        builder.append(head);
    } else |_| {}
    builder.append("「");
    builder.append(text);
    builder.append("」@");
    builder.append(if (author.len == 0) "未知作者" else author);
    writeSuspectNote(&builder, suspect);
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, dfy.getInt(ctx.state, "counter") orelse 0);

    try reply.stateStr("lastReplyId", id);
    if (author.len > 0) try reply.stateStr("lastReplyAuthor", author);
    if (text.len > 0) try reply.stateStr("lastReplyText", text);
    try reply.stateBool("lastReplySuspect", suspect);
    try reply.stateInt("replyIndex", @intCast(index));
}

// ---------------------------------------------------------------------------
// 事件处理
// ---------------------------------------------------------------------------

const WriteResult = struct {
    kind: WriteKind,
    ok: bool,
    reason: []const u8,
};

fn findWriteResult(results: []const dfy.Value) ?WriteResult {
    for (results) |entry| {
        if (entry != .object) continue;
        const id = dfy.getStr(entry, "id") orelse continue;
        const kind = kindFromEffectId(id) orelse continue;
        return .{
            .kind = kind,
            .ok = dfy.getBool(entry, "ok") orelse false,
            .reason = dfy.getStr(entry, "error") orelse "",
        };
    }
    return null;
}

/// Build and emit one write request. The URL is just the endpoint; the JSON
/// body carries a validated id and - when the action needs it - the user's own
/// text. Nothing from the feed can reach this function's `text` argument.
fn emitWrite(
    reply: *dfy.Reply,
    kind: WriteKind,
    bridge: []const u8,
    target: []const u8,
    text: []const u8,
) !bool {
    var url_buffer: [1_024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ bridge, kind.path() }) catch return false;

    // 200 个字符最多 800 字节；JSON 转义最坏翻倍，再留一点结构开销。
    var body_buffer: [Guard.max_user_text * 8 + 128]u8 = undefined;
    var at: usize = 0;
    const head = std.fmt.bufPrint(
        &body_buffer,
        "{{\"{s}\":\"",
        .{kind.targetKey()},
    ) catch return false;
    at = head.len;
    if (!appendJsonString(&body_buffer, &at, target)) return false;
    if (kind.needsText()) {
        const middle = std.fmt.bufPrint(body_buffer[at..], "\",\"text\":\"", .{}) catch return false;
        at += middle.len;
        if (!appendJsonString(&body_buffer, &at, text)) return false;
    }
    const tail = std.fmt.bufPrint(body_buffer[at..], "\"}}", .{}) catch return false;
    at += tail.len;

    try reply.httpRequest(kind.effectId(), "POST", url, body_buffer[0..at]);
    try reply.stateStr("pendingWrite", kind.effectId());
    return true;
}

/// The write path shared by commands and auto-favourite: validate the target
/// against this run's own state, consult the guard, then emit exactly one
/// request - or explain why not.
fn resolveTarget(state: dfy.Value, kind: WriteKind) struct { id: []const u8, provenance: []const u8 } {
    return switch (kind) {
        .reply => blk: {
            // 已经选过某条回复就必须写在它下面；选中的回复过期时宁可拒绝，
            // 也不偷偷改成评论——静默降级本身就是一种被引导。
            if (dfy.getStr(state, "lastReplyId")) |reply_id| {
                if (reply_id.len > 0) break :blk .{ .id = reply_id, .provenance = "replyIds" };
            }
            break :blk .{
                .id = dfy.getStr(state, "lastCommentId") orelse "",
                .provenance = "commentIds",
            };
        },
        .comment_like => .{
            .id = dfy.getStr(state, "lastCommentId") orelse "",
            .provenance = "commentIds",
        },
        else => .{ .id = dfy.getStr(state, "lastId") orelse "", .provenance = "videoIds" },
    };
}

fn requestWrite(
    ctx: *dfy.Context,
    kind: WriteKind,
    bridge: []const u8,
    counter: i64,
    allow_writes: bool,
    daily_limit: i64,
    cooldown_ms: i64,
    text: []const u8,
) !void {
    const reply = ctx.reply;
    if (bridge.len == 0) {
        try reply.say("还没配置抖音桥接地址，先在面板里填上吧。");
        reply.status("等待配置桥接地址", null, counter);
        return;
    }

    const resolved = resolveTarget(ctx.state, kind);
    const target = resolved.id;

    const refusal = writeRefusal(.{
        .allow = allow_writes,
        .target_valid = validId(target),
        .target_proven = stateContainsId(ctx.state, resolved.provenance, target),
        .target_len = target.len,
        .needs_text = kind.needsText(),
        .text_len = text.len,
        .cooldown_ms = cooldown_ms,
        .daily_limit = daily_limit,
        .now = ctx.now,
        .last_write_at = dfy.getInt(ctx.state, "lastWriteAt") orelse 0,
        .writes_today = writesToday(ctx.state, ctx.now),
    });

    var line_buffer: [240]u8 = undefined;
    if (refusal) |reason| {
        // A command always answers with the reason; silence would look like a
        // broken button.
        const line = std.fmt.bufPrint(&line_buffer, "{s}：{s}", .{ kind.doneLabel(), reason }) catch reason;
        try reply.say(line);
        reply.status(line, null, counter);
        return;
    }

    if (!try emitWrite(reply, kind, bridge, target, text)) {
        try reply.say("桥接地址太长或文本编码失败，这次没发出去。");
        reply.status("写入中止", null, counter);
        return;
    }

    const pending = std.fmt.bufPrint(&line_buffer, "正在{s}…", .{kind.doneLabel()}) catch "正在写入…";
    reply.status(pending, null, counter);
}

fn onEvent(ctx: *dfy.Context) anyerror!void {
    const reply = ctx.reply;
    const kind = dfy.getStr(ctx.event, "type") orelse "tick";

    const options = dfy.get(ctx.config, "options") orelse .null;
    const bridge = dfy.getStr(options, "bridgeUrl") orelse "";
    const interval = dfy.getInt(options, "intervalSeconds") orelse 20;
    const boost = dfy.getBool(options, "interestBoost") orelse true;
    const allow_writes = dfy.getBool(options, "allowWrites") orelse false;
    const auto_favorite = dfy.getBool(options, "autoFavorite") orelse false;
    const auto_reply = dfy.getBool(options, "autoReply") orelse false;
    const daily_limit = clampInt(
        dfy.getInt(options, "dailyWriteLimit") orelse 5,
        Guard.daily_min,
        Guard.daily_max,
    );
    const cooldown_ms = clampInt(
        dfy.getInt(options, "writeCooldownSeconds") orelse 60,
        Guard.cooldown_min_s,
        Guard.cooldown_max_s,
    ) * 1000;
    const interests = dfy.getList(ctx.config, "interests");

    // The only text this plug-in may ever send: what the user typed into the
    // settings panel. Sanitised once, reused verbatim.
    var comment_buffer: [Guard.max_user_text * 4]u8 = undefined;
    const user_comment = sanitize(
        &comment_buffer,
        dfy.getStr(options, "commentText") orelse "",
        Guard.max_user_text,
    );
    var reply_buffer: [Guard.max_user_text * 4]u8 = undefined;
    const user_reply = sanitize(
        &reply_buffer,
        dfy.getStr(options, "replyText") orelse "",
        Guard.max_user_text,
    );

    const counter = dfy.getInt(ctx.state, "counter") orelse 0;
    const seen = dfy.getList(ctx.state, "seen");

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
        if (try handleCommand(
            ctx,
            name,
            counter,
            bridge,
            allow_writes,
            daily_limit,
            cooldown_ms,
            user_comment,
            user_reply,
        )) {
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

        // A write came back: record it, then keep the usual rhythm going.
        if (findWriteResult(results)) |written| {
            var line_buffer: [240]u8 = undefined;
            if (written.ok) {
                const today = writesToday(ctx.state, ctx.now) + 1;
                try reply.stateInt("writeDay", dayOf(ctx.now));
                try reply.stateInt("writesToday", today);
                try reply.stateInt("lastWriteAt", ctx.now);
                const line = std.fmt.bufPrint(&line_buffer, "{s}好了。", .{written.kind.doneLabel()}) catch "写好了。";
                try reply.say(line);
                reply.status(line, null, counter);
            } else {
                var reason_buffer: [Guard.max_error * 4]u8 = undefined;
                const reason = sanitize(&reason_buffer, written.reason, Guard.max_error);
                const shown = if (reason.len == 0) "桥接没有响应" else reason;
                const line = std.fmt.bufPrint(
                    &line_buffer,
                    "{s}失败：{s}",
                    .{ written.kind.doneLabel(), shown },
                ) catch "写入失败。";
                try reply.say(line);
                reply.status(line, null, counter);
            }
            try reply.stateRemove("pendingWrite");
            reply.schedule(clampSeconds(interval));
            return;
        }

        const feed = findEffect(results, "feed") orelse {
            reply.status("等待桥接响应", null, counter);
            reply.schedule(clampSeconds(interval));
            return;
        };
        const ok = dfy.getBool(feed, "ok") orelse false;
        if (!ok) {
            var reason_buffer: [Guard.max_error * 4]u8 = undefined;
            const reason = sanitize(
                &reason_buffer,
                dfy.getStr(feed, "error") orelse "桥接没有响应",
                Guard.max_error,
            );
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

        // 先落快照：写操作的目标来源证明就在这一步确定。后面的挑选必须限定在
        // 快照保留的前 `Snapshot.videos` 条里，否则会出现「选中了但没证明」。
        const writer = reply.stateWriter();
        try writeSnapshot(writer, items);
        try reply.stateInt("lastFetchAt", ctx.now);
        try reply.stateInt("available", @intCast(items.len));
        try reply.stateInt("browsePage", -1);

        var best: ?dfy.Value = null;
        var best_score: f64 = -1e18;
        var scanned: usize = 0;
        for (items) |item| {
            if (scanned >= Snapshot.videos) break;
            if (item != .object) continue;
            const id = dfy.getStr(item, "id") orelse continue;
            if (!validId(id)) continue;
            scanned += 1;
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
        const raw_title = dfy.getStr(picked, "title") orelse "";
        const raw_author = dfy.getStr(picked, "author") orelse "";
        const url = dfy.getStr(picked, "url") orelse "";

        // Everything from the bridge goes through the sanitiser before it can
        // be spoken.
        var title_buffer: [Guard.max_feed_text * 4]u8 = undefined;
        const raw_title_text = sanitize(&title_buffer, raw_title, Guard.max_feed_text);
        const title = if (raw_title_text.len == 0) "（无标题）" else raw_title_text;
        var author_buffer: [Guard.max_author * 4]u8 = undefined;
        const raw_author_text = sanitize(&author_buffer, raw_author, Guard.max_author);
        const author = if (raw_author_text.len == 0) "未知作者" else raw_author_text;
        const video_suspect = looksLikeInjection(raw_title) or looksLikeInjection(raw_author);

        // 评论：按点赞 + 兴趣挑一条，念出来就是「评价」。只在快照保留的
        // 前 `Snapshot.comments` 条里挑，保证念到的评论一定可写。
        var best_comment: ?dfy.Value = null;
        var best_comment_score: f64 = -1e18;
        var scanned_comments: usize = 0;
        for (dfy.getList(picked, "comments")) |comment| {
            if (scanned_comments >= Snapshot.comments) break;
            if (comment != .object) continue;
            const comment_id = dfy.getStr(comment, "id") orelse continue;
            if (!validId(comment_id)) continue;
            const comment_text = dfy.getStr(comment, "text") orelse "";
            if (comment_text.len == 0) continue;
            // 只念得出来的评论才参评：一句 900 字的评论本来就进不了桌宠嘴里，
            // 又最容易藏东西，直接跳过而不是靠扣分侥幸压住。
            if (comment_text.len > Snapshot.max_comment_bytes) continue;
            scanned_comments += 1;
            const likes = dfy.getFloat(comment, "likes") orelse 0;
            var score: f64 = if (likes < 0) 0 else if (likes > 5_000) 5_000 else likes;
            if (boost) score += interestScore(interests, comment_text, "");
            if (score > best_comment_score) {
                best_comment_score = score;
                best_comment = comment;
            }
        }

        var builder = SayBuilder{};
        builder.append("刷到：「");
        builder.append(title);
        builder.append("」@");
        builder.append(author);
        writeSuspectNote(&builder, video_suspect);
        if (best_comment) |comment| {
            var comment_text_buffer: [Guard.max_feed_text * 4]u8 = undefined;
            const comment_text = sanitize(
                &comment_text_buffer,
                dfy.getStr(comment, "text") orelse "",
                Guard.max_feed_text,
            );
            var comment_author_buffer: [Guard.max_author * 4]u8 = undefined;
            const comment_author = sanitize(
                &comment_author_buffer,
                dfy.getStr(comment, "author") orelse "",
                Guard.max_author,
            );
            const comment_suspect = looksLikeInjection(dfy.getStr(comment, "text") orelse "")
                or looksLikeInjection(dfy.getStr(comment, "author") orelse "");
            builder.append("；评论：「");
            builder.append(comment_text);
            builder.append("」@");
            builder.append(if (comment_author.len == 0) "未知作者" else comment_author);
            writeSuspectNote(&builder, comment_suspect);
        }
        const line = builder.slice();
        try reply.say(line);
        if (@rem(counter, 3) == 2) try reply.play("吃Token");

        // Newest first, capped, and never storing the same id twice.
        const seen_writer = reply.stateWriter();
        try seen_writer.key("seen");
        try seen_writer.beginArray();
        try seen_writer.str(item_id);
        var kept: usize = 1;
        for (seen) |entry| {
            if (!isString(entry)) continue;
            if (dfy.eql(entry.string, item_id)) continue;
            if (kept >= seen_limit) break;
            try seen_writer.str(entry.string);
            kept += 1;
        }
        try seen_writer.endArray();

        try reply.stateInt("counter", counter + 1);
        try reply.stateStr("lastId", item_id);
        try reply.stateStr("lastTitle", title);
        try reply.stateStr("lastAuthor", author);
        try reply.stateBool("lastSuspect", video_suspect);
        if (isHttpsUrl(url)) try reply.stateStr("lastUrl", url);
        // 新一轮抓取就把选择游标归零：第一次 pick / pick-comment 落在第一条。
        try reply.stateInt("pickIndex", -1);

        // The one id an autonomous reply may use, taken from this very fetch.
        var auto_reply_target: []const u8 = "";
        var auto_reply_suspect = true;

        // Provenance for later writes: only ids the bridge actually returned.
        if (best_comment) |comment| {
            const comment_id = dfy.getStr(comment, "id") orelse "";
            var comment_text_buffer: [Guard.max_feed_text * 4]u8 = undefined;
            const comment_text = sanitize(
                &comment_text_buffer,
                dfy.getStr(comment, "text") orelse "",
                Guard.max_feed_text,
            );
            var comment_author_buffer: [Guard.max_author * 4]u8 = undefined;
            const comment_author = sanitize(
                &comment_author_buffer,
                dfy.getStr(comment, "author") orelse "",
                Guard.max_author,
            );
            const comment_suspect = looksLikeInjection(dfy.getStr(comment, "text") orelse "")
                or looksLikeInjection(dfy.getStr(comment, "author") orelse "");
            try reply.stateStr("lastCommentId", comment_id);
            try reply.stateStr("lastCommentAuthor", if (comment_author.len == 0) "未知作者" else comment_author);
            try reply.stateStr("lastCommentText", comment_text);
            try reply.stateBool("lastCommentSuspect", comment_suspect);
            try reply.stateInt("commentIndex", -1);
            if (validId(comment_id) and !comment_suspect) {
                auto_reply_target = comment_id;
                auto_reply_suspect = false;
            }

            // 回复也只在快照保留的前 `Snapshot.replies` 条里挑。
            const replies = dfy.getList(comment, "replies");
            var chosen_reply: ?dfy.Value = null;
            var scanned_replies: usize = 0;
            for (replies) |item| {
                if (scanned_replies >= Snapshot.replies) break;
                if (item != .object) continue;
                const reply_id = dfy.getStr(item, "id") orelse continue;
                if (!validId(reply_id)) continue;
                const reply_text = dfy.getStr(item, "text") orelse "";
                if (reply_text.len == 0 or reply_text.len > Snapshot.max_comment_bytes) continue;
                scanned_replies += 1;
                chosen_reply = item;
                break;
            }
            if (chosen_reply) |item| {
                const reply_id = dfy.getStr(item, "id") orelse "";
                var reply_text_buffer: [Guard.max_feed_text * 4]u8 = undefined;
                const reply_text = sanitize(
                    &reply_text_buffer,
                    dfy.getStr(item, "text") orelse "",
                    Guard.max_feed_text,
                );
                var reply_author_buffer: [Guard.max_author * 4]u8 = undefined;
                const reply_author = sanitize(
                    &reply_author_buffer,
                    dfy.getStr(item, "author") orelse "",
                    Guard.max_author,
                );
                const reply_suspect = looksLikeInjection(dfy.getStr(item, "text") orelse "")
                    or looksLikeInjection(dfy.getStr(item, "author") orelse "");
                try reply.stateStr("lastReplyId", reply_id);
                try reply.stateStr("lastReplyAuthor", if (reply_author.len == 0) "未知作者" else reply_author);
                try reply.stateStr("lastReplyText", reply_text);
                try reply.stateBool("lastReplySuspect", reply_suspect);
                try reply.stateInt("replyIndex", -1);
                // 目标回复可疑时退回评论；评论也可疑就由 auto_reply_suspect
                // 保持为 true，整轮自动回复作废。
                if (validId(reply_id) and !reply_suspect) {
                    auto_reply_target = reply_id;
                }
            } else {
                try reply.stateRemove("lastReplyId");
                try reply.stateRemove("lastReplyAuthor");
                try reply.stateRemove("lastReplyText");
                try reply.stateRemove("lastReplySuspect");
                try reply.stateRemove("replyIndex");
            }
        } else {
            try clearCommentSelection(reply);
        }

        reply.status(line, null, counter + 1);

        // 自主写入：一条视频最多一条，回复优先于收藏。
        // 目标 id 与正文都来自本次抓取的 id 与设置；feed 文本到这里只是被引述。
        // 任何一个环节被 `looksLikeInjection` 标记，就退回下一层，退无可退就不发。
        var wrote_this_round = false;

        const auto_reply_wanted = auto_reply
            and allow_writes
            and user_reply.len > 0
            and best_comment != null
            and best_comment_score >= Guard.auto_interest_score
            and !video_suspect
            and !auto_reply_suspect;
        if (auto_reply_wanted) {
            const refusal = writeRefusal(.{
                .allow = allow_writes,
                .target_valid = validId(auto_reply_target),
                // ctx.state 还没有合入本次快照，来源证明只能在这次抓取上重算。
                .target_proven = provenReply(items, auto_reply_target)
                    or provenComment(items, auto_reply_target),
                .target_len = auto_reply_target.len,
                .needs_text = true,
                .text_len = user_reply.len,
                .cooldown_ms = cooldown_ms,
                .daily_limit = daily_limit,
                .now = ctx.now,
                .last_write_at = dfy.getInt(ctx.state, "lastWriteAt") orelse 0,
                .writes_today = writesToday(ctx.state, ctx.now),
            });
            // Same guard as the commands: a refusal here is silent, because the
            // user did not press anything.
            if (refusal == null) {
                if (try emitWrite(reply, .reply, bridge, auto_reply_target, user_reply)) {
                    wrote_this_round = true;
                } else {
                    reply.status("自动回复没发出去", null, counter + 1);
                }
            }
        }

        if (!wrote_this_round and auto_favorite and allow_writes and best_score >= Guard.auto_interest_score and !video_suspect) {
            const refusal = writeRefusal(.{
                .allow = allow_writes,
                .target_valid = validId(item_id),
                .target_proven = provenVideo(items, item_id),
                .target_len = item_id.len,
                .needs_text = false,
                .text_len = 0,
                .cooldown_ms = cooldown_ms,
                .daily_limit = daily_limit,
                .now = ctx.now,
                .last_write_at = dfy.getInt(ctx.state, "lastWriteAt") orelse 0,
                .writes_today = writesToday(ctx.state, ctx.now),
            });
            if (refusal == null) {
                if (!try emitWrite(reply, .favorite, bridge, item_id, "")) {
                    reply.status("自动收藏没发出去", null, counter + 1);
                }
            }
        }
        // The chain only continues if we ask for it: without this the plug-in
        // would stop after the very first clip.
        reply.schedule(clampSeconds(interval));
        return;
    }

    // tick / next: ask the bridge for the current feed.
    var url_buffer: [512]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buffer,
        "{s}/feed?limit={d}&comments=1",
        .{ bridge, feed_limit },
    ) catch {
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
