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
//! 不能变成动作**：不能决定写什么、写给谁。写请求只有一条合法路径：
//!
//!   `command`（或明确开启的自动收藏 / 自动回复） → `writeRefusal` 通过 → 发出请求
//!   （正文只可能是用户手写原文；`like` / `favorite` / `comment-like` 不带正文）。
//!
//! 守门规则见 `WriteContext`：开关、目标格式 / 来源证明 / 可疑标记、正文非空（来源
//! 由调用点保证）、在途写入、每日写入额度（含顶替预留）、冷却。
//! 正文这一项由 `bodyRefusal` 定：只判定能不能原样发，绝不改写一个字。
//! 只要有一项不满足就拒绝。命令路径会把拒绝理由念给用户听——按钮是你按的，
//! 你得知道为什么没动静；自动路径对普通拒绝保持安静，`tick` 抓回来的一句话
//! 不该替你在桌面上嚷「每日写入额度用完了」。两个例外都由调用点处理：正文
//! 不合规只留一行状态，提示用户手动执行命令看具体原因；「写入序号用尽」才
//! 念出来——那不是「这一条不该写」，而是插件的写入账本坏了，恢复动作必须
//! 说出来。两条路径共用同一份守门，没有哪条能绕过去。
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
//!
//! 3. 传出正文上：`commentText` / `replyText` 走 `bodyRefusal` —— 只判定能否
//!    原样发送（无不可见字符、不换行或制表符、不超过 200 字），不合规就拒发
//!    并说明理由。展示通道可以剪，发送通道不能「洗」：清洗后照发会让发出去
//!    的那句变成用户没写过的话。
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
    // `_s` 是设置项里的秒数上下限，`_ms` 是内部按毫秒算的时长；两者别相加。
    const cooldown_min_s: i64 = 10;
    const cooldown_max_s: i64 = 600;
    /// 写入发出后等回执的上限；超时视为回执丢失，解除在途拦截，免得一次
    /// 丢包把写入永久锁死。冷却照常生效，所以超时后的重试仍可能被冷却拦住。
    /// 这个窗口只管在途：时钟回拨（当前时间早于发出时间）不去判过期，而是
    /// 由 `settleClock` 把时间戳重锚到当前时间，并按在途继续拦住——最多让
    /// 用户多等一个窗口。时钟往前跳超过这个窗口只是让在途放行，冷却按自己的
    /// `cooldown_ms` 独立计算（配到 600 秒时比这个窗口长），所以前跳 130 秒、
    /// 冷却 600 秒时在途已过期、冷却仍然拦得住。
    const in_flight_timeout_ms: i64 = 120_000;
    /// 自动收藏只认「命中兴趣」的视频，热度高不算。
    const auto_interest_score: f64 = 2_000;
    /// 超时重试时被顶替的旧 token 名单上限。名单只用于事后识别回执并播报
    /// 结果；每日写入额度在被顶替那一刻就计数，所以名单再丢也不会放宽封顶。
    const stale_write_max: usize = 3;
};

/// 被后续写入顶替的旧 token 名单：有界，最旧的先丢。每日写入额度在被顶替时
/// 先记一笔（宁可高估），迟到回执只用来向用户确认结果，不参与计数。
const StaleWrites = struct {
    const max_entries: usize = Guard.stale_write_max;
    const max_token: usize = 40;
    const capacity: usize = max_entries * max_token + 8;

    entries: [max_entries][max_token]u8 = undefined,
    lens: [max_entries]usize = undefined,
    count: usize = 0,

    const empty = StaleWrites{};

    /// Parse persisted stale-token text. Unknown or malformed items are
    /// dropped so corrupt state cannot revive a growing list.
    fn parse(saved: []const u8) StaleWrites {
        var list = StaleWrites.empty;
        var remaining = std.mem.splitScalar(u8, saved, ',');
        while (remaining.next()) |entry| {
            // 名单只收写回执 token：手改出的 `feed` 之类会在 `settle` 里按 id
            // 全等匹配到抓取回执，被当成「超时写入确认成功」并吞掉同批推荐。
            // 可用性校验、去重与「满了丢最旧」都由 `append` 负责，两处共用一套
            // 规则，免得落盘名单与内存名单哪天改岔。
            _ = list.append(entry);
        }
        return list;
    }

    fn contains(self: StaleWrites, token: []const u8) bool {
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            if (std.mem.eql(u8, self.entries[index][0..self.lens[index]], token)) return true;
        }
        return false;
    }

    /// Append `token`, dropping the oldest entry when the list is full.
    /// Returns false when the token is unusable or already listed, so the
    /// caller only counts a write it has not already counted.
    fn append(self: *StaleWrites, token: []const u8) bool {
        if (!usableToken(token) or self.contains(token)) return false;
        if (self.count == max_entries) self.dropOldest();
        @memcpy(self.entries[self.count][0..token.len], token);
        self.lens[self.count] = token.len;
        self.count += 1;
        return true;
    }

    fn dropOldest(self: *StaleWrites) void {
        self.removeAt(0);
    }

    /// 名单里最大的序号。新 token 必须大于它，否则名单上的旧 token 会被
    /// 复用，重投的旧回执就能冒充新写入（名单是持久状态，可被手改）。
    fn maxSequence(self: StaleWrites) ?i64 {
        var max: ?i64 = null;
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const seq = tokenSequence(self.entries[index][0..self.lens[index]]) orelse continue;
            if (max == null or seq > max.?) max = seq;
        }
        return max;
    }

    fn removeAt(self: *StaleWrites, index: usize) void {
        var at = index;
        while (at + 1 < self.count) : (at += 1) {
            self.entries[at] = self.entries[at + 1];
            self.lens[at] = self.lens[at + 1];
        }
        self.count -= 1;
    }

    /// Settle every stale token that has a receipt in this result batch.
    /// Successes are already reflected in `writesToday`; this only reports
    /// what happened and keeps unmatched tokens for later confirmation.
    fn settle(self: *StaleWrites, results: []const dfy.Value) StaleSettlement {
        var settlement = StaleSettlement{};
        var index: usize = 0;
        while (index < self.count) {
            const entry = self.entries[index][0..self.lens[index]];
            var matched = false;
            for (results) |result| {
                if (result != .object) continue;
                const id = dfy.getStr(result, "id") orelse continue;
                if (!dfy.eql(id, entry)) continue;
                matched = true;
                // 缺 `ok` 的回执说不清成败：既不按成功也不按失败，只从名单
                // 摘掉并如实告诉用户「无法确认」，不替桥接编造结论。
                if (dfy.getBool(result, "ok")) |ok| {
                    if (ok) {
                        settlement.succeeded += 1;
                    } else {
                        settlement.failed += 1;
                    }
                } else {
                    settlement.unconfirmed += 1;
                }
                settlement.changed = true;
                self.removeAt(index);
                break;
            }
            if (!matched) index += 1;
        }
        return settlement;
    }

    fn save(self: StaleWrites, reply: *dfy.Reply) !void {
        if (self.count == 0) {
            try reply.stateRemove("staleWrites");
            return;
        }
        var buffer: [capacity]u8 = undefined;
        var at: usize = 0;
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            if (at + self.lens[index] + 1 > buffer.len) break;
            if (at > 0) {
                buffer[at] = ',';
                at += 1;
            }
            @memcpy(buffer[at..][0..self.lens[index]], self.entries[index][0..self.lens[index]]);
            at += self.lens[index];
        }
        try reply.stateStr("staleWrites", buffer[0..at]);
    }
};

pub const StaleSettlement = struct {
    /// 回执确认成功的笔数。被顶替那一刻已经记过一笔，所以它只用于播报。
    succeeded: i64 = 0,
    failed: i64 = 0,
    /// 回执在但读不出 `ok` 的条目：只摘名单，不下结论。
    unconfirmed: i64 = 0,
    /// 这次结算是否真的动过名单，决定要不要落盘（没动就不写）。
    changed: bool = false,
};

/// A receipt may settle stale writes and a new write may replace the current
/// in-flight slot in the same event. `ctx.state` stays stale until the host
/// merges the reply, so this event-local list is the only source of truth
/// while the handler runs.
threadlocal var round_stale = StaleWrites.empty;

/// 本次事件已经发出几笔写入。守门与调用链本来只允许一笔，这里再钉一道：
/// 万一以后有人加了第二条写入路径，也不会在同一轮里把同一个旧 token
/// 重复顶替、重复计入每日写入额度。
threadlocal var writes_this_event: u32 = 0;

/// 从写入 token（`write:<动作>:<序号>`）里读回序号；读不出返回 null。
/// 用于 `writeSeq` 被写坏时兜底，避免新 token 与仍在途的那一笔撞号。
///
/// 位数上限必须覆盖 `emitWrite` 能写出的全部序号：`i64` 上限是 19 位，
/// `emitWrite` 只在 `seq >= maxInt(i64)` 时拒绝，所以最后一笔合法 token 可能是
/// 19 位。上限若收得比它紧，这笔回执就会被判成「认不出动作」——成功不计数、
/// 每日封顶静默失效，而状态本身看起来完全合法。超范围仍由 `parseInt` 的
/// overflow 兜住。
fn tokenSequence(token: []const u8) ?i64 {
    const at = std.mem.lastIndexOfScalar(u8, token, ':') orelse return null;
    const digits = token[at + 1 ..];
    if (digits.len == 0 or digits.len > 19) return null;
    for (digits) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

/// 只有写回执形状、且动作名认得出的字符串才允许进超时名单。名单项会被拿去和
/// 回执 id 全等比较，收进 `feed` 这类 id 就会把抓取回执当成写入回执处理；
/// 动作认不出的 token（`write:`、`write:x:1`）进名单也没法在结算时说明是哪
/// 种写入，所以同样不收——它若占着 `pendingWrite`，被顶替时照样计数（见
/// `emitWrite` 里那一段）。带 `,` 的 token 也不收：名单用逗号拼成一串落盘，
/// 收进来会在下一次读回时被拆成两条，内存名单与落盘名单就对不上了。
fn usableToken(token: []const u8) bool {
    return token.len > 0
        and token.len <= StaleWrites.max_token
        and std.mem.indexOfScalar(u8, token, ',') == null
        and kindFromToken(token) != null;
}

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

/// 传出正文的硬闸门：只判定设置面板里那句原文能不能**原样**发出去，绝不改写。
/// 桥接文本走 `sanitize`（展示通道），两条通道的规则故意不同：展示可以剪，
/// 发送不行——清洗后照发会让发出去的那句变成用户没写过的话。
///
/// 返回 null 表示可以逐字发送，否则返回拒绝理由（命令路径念给用户听）。
fn bodyRefusal(text: []const u8) ?[]const u8 {
    var view = std.unicode.Utf8View.init(text) catch return "正文不是有效的 UTF-8，守门已拒绝发送";
    var it = view.iterator();
    var chars: usize = 0;
    while (it.nextCodepoint()) |cp| {
        chars += 1;
        // 换行与制表符单独说：它们在 `isInvisible` 里也算控制符，但「不能换行」
        // 是用户能直接改的一条，说成「不可见字符」只会让人去猜。
        if (cp == '\n' or cp == '\r' or cp == '\t') return "正文不能换行或带制表符，守门已拒绝发送";
        if (isInvisible(cp)) return "正文里有不可见字符（控制符 / 零宽 / 双向覆盖），守门已拒绝发送";
    }
    if (chars > Guard.max_user_text) return "正文超过 200 字，守门已拒绝发送，先改短再试";
    return null;
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

    /// 回执 id 里的动作段，也是 `parseWriteKind` 认识的唯一写法。
    fn actionName(self: WriteKind) []const u8 {
        return switch (self) {
            .like => "like",
            .favorite => "favorite",
            .comment => "comment",
            .reply => "reply",
            .comment_like => "comment-like",
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

/// 写回执 id 形如 `write:<kind>:<seq>`。只解析前缀与第一段动作名，
/// 序号不参与种类判断——认出动作是为了念对一句话，不是为了确认归属；
/// 归属只认和 `pendingWrite` 全等（见 `findWriteReceipt`）。
fn kindFromToken(id: []const u8) ?WriteKind {
    if (!std.mem.startsWith(u8, id, "write:")) return null;
    const rest = id["write:".len..];
    const name = if (std.mem.indexOfScalar(u8, rest, ':')) |at| blk: {
        // 新 token 必须带十进制序号；旧版的 `write:<action>` 仍保留兼容。
        if (tokenSequence(id) == null) return null;
        break :blk rest[0..at];
    } else rest;
    return parseWriteKind(name);
}

/// 回执列表里是否出现过任何写回执（不论归属、不论认不认识）。
fn hasWriteReceipt(results: []const dfy.Value) bool {
    for (results) |entry| {
        if (entry != .object) continue;
        const id = dfy.getStr(entry, "id") orelse continue;
        if (std.mem.startsWith(u8, id, "write:")) return true;
    }
    return false;
}

fn settleStaleWrites(reply: *dfy.Reply, results: []const dfy.Value) !StaleSettlement {
    const settlement = round_stale.settle(results);
    if (settlement.changed) try round_stale.save(reply);
    return settlement;
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
    target_suspect: bool,
    target_len: usize,
    needs_text: bool,
    text_len: usize,
    /// 上一笔写入已经发出、回执还没回来，而且还没到超时。
    in_flight: bool,
    cooldown_ms: i64,
    daily_limit: i64,
    now: i64,
    last_write_at: i64,
    writes_today: i64,
    /// 当前请求会顶替一笔已超时但尚未结算的写入。旧账与新账都要
    /// 预留额度，避免「先顶替计一笔，再立刻发一笔」越过上限。
    replaces_in_flight: bool,
};

/// The guard. Returns null when the write may go out, otherwise the reason it
/// must not. The command path shows that reason to the user; the automatic path
/// stays silent by design, except for the sequence-exhausted case.
fn writeRefusal(ctx: WriteContext) ?[]const u8 {
    if (!ctx.allow) return "写操作总开关是关的，先设置里勾「允许写入」";
    if (ctx.target_len == 0) return "还没有选中目标，先 browse / pick 选一条视频";
    if (!ctx.target_valid) return "选中的目标格式不对，拒绝写入";
    if (!ctx.target_proven) return "选中的目标不在最近一次抓取里，重新刷一次再选";
    if (ctx.target_suspect) return "目标内容被标记为可疑，守门已拒绝写入";
    if (ctx.needs_text and ctx.text_len == 0) return "设置里还没写要发送的原文";
    // 坏状态下这条可能永远成立：`inFlightState` 对「`writeInFlight` 非 0 却没有
    // 可用时间戳」也判在途，那种状态不会超时；`pendingWrite` 也为空时，更没有
    // token 能让回执清掉它。所以除了等回执，必须同时说出唯一的人工出口。
    if (ctx.in_flight) return "上一笔写入还没回执（等它回来，或执行 reset 重来）";
    if (ctx.writes_today >= ctx.daily_limit) return "每日写入额度用完了";
    if (ctx.replaces_in_flight and ctx.writes_today + 2 > ctx.daily_limit) {
        // 这里 `writes_today` 可能还是 0（旧账要到顶替那一刻才计），说「用完」
        // 会让人以为额度已经被别人占光。如实说成「剩下的额度不够」。
        // 这一支拒绝后状态一动不动，旧的在途槽也还在，所以要说清唯一出口，
        // 否则额度卡在 `daily_limit - 1` 的用户会以为只能等到明天。
        return "今天剩下的每日写入额度不够再发一笔（超时那笔也要先占额度）；等它的回执，或执行 reset 重来";
    }
    // 时钟回拨时 `settleClock` 会把持久化里的 `lastWriteAt` 重锚到当前时间，
    // 但那次重锚要等宿主合并 state 之后才对下一次事件生效；本事件读到的仍是
    // 未来值，差值因此为负，比较结果天然为真，按冷却拦住而不是放行。
    if (ctx.last_write_at > 0 and ctx.now - ctx.last_write_at < ctx.cooldown_ms) {
        return "写入冷却中，晚点再试";
    }
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
    // 只有「日期桶比今天旧」才算换天归零。桶被写到未来（手改状态、或系统时钟
    // 往前跳了一天以上）时一律按同日处理：宁可把额度多压到真实换天前，也不让
    // 一次前跳当场把每日写入额度重新打开。
    if (saved_day < day) return 0;
    const saved = dfy.getInt(state, "writesToday") orelse 0;
    // 两头都钳：负数会让「额度没用完」长期成立，超出上限的值再 +1 会在
    // ReleaseSafe 下把 WASM 打成 trap、在 ReleaseFast 下回绕成负数。
    return clampInt(saved, 0, Guard.daily_max);
}

const InFlight = struct {
    /// 有证据表明上一笔写入还没结束。
    active: bool,
    /// 用来判定的时间戳落在未来（时钟回拨），需要重锚。
    future: bool,
};

/// 写入已发出、`effect-result` 还没回来时的状态。等待上限由
/// `Guard.in_flight_timeout_ms` 兜住：桥接永远不回话也不能把写入永久锁死，
/// 但刚发出的一笔总会拦住下一笔。坏状态一律按在途处理，用户能用 `reset`
/// 解卡，匹配的回执仍能按 token 清掉它：
/// - `writeInFlight` 是非整数（字符串 `"1"`、对象、坏值）时，不依赖 `pendingWrite`
///   就按在途处理，但仍和其它在途一样受 120 秒窗口约束；非零整数同样算在途；
/// - `writeInFlight` 为 0、为 `null` 或缺失时（`null` 与缺失同义），
///   只有 `pendingWrite` 非空才算在途；
/// - 时间锚先取 `writeInFlightAt`，再退到 `lastWriteAt`，两者都没有（或为 0）
///   就没有证据说明旧请求已经结束，继续拦住；
/// - 锚点落在未来（时钟回拨）算仍在途，由 `settleClock` 重锚，不做「过期放行」。
/// 0.4.1 没有 `writeInFlight`，只有 `pendingWrite` 与 `lastWriteAt`，走的就是
/// 第二条分支。冷却有各自的回拨防护，见 `settleClock`。
fn inFlightState(state: dfy.Value, now: i64) InFlight {
    var flagged = false;
    if (dfy.get(state, "writeInFlight")) |flag| {
        flagged = switch (flag) {
            .integer => |value| value != 0,
            // JSON `null` 与「键不存在」同义：宿主删键时可能留下 null，
            // 那不算「有一笔在途」的证据，交给 `pendingWrite` 去判断。
            .null => false,
            // 坏值没有证据说明不是 1，宁可拦住。
            else => true,
        };
    }
    if (!flagged) {
        const legacy_pending = dfy.getStr(state, "pendingWrite") orelse "";
        if (legacy_pending.len == 0) return .{ .active = false, .future = false };
    }
    var started: i64 = 0;
    if (dfy.getInt(state, "writeInFlightAt")) |at| {
        if (at > 0) started = at;
    }
    if (started <= 0) {
        if (dfy.getInt(state, "lastWriteAt")) |at| {
            if (at > 0) started = at;
        }
    }
    if (started <= 0) return .{ .active = true, .future = false };
    if (now < started) return .{ .active = true, .future = true };
    return .{ .active = now - started < Guard.in_flight_timeout_ms, .future = false };
}

fn isWriteInFlight(state: dfy.Value, now: i64) bool {
    return inFlightState(state, now).active;
}

fn replacesExpiredWrite(state: dfy.Value, now: i64) bool {
    const pending = dfy.getStr(state, "pendingWrite") orelse return false;
    return pending.len > 0 and !isWriteInFlight(state, now);
}

/// 把 `text` 追加到 `dest[at.*..]`；放不下返回 false，调用方退回一句短的。
fn appendLine(dest: []u8, at: *usize, text: []const u8) bool {
    if (at.* + text.len > dest.len) return false;
    @memcpy(dest[at.*..][0..text.len], text);
    at.* += text.len;
    return true;
}

/// 往 `dest` 里追加一段「格式化失败就整句退回」的片段。`piece` 放不下时把
/// `fits` 拉成 false，让调用方退回短句：宁可少说一句，也不能把一个已经摘出
/// 名单的笔数悄悄吞掉。
fn appendPiece(dest: []u8, at: *usize, piece: []u8, comptime text: []const u8, args: anytype, fits: *bool) void {
    const part = std.fmt.bufPrint(piece, text, args) catch "";
    if (part.len == 0) {
        fits.* = false;
        return;
    }
    fits.* = fits.* and appendLine(dest, at, part);
}

/// 迟到回执的播报：被顶替那一刻就已经记过一笔，这里只确认结果，
/// 不再改动每日写入额度（失败也不退回，宁可高估也不放宽封顶）。
///
/// 那一笔记在被顶替那天的桶里，不一定是今天：跨过 UTC 换天以后，今天的
/// `writesToday` 根本没有这笔旧账。所以措辞统一说「被顶替那天已占用一次每日写入额度」，
/// 不说「今日次数」——否则用户对着 `stats` 的数字怎么也对不上。
fn staleSettlementLine(buffer: []u8, settlement: StaleSettlement) []const u8 {
    if (settlement.succeeded == 0 and settlement.failed == 0) {
        return std.fmt.bufPrint(
            buffer,
            "刚才超时的 {d} 笔写入回执读不出结果，无法确认（被顶替那天已占用一次每日写入额度）。",
            .{settlement.unconfirmed},
        ) catch "刚才超时的旧写入回执无法确认。";
    }
    if (settlement.failed == 0 and settlement.unconfirmed == 0) {
        if (settlement.succeeded == 1) {
            return std.fmt.bufPrint(
                buffer,
                "刚才超时的那笔写入确认成功了（被顶替那天已占用一次每日写入额度，不重复计）。",
                .{},
            ) catch "刚才超时的那笔写入确认成功了。";
        }
        return std.fmt.bufPrint(
            buffer,
            "刚才超时的 {d} 笔写入确认成功了（被顶替那天都已占用一次每日写入额度，不重复计）。",
            .{settlement.succeeded},
        ) catch "刚才超时的旧写入确认成功了。";
    }
    if (settlement.succeeded == 0 and settlement.unconfirmed == 0) {
        if (settlement.failed == 1) {
            return std.fmt.bufPrint(
                buffer,
                "刚才超时的那笔写入确认失败了（被顶替那天已占用一次每日写入额度，失败也不退回）。",
                .{},
            ) catch "刚才超时的那笔写入确认失败了。";
        }
        return std.fmt.bufPrint(
            buffer,
            "刚才超时的 {d} 笔写入确认失败了（被顶替那天都已占用一次每日写入额度，失败也不退回）。",
            .{settlement.failed},
        ) catch "刚才超时的旧写入确认失败了。";
    }
    // 一批里成功、失败、读不出结果混在一起：只念真有数的那些。三种结果都写
    // 死会念出「失败 0 笔」，而漏掉任何一类又会把已经摘出名单的条目悄悄吞掉。
    var at: usize = 0;
    var piece: [96]u8 = undefined;
    var fits = appendLine(buffer, &at, "刚才超时的旧写入：");
    var first = true;
    if (settlement.succeeded > 0) {
        appendPiece(buffer, &at, &piece, "{s}成功 {d} 笔", .{ @as([]const u8, if (first) "" else "、"), settlement.succeeded }, &fits);
        first = false;
    }
    if (settlement.failed > 0) {
        appendPiece(buffer, &at, &piece, "{s}失败 {d} 笔", .{ @as([]const u8, if (first) "" else "、"), settlement.failed }, &fits);
        first = false;
    }
    if (settlement.unconfirmed > 0) {
        appendPiece(buffer, &at, &piece, "{s}{d} 笔无法确认", .{ @as([]const u8, if (first) "" else "、"), settlement.unconfirmed }, &fits);
    }
    fits = fits and appendLine(buffer, &at, "（被顶替那天都已占用一次每日写入额度，成功不重复计、失败也不退回）。");
    if (!fits) return "刚才超时的旧写入已结算。";
    return buffer[0..at];
}

/// 时钟回拨：把落在未来的时间戳重锚到当前时间，最多让用户多等一个窗口 /
/// 一次冷却，而不是让一次回拨把写入锁死到只能 `reset`。
///
/// 回执事件自己会结算在途状态（匹配的回执要 `stateRemove` 掉
/// `writeInFlightAt`），`reset` 要删掉这两个键；这两类事件不重锚，免得
/// 同一轮里先写后删，删除被合并逻辑吞掉。其余事件重锚一次即可，下一次
/// `now` 正常前进后就不再触发。
fn settleClock(ctx: *dfy.Context) !void {
    const kind = dfy.getStr(ctx.event, "type") orelse "";
    if (dfy.eql(kind, "effect-result")) return;
    if (dfy.eql(kind, "command") and dfy.eql(dfy.getStr(ctx.event, "name") orelse "", "reset")) return;
    if (inFlightState(ctx.state, ctx.now).future) {
        try ctx.reply.stateInt("writeInFlightAt", ctx.now);
    }
    if (dfy.getInt(ctx.state, "lastWriteAt")) |last| {
        if (last > 0 and ctx.now < last) try ctx.reply.stateInt("lastWriteAt", ctx.now);
    }
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
    seq: *i64,
) !bool {
    const reply = ctx.reply;
    if (dfy.eql(name, "reset")) {
        // 重置是用户解卡的出口：在途槽必须清掉，否则一笔丢包就能把写入锁到
        // 120 秒之后。代价是旧请求可能还在桥接侧跑，重置后立刻再写有可能让
        // 同一个动作做两遍——这个代价说出来，别让用户以为重置等于取消。
        const had_in_flight = isWriteInFlight(ctx.state, ctx.now);
        // 序号下限必须在清理之前算：在途那一笔与超时名单里的序号都还读得到。
        // 清完之后只剩 `writeSeq`，一旦它本身缺失或被写坏，没有这个下限就只能
        // 从 0 起重播种，与桥接侧还没结束的旧请求撞出同一个 token，旧回执回来
        // 就能冒充新写入。所以重播种至少写到这个下限。
        var seq_floor: i64 = 0;
        if (dfy.getStr(ctx.state, "pendingWrite")) |pending_token| {
            if (tokenSequence(pending_token)) |value| {
                if (value > seq_floor) seq_floor = value;
            }
        }
        if (round_stale.maxSequence()) |value| {
            if (value > seq_floor) seq_floor = value;
        }
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
        try reply.stateRemove("writeInFlight");
        try reply.stateRemove("writeInFlightAt");
        try reply.stateRemove("lastWriteAt");
        try reply.stateRemove("staleWrites");
        round_stale = StaleWrites.empty;
        try reply.stateRemove("writesToday");
        try reply.stateRemove("writeDay");
        // 上面是本次会话的选择、快照、计数与在途状态，都可以清；`writeSeq`
        // 原则上保留：序号在正常区间内必须跨重置单调，否则重置后第一笔写入会复用重置前
        // 在途那笔的 token，旧回执回来就能顶替新写入。它自己不可用（缺失、负数、
        // 或已撞上 i64 上限）时从 `seq_floor` 重播种而不是从 0：下限已经涵盖了
        // 在途与名单里的序号，这样重置永远是安全的解卡出口，不会顺手造出撞号。
        // 可用时也不许低于 `seq_floor`（手改状态可能把两者写岔）。
        //
        // 撞上 i64 上限时这条看着像绕圈：下限本身就是上限，重播种后仍是上限，
        // 下一笔照样 `sequence_exhausted`。但它不是死循环——这次 reset 同时删掉了
        // `pendingWrite` 与 `staleWrites`，所以第二次 reset 读到的下限是 0，序号
        // 回到可用区间。最坏情况要连按两次 reset，代价换来的是「重播种绝不去
        // 复用一个可能还在桥接侧跑着的旧序号」。
        const saved_seq = dfy.getInt(ctx.state, "writeSeq") orelse 0;
        const seq_usable = saved_seq >= 0 and saved_seq < std.math.maxInt(i64);
        const next_seq = if (seq_usable) @max(saved_seq, seq_floor) else seq_floor;
        try reply.stateInt("writeSeq", next_seq);
        if (had_in_flight) {
            try reply.say("计数清零，重新开始刷；上一笔写入可能还在桥接侧处理，别马上重发。");
        } else {
            try reply.say("计数清零，重新开始刷。");
        }
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
            "累计刷了 {d} 条，记了 {d} 个视频，快照里有 {d} 条，今天占用每日写入额度 {d} 次。",
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
            seq,
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

const WriteReceipt = struct {
    /// 从回执 token 认出的动作；`pendingWrite` 是损坏状态时才是 null。
    kind: ?WriteKind,
    /// 桥接没写 `ok` 时为 null：读不出成败就如实说无法确认，不替它下结论。
    /// 这一笔照样算占用一次每日写入额度——见事件处理里那一支的注释。
    ok: ?bool,
    reason: []const u8,
};

/// 只认和这次在途写入 token 全等的回执。`write:` 前缀只说明「这是一条写
/// 回执」，不能说明是哪一笔：上一笔迟到的、同一 token 重复投递的、0.4.1 留下
/// 的无序号回执，或者手改状态后对不上的，都可能撞上前缀，用前缀匹配会把当前
/// 在途标记提前清掉、顺手播报别人的动作结果。
fn findWriteReceipt(results: []const dfy.Value, expected: []const u8) ?WriteReceipt {
    for (results) |entry| {
        if (entry != .object) continue;
        const id = dfy.getStr(entry, "id") orelse continue;
        if (!dfy.eql(id, expected)) continue;
        return .{
            .kind = kindFromToken(id),
            .ok = dfy.getBool(entry, "ok"),
            .reason = dfy.getStr(entry, "error") orelse "",
        };
    }
    return null;
}

/// `emitWrite` 的结果。`failed` 与 `sequence_exhausted` 要分开报，否则序号用尽
/// 会被说成「地址或正文太长」，用户根本无从恢复。`no_bridge` 与 `already_wrote`
/// 同理分开：它们各有各的原因，混进 `failed` 会把「还没填地址」「本轮已经写过
/// 一笔」都说成「太长」，指错方向。
const EmitOutcome = enum { sent, failed, sequence_exhausted, no_bridge, already_wrote };

/// Build and emit one write request. The URL is just the endpoint; the JSON
/// body carries a validated id and - when the action needs it - the user's own
/// text. Nothing from the feed can reach this function's `text` argument.
/// On success it also claims the in-flight slot in `state` (sequence, pending
/// token, start time, cooldown start), so the next write waits for this one.
///
/// `seq` 由调用方持有：宿主要在事件返回后才合并 state，这里读 `ctx.state` 只会
/// 拿到旧值。当前每个事件至多写一笔（`writes_this_event`），这份本地副本只是
/// 让自增在合并前就可见。
fn emitWrite(
    ctx: *dfy.Context,
    seq: *i64,
    kind: WriteKind,
    bridge: []const u8,
    target: []const u8,
    text: []const u8,
) !EmitOutcome {
    const reply = ctx.reply;
    // 没有桥接地址时什么都不发：拼出来会是一个相对路径 `/favorite`，宿主只能
    // 当成无效请求。命令路径与两条自动写入路径都已经在上游拦过，这里是最后
    // 一道防御。
    if (bridge.len == 0) return .no_bridge;
    // 一个事件至多一笔写入（见 `writes_this_event`）。按设计走不到这里：命令
    // 分支按顺序短路，两条自动路径又都由 `writes_this_event` 串起来。真走到这里
    // 说明有人加了第三条写入路径，那时该给它单独的 `EmitOutcome`，不要复用
    // `.failed`——它的文案是「地址或正文太长」，会指错方向。这里先单独回
    // `.already_wrote`，让宿主念出「本轮已经写过一笔」，而不是编一个太长。
    if (writes_this_event > 0) return .already_wrote;
    var url_buffer: [1_024]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ bridge, kind.path() }) catch return .failed;

    // 200 个字符最多 800 字节；JSON 转义最坏翻倍，再留一点结构开销。
    var body_buffer: [Guard.max_user_text * 8 + 128]u8 = undefined;
    var at: usize = 0;
    const head = std.fmt.bufPrint(
        &body_buffer,
        "{{\"{s}\":\"",
        .{kind.targetKey()},
    ) catch return .failed;
    at = head.len;
    if (!appendJsonString(&body_buffer, &at, target)) return .failed;
    if (kind.needsText()) {
        const middle = std.fmt.bufPrint(body_buffer[at..], "\",\"text\":\"", .{}) catch return .failed;
        at += middle.len;
        if (!appendJsonString(&body_buffer, &at, text)) return .failed;
    }
    const tail = std.fmt.bufPrint(body_buffer[at..], "\"}}", .{}) catch return .failed;
    at += tail.len;

    // 每一笔写入带一个自己的序号，回执只认全等——同一端点连写两笔时，
    // 上一笔的迟到回执不会被当成这一笔的。
    var token_buffer: [64]u8 = undefined;
    if (seq.* >= std.math.maxInt(i64)) return .sequence_exhausted;
    seq.* += 1;
    const token = std.fmt.bufPrint(&token_buffer, "write:{s}:{d}", .{ kind.actionName(), seq.* }) catch return .failed;

    // 先把序号和在途槽落进 state，再发请求。这里不用为「写了一半失败」回滚：
    // 宿主拿到的是一个完整回包，`dfy_invoke` 在任何一步失败时都改发
    // `{"state":{},"effects":[],"pet":[]}`（见 `sdk/dfy.zig` 的 `FALLBACK`），
    // 所以状态与请求要么一起生效、要么一起不生效，不会留下没人认领的在途槽。
    //
    // 上一笔还没结算就被这一笔顶替（典型：120 秒超时后重试，或 0.4.1 留下的
    // 旧 pending），说明它可能已经在桥接侧成功、只是回执慢。这里先把它计入
    // 每日写入额度，宁可高估也不让反复超时绕开封顶；token 只留作迟到回执的
    // 事后确认。
    const previous = dfy.getStr(ctx.state, "pendingWrite") orelse "";
    var replaced_a_write = false;
    // 「旧账先计一笔」与「旧 token 进名单」是两条独立规则：名单只收写回执形状
    // 的 token，但读不出序号的坏 token（手改、跨版本残留）同样可能代表桥接侧
    // 一笔真实请求，入不了名单也要计数，否则「宁可高估」在这里破功。已经在
    // 名单上的旧 token 当初顶替时计过一次，这里不重复计。
    if (previous.len > 0 and !dfy.eql(previous, token) and !round_stale.contains(previous)) {
        replaced_a_write = true;
        // 坏 token 加不进名单：没东西可存，但上面的计数已经生效。
        if (round_stale.append(previous)) try round_stale.save(reply);
    }
    try reply.stateInt("writeSeq", seq.*);
    try reply.stateStr("pendingWrite", token);
    try reply.stateInt("writeInFlight", 1);
    try reply.stateInt("writeInFlightAt", ctx.now);
    // 冷却从「发出」起算，而不是等回执：收不到回执的那一笔同样占用冷却，
    // 重试绕不开冷却；被顶替的写入已经按「可能成功」先计入每日写入额度，
    // 迟到回执只用于播报确认结果。
    if (replaced_a_write) {
        // 饱和到上限：读到的值已经钳在 [0, daily_max]，再 +1 只会让落盘值
        // 越过上限一位，下一轮还得靠读取端再钳回来。
        const today = @min(writesToday(ctx.state, ctx.now) + 1, Guard.daily_max);
        try reply.stateInt("writeDay", dayOf(ctx.now));
        try reply.stateInt("writesToday", today);
    }
    try reply.stateInt("lastWriteAt", ctx.now);
    try reply.httpRequest(token, "POST", url, body_buffer[0..at]);
    writes_this_event += 1;
    return .sent;
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

fn targetIsSuspect(state: dfy.Value, kind: WriteKind) bool {
    const video_id = dfy.getStr(state, "lastId") orelse "";
    const video = findById(snapshotItems(state), video_id) orelse return true;
    if (kind != .reply and kind != .comment_like) {
        return dfy.getBool(video, "suspect") orelse true;
    }
    const comment_id = dfy.getStr(state, "lastCommentId") orelse "";
    const comment = findById(dfy.getList(video, "comments"), comment_id) orelse return true;
    const reply_id = dfy.getStr(state, "lastReplyId") orelse "";
    if (kind == .comment_like or reply_id.len == 0) {
        return dfy.getBool(comment, "suspect") orelse true;
    }
    const selected_reply = findById(dfy.getList(comment, "replies"), reply_id) orelse return true;
    return dfy.getBool(selected_reply, "suspect") orelse true;
}

fn requestWrite(
    ctx: *dfy.Context,
    seq: *i64,
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
        .target_suspect = targetIsSuspect(ctx.state, kind),
        .target_len = target.len,
        .needs_text = kind.needsText(),
        .text_len = text.len,
        .in_flight = isWriteInFlight(ctx.state, ctx.now),
        .cooldown_ms = cooldown_ms,
        .daily_limit = daily_limit,
        .now = ctx.now,
        .last_write_at = dfy.getInt(ctx.state, "lastWriteAt") orelse 0,
        .writes_today = writesToday(ctx.state, ctx.now),
        .replaces_in_flight = replacesExpiredWrite(ctx.state, ctx.now),
    });

    // 正文守门。空正文已经在 `writeRefusal` 里拦过，这里管的是「有正文但不能原样发」：
    // 含不可见字符、换行或制表符，或者超过 200 字。以前这些情况会被 `sanitize`
    // 悄悄改写后照发，发出去的那句话和用户写的那句话不是同一句。
    var line_buffer: [Guard.max_user_text * 4 + 128]u8 = undefined;
    if (refusal) |reason| {
        // A command always answers with the reason; silence would look like a
        // broken button.
        const line = std.fmt.bufPrint(&line_buffer, "{s}：{s}", .{ kind.doneLabel(), reason }) catch reason;
        try reply.say(line);
        reply.status(line, null, counter);
        return;
    }
    if (kind.needsText()) {
        if (bodyRefusal(text)) |reason| {
            const line = std.fmt.bufPrint(&line_buffer, "{s}：{s}", .{ kind.doneLabel(), reason }) catch reason;
            try reply.say(line);
            reply.status(line, null, counter);
            return;
        }
    }

    switch (try emitWrite(ctx, seq, kind, bridge, target, text)) {
        .sent => {},
        .sequence_exhausted => {
            // 序号是 i64 上限，正常一辈子撞不到；真撞上只能靠 reset 重播种，
            // 说成「地址太长」会让用户永远修不好。
            try reply.say("写入序号已经用尽，先执行 reset 重置写入序号再试。");
            reply.status("写入序号用尽", null, counter);
            return;
        },
        .no_bridge => {
            // 上游已经拦过空地址，走到这里说明配置被清掉的那一刻正好赶上，
            // 照实说「还没填地址」，不要说成「太长」。
            try reply.say("还没填桥接地址，先在面板里填上再试。");
            reply.status("缺桥接地址", null, counter);
            return;
        },
        .already_wrote => {
            // 每个事件至多一笔：命令分支与两条自动路径都已经串起来。真走到这里
            // 说明有人加了新的写入路径却没同步 `writes_this_event`，如实报「本轮
            // 已经写过」而不是「太长」。
            try reply.say("这一轮已经发过一笔写入了，下次再试。");
            reply.status("本轮已写入", null, counter);
            return;
        },
        .failed => {
            // 空地址、本事件已写过一笔都已在上游拦掉；这里主要兜住「地址或
            // 正文超出缓冲」，说清楚免得用户以为请求已经发出去了。
            try reply.say("桥接地址或正文太长，这次没发出去。");
            reply.status("写入中止", null, counter);
            return;
        },
    }

    // 回显真正发出去的那句话：用户按一次按钮就该看得见要发出去的正文原文。
    // 没有正文的动作（点赞 / 收藏 / 评论点赞）只报动作名。
    const pending = if (kind.needsText())
        std.fmt.bufPrint(&line_buffer, "正在{s}：「{s}」（逐字发送）", .{ kind.doneLabel(), text }) catch "正在写入…"
    else
        std.fmt.bufPrint(&line_buffer, "正在{s}…", .{kind.doneLabel()}) catch "正在写入…";
    reply.status(pending, null, counter);
}

fn onEvent(ctx: *dfy.Context) anyerror!void {
    const reply = ctx.reply;
    const kind = dfy.getStr(ctx.event, "type") orelse "tick";
    // 回执结算和超时重试可能落在同一轮；此时不能回头读还没被宿主合并的
    // `ctx.state`，否则刚删掉的旧 token 会被旧值复活。事件开始时只解析一次，
    // 之后结算与顶替都改这份共享名单，最后统一落回 reply。
    round_stale = StaleWrites.parse(dfy.getStr(ctx.state, "staleWrites") orelse "");
    writes_this_event = 0;
    // 时钟回拨的修正放在所有分支之前，但它改的是 `reply`，要等宿主合并 state
    // 之后才生效。本事件里的在途 / 冷却 / 自动写入读到的仍是 `ctx.state` 里那份
    // 未来值，因此照旧被拦住（`writeRefusal` 里也写明了这一点）。这不是「本事件
    // 就地修正」，而是让下一个普通事件自动恢复。
    try settleClock(ctx);

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
    // settings panel, taken byte for byte. It is deliberately **not** sanitised
    // here - `sanitize` belongs to the display channel, and quietly rewriting
    // the body would send a sentence the user never wrote. Whether the stored
    // text may go out at all is decided by `bodyRefusal` at the write gate.
    const user_comment = dfy.getStr(options, "commentText") orelse "";
    const user_reply = dfy.getStr(options, "replyText") orelse "";

    const counter = dfy.getInt(ctx.state, "counter") orelse 0;
    const seen = dfy.getList(ctx.state, "seen");
    // 序号在本次事件内只由这一处推进：`ctx.state` 要等 reply 合并后才看得到
    // 上一笔，同一次事件里连发两笔会读到同一个旧值、撞出一样的 token。
    var write_seq = dfy.getInt(ctx.state, "writeSeq") orelse 0;
    // 负数会被原样拼进 token（`write:favorite:-4`），而 `tokenSequence` 只认
    // 纯数字，之后每一笔回执都认不出动作：不计数、也不播报结果。负数一律当
    // 损坏状态从 0 重新起算。
    if (write_seq < 0) write_seq = 0;
    // `writeSeq` 被旧版本或手改写坏（缺失 / 不是整数）时 `orelse 0` 会让序号
    // 从头再来，与仍在途的那一笔撞号，旧回执就能冒充这一笔。在途 token 里
    // 读得出的序号是最低下限，用它兜住。
    if (dfy.getStr(ctx.state, "pendingWrite")) |pending_token| {
        if (tokenSequence(pending_token)) |floor| {
            if (floor > write_seq) write_seq = floor;
        }
    }
    // 超时名单同样是持久状态：序号回落时新 token 也不能复用名单上的旧序号，
    // 否则桥接重投那条旧回执会与这一笔逐字相同，被当成这一笔的成功。
    if (round_stale.maxSequence()) |floor| {
        if (floor > write_seq) write_seq = floor;
    }

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
            &write_seq,
        )) {
            return;
        }
        // "next" falls through and behaves like a tick.
    }

    if (dfy.eql(kind, "effect-result")) {
        const results = dfy.getList(ctx.event, "effects");
        const pending = dfy.getStr(ctx.state, "pendingWrite") orelse "";

        // A write came back: record it, then keep the usual rhythm going.
        const receipt: ?WriteReceipt = if (pending.len > 0) findWriteReceipt(results, pending) else null;
        if (receipt) |written| {
            // 只有和 `pendingWrite` 全等的回执才算这一笔结束。
            try reply.stateRemove("pendingWrite");
            try reply.stateRemove("writeInFlight");
            try reply.stateRemove("writeInFlightAt");
            // 同一批里也可能带回被顶替 token 的迟到回执：顺手结算名单，
            // 免得多等一轮才知道那笔到底成没成。
            const stale = try settleStaleWrites(reply, results);

            var line_buffer: [240]u8 = undefined;
            if (written.kind) |written_kind| {
                if (written.ok) |ok| {
                    if (ok) {
                        // 被顶替的旧写入已经在顶替那一刻计过数，这里只加当前这笔。
                        // 饱和到上限，理由同 `emitWrite` 里那一处。
                        const today = @min(writesToday(ctx.state, ctx.now) + 1, Guard.daily_max);
                        try reply.stateInt("writeDay", dayOf(ctx.now));
                        try reply.stateInt("writesToday", today);
                        const line = std.fmt.bufPrint(&line_buffer, "{s}好了。", .{written_kind.doneLabel()}) catch "写好了。";
                        try reply.say(line);
                        reply.status(line, null, counter);
                    } else {
                        var reason_buffer: [Guard.max_error * 4]u8 = undefined;
                        const reason = sanitize(&reason_buffer, written.reason, Guard.max_error);
                        const shown = if (reason.len == 0) "桥接没有响应" else reason;
                        const line = std.fmt.bufPrint(
                            &line_buffer,
                            "{s}失败：{s}",
                            .{ written_kind.doneLabel(), shown },
                        ) catch "写入失败。";
                        try reply.say(line);
                        reply.status(line, null, counter);
                    }
                } else {
                    // 回执在、但读不出成败：不冒充成功，也不冒充失败，但**必须
                    // 占一次额度**。不占的话，一个只回 `{id}` 不回 `ok` 的畸形
                    // 桥接可以让 `writesToday` 永远不涨，每笔都「无法确认」，
                    // 每日写入额度就静默失效了。这里饱和地加一笔，和成功回执同一口径
                    // （宁可高估）；与超时名单不同，那些条目在被顶替那一刻已经计过。
                    const line = std.fmt.bufPrint(
                        &line_buffer,
                        "{s}回执读不出结果，无法确认成败；已按占用一次每日写入额度计。",
                        .{written_kind.doneLabel()},
                    ) catch "写入回执读不出结果，无法确认。";
                    const today = @min(writesToday(ctx.state, ctx.now) + 1, Guard.daily_max);
                    try reply.stateInt("writeDay", dayOf(ctx.now));
                    try reply.stateInt("writesToday", today);
                    try reply.say(line);
                    reply.status("写入结果无法确认", null, counter);
                }
            } else {
                // 正常路径不会走到这里：`pendingWrite` 只由 `emitWrite` 写入可解析
                // 的 token。手改或跨版本留下的损坏状态走到这里时，回执已经把
                // 在途标记清掉了——这一笔确实结束了，只是认不出是哪个动作，
                // 所以不计数、不播报动作结果。
                try reply.say("这条回执认不出动作，这笔写入已结束。");
                reply.status("写入回执无法识别", null, counter);
            }
            if (stale.succeeded > 0 or stale.failed > 0 or stale.unconfirmed > 0) {
                var stale_buffer: [320]u8 = undefined;
                try reply.say(staleSettlementLine(&stale_buffer, stale));
                // 这一轮刚结算掉在途那一笔，所以只说旧账，不补「还在等回执」。
            }
            // 匹配的回执到这里就结束这一轮：同批带回的 feed 不处理，留到下一次
            // tick 再拉。否则一句话既播报写入结果、又顺手改掉快照和选择游标，
            // 用户刚点的那条视频会被新快照顶掉。代价是这次 feed 白拉了，所以
            // 排期照常，下一轮按 `interval` 再来一次。
            reply.schedule(clampSeconds(interval));
            return;
        }
        // 超时后被顶替的旧写入，回执可能迟到。被顶替时已经先计入每日写入额度，
        // 这里只确认结果：成功不重复计，失败也不退回。
        const stale = try settleStaleWrites(reply, results);
        if (stale.succeeded > 0 or stale.failed > 0 or stale.unconfirmed > 0) {
            var stale_buffer: [320]u8 = undefined;
            const line = staleSettlementLine(&stale_buffer, stale);
            try reply.say(line);
            reply.status(line, null, counter);
            // 名单上的 token 都不是在途那一笔，所以这句话只结旧账。当前这笔
            // 可能还在等回执，补一句，免得「成功了」被听成刚发出去的那笔。
            if (isWriteInFlight(ctx.state, ctx.now)) {
                try reply.say("现在这笔还在等回执。");
            }
            // 结算了旧回执的一轮也不处理同批 feed：这一轮的状态已经被改写，
            // 顺手换快照会顶掉用户选中的目标，和匹配回执那一轮同理。
            reply.schedule(clampSeconds(interval));
            return;
        }
        if (hasWriteReceipt(results)) {
            // 没有匹配到在途 token 的写回执不属于当前这一笔：上一轮迟到、同一
            // token 重复投递、0.4.1 留下的无序号回执、`reset` 之后才到的旧回执，
            // 或者干脆没有在途写入，都会走到这里。不改在途标记与计数（超时名单
            // 已在上面结算过），也不播报动作结果。它到底属于哪一笔，这里判断
            // 不出来，所以只说「不是这一笔」，不断言存在在途写入。单独到达时回
            // 一句「已忽略」；和 feed 一起回来时先照常处理推荐，免得两句话挤在
            // 同一轮。
            if (findEffect(results, "feed") == null) {
                try reply.say("这条写入回执不是这一笔的，已忽略。");
                reply.status("已忽略对不上的写入回执", null, counter);
                reply.schedule(clampSeconds(interval));
                return;
            }
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
        // 序号用尽说明插件的账本坏了，不是「这一条不该写」，所以它必须念出来，
        // 而且只念一次：回复分支已经说过之后，收藏分支不能再把同一句「写入序号
        // 用尽」重复一遍——同一轮两条一模一样的提示会让人以为发了两笔。
        var write_blocked = false;

        const auto_reply_wanted = auto_reply
            and allow_writes
            and bridge.len > 0
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
                .target_suspect = auto_reply_suspect,
                .target_len = auto_reply_target.len,
                .needs_text = true,
                .text_len = user_reply.len,
                .in_flight = isWriteInFlight(ctx.state, ctx.now),
                .cooldown_ms = cooldown_ms,
                .daily_limit = daily_limit,
                .now = ctx.now,
                .last_write_at = dfy.getInt(ctx.state, "lastWriteAt") orelse 0,
                .writes_today = writesToday(ctx.state, ctx.now),
                .replaces_in_flight = replacesExpiredWrite(ctx.state, ctx.now),
            });
            // Same guard as the commands: a refusal here is silent, because the
            // user did not press anything.
            if (refusal == null) {
                // 自动路径的正文同样过 `bodyRefusal`：设置里那句原文不合规就
                // 不写，一个字也不改。静默是有代价的——用户开了自动回复却永远
                // 等不到，会以为插件坏了——所以这里留一行状态，指明手动执行
                // `reply` 能看到具体原因。
                if (bodyRefusal(user_reply) == null) {
                    switch (try emitWrite(ctx, &write_seq, .reply, bridge, auto_reply_target, user_reply)) {
                        .sent => wrote_this_round = true,
                        // 序号用尽与「请求拼不出来」是两回事：前者唯一的出口是
                        // `reset`，静默按「没发出去」处理会让用户永远等不到恢复。
                        .sequence_exhausted => {
                            try reply.say("自动回复没发出去：写入序号已经用尽，先执行 reset 重置写入序号。");
                            reply.status("写入序号用尽", null, counter + 1);
                            write_blocked = true;
                        },
                        .failed, .no_bridge, .already_wrote => reply.status("自动回复没发出去", null, counter + 1),
                    }
                } else {
                    reply.status("自动回复没发出去：设置里的回复正文不合规，手动执行一次 reply 会说明原因", null, counter + 1);
                    // 正文不合规同样是「这一条不该写」：不能再让同一轮的自动
                    // 收藏接着发，否则就违反一条视频最多一笔自动写入。
                    write_blocked = true;
                }
            }
        }

        if (!wrote_this_round
            and !write_blocked
            and auto_favorite
            and allow_writes
            and bridge.len > 0
            and best_score >= Guard.auto_interest_score
            and !video_suspect) {
            const refusal = writeRefusal(.{
                .allow = allow_writes,
                .target_valid = validId(item_id),
                .target_proven = provenVideo(items, item_id),
                .target_suspect = video_suspect,
                .target_len = item_id.len,
                .needs_text = false,
                .text_len = 0,
                .in_flight = isWriteInFlight(ctx.state, ctx.now),
                .cooldown_ms = cooldown_ms,
                .daily_limit = daily_limit,
                .now = ctx.now,
                .last_write_at = dfy.getInt(ctx.state, "lastWriteAt") orelse 0,
                .writes_today = writesToday(ctx.state, ctx.now),
                .replaces_in_flight = replacesExpiredWrite(ctx.state, ctx.now),
            });
            if (refusal == null) {
                switch (try emitWrite(ctx, &write_seq, .favorite, bridge, item_id, "")) {
                    .sent => {},
                    .sequence_exhausted => {
                        try reply.say("自动收藏没发出去：写入序号已经用尽，先执行 reset 重置写入序号。");
                        reply.status("写入序号用尽", null, counter + 1);
                    },
                    .failed, .no_bridge, .already_wrote => reply.status("自动收藏没发出去", null, counter + 1),
                }
            }
        }
        // The chain only continues if we ask for it: without this the plug-in
        // would stop after the very first clip.
        reply.schedule(clampSeconds(interval));
        return;
    }

    // tick / next 要拼请求地址，到这一步才必须知道桥接在哪。上面的命令和回执
    // 归属都不依赖它：桥接地址被清空时，回执照样能结束在途，不会把下一笔写入
    // 卡到超时。
    if (bridge.len == 0) {
        reply.status("等待配置桥接地址", null, counter);
        reply.schedule(60_000);
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
