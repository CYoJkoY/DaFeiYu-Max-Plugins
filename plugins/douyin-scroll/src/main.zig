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
//!   `command`（或明确开启的自动收藏 / 自动回复） → `writeRefusal` 与 `bodyRefusal`
//!   都通过 → 发出请求（正文只可能是用户手写原文；`like` / `favorite` /
//!   `comment-like` 不带正文）。
//!
//! 守门规则见 `WriteContext`：开关、目标格式 / 来源证明 / 可疑标记、在途写入、
//! 每日写入额度（含顶替预留）、冷却；正文它只看「有没有」——空正文在这里就被
//! 拦下，来源由调用点保证。「这句正文能不能原样发出去」是另一项，由
//! `bodyRefusal` 判，它只看不改。只要有一项不满足就拒绝。命令路径会把拒绝理由
//! 念给用户听——按钮是你按的，你得知道为什么没动静；自动路径对普通拒绝保持
//! 安静，`tick` 抓回来的一句话不该替你在桌面上嚷「每日写入额度用完了」。两个
//! 例外都由调用点处理：正文不合规只留一行状态，提示用户手动执行命令看具体
//! 原因；「写入序号用尽」才念出来——那不是「这一条不该写」，而是插件的写入
//! 账本坏了，恢复动作必须说出来。两条路径共用同一份守门，没有哪条能绕过去。
//!
//! ## 提示词注入的防线与正文通道
//!
//! 1. 结构上：写请求的目标 id 必须同时「格式合法」且「在最近一次抓取的快照里」
//!    出现过——`videoIds` / `commentIds` / `replyIds` 就是来源证明，桥接文本
//!    伪造不出一个写目标。发送文本只能来自设置项里用户自己敲的原文，逐字发送，
//!    绝不拼接 feed 内容。`browse` / `pick` / `comments` 这些选择命令只认编号，
//!    不认内容。
//! 2. 文本上：所有来自桥接的文本在交给桌宠之前都过 `sanitize` —— 去掉控制
//!    符、零宽字符（emoji 组合符除外）、软连字符、双向控制符、行分隔符、空白
//!    填充符与 Unicode 标签字符，空白压成单空格并按字符数截断；再过
//!    `looksLikeInjection` 打标记——检测前先归一化（全角折半角、常见西里尔 /
//!    希腊同形字折拉丁、跳过组合符与组合标记、去掉空白与标点压成紧凑视图），
//!    「忽 略 之 前」、「Ｉｇｎｏｒｅ ｐｒｅｖｉｏｕｓ」、用同形字拼的样本，
//!    以及往词中间塞 ZWJ、变体选择符或组合标记的写法同样命中。带标记的
//!    条目**默认不念正文**（作者名一起拦），只报「疑似注入，已拦下」；唯一的
//!    例外是用户显式发的 `peek`，见第 4 条。被标记的条目仍然永远不能触发自动
//!    收藏或自动回复。
//! 3. 传出正文上：`commentText` / `replyText` 走 `bodyRefusal` —— 只判定能否
//!    原样发送（不含控制符、零宽字符、软连字符、双向控制符、行分隔符、空白
//!    填充符或 Unicode 标签字符，不换行 / 回车 / 制表符，至少有一个可见字符，
//!    不超过 200 字），不合规就拒发并说明理由；两条通道的规则为什么故意不同，
//!    理由只写在 `bodyRefusal` 那一段。
//! 4. 出口上：被拦下的内容只有一个出口——用户显式发 `peek`。它读的是快照里
//!    那份净化副本（最多 200 字），念之前对着**当前**快照重新核一遍标记，快照
//!    换了一轮就不再认旧指针；念出来的句子照样只是素材，不参与任何判定，也
//!    绝不会进入写请求。
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
    /// 可疑条目额外留一份更长的净化文本，专供 `peek`：播报上限只有 60 字，
    /// 一行攻击句往往看不全。作者名同理：播报副本只有 24 字，可疑时也按这个
    /// 上限另存一份。只有可疑条目才写这两份，快照体积不随正常 feed 增长。
    const peek_chars: usize = 200;
    /// 所有可疑节点的 `peekText` / `peekAuthor` 合计最多占这么多 JSON 输出。
    /// 这个额度要给标题、作者、链接、评论、回复和来源 id 留出空间；否则
    /// 最坏情况下基础快照本身再加副本就会推过宿主的 48KB state 上限。预算
    /// 超出后不再追加副本；可疑标记仍在，只是 `peek` 展示不到那段原因。
    const peek_budget_bytes: usize = 4_000;
};

const SayBuilder = struct {
    buffer: [1_600]u8 = undefined,
    used: usize = 0,
    chars: usize = 0,
    /// 一句话的字数上限。`peek` 的预留宽度与这里的上限绑定，两者一起算。
    const max_chars: usize = 400;

    fn append(self: *SayBuilder, text: []const u8) void {
        if (text.len == 0) return;
        var view = std.unicode.Utf8View.init(text) catch return;
        var iterator = view.iterator();
        var count: usize = 0;
        while (iterator.nextCodepoint() != null) count += 1;
        if (self.chars + count > max_chars or self.used + text.len > self.buffer.len) return;
        @memcpy(self.buffer[self.used .. self.used + text.len], text);
        self.used += text.len;
        self.chars += count;
    }

    fn slice(self: *const SayBuilder) []const u8 {
        return self.buffer[0..self.used];
    }

    /// 还能再念多少字：给随后的固定字符（引号、`@` 之类）留出 `reserve`。
    fn room(self: *const SayBuilder, reserve: usize) usize {
        if (self.chars + reserve >= max_chars) return 0;
        return max_chars - self.chars - reserve;
    }

    /// 念一段可能装不下的文本：超额就按字截断并补「…」，而不是让 `append`
    /// 把整段静默丢掉——作者名被吞掉时，「可疑的是作者名」会变成一句没有
    /// 名字的话。`reserve` 是随后还要写的固定字符数，连「…」一起预留。
    ///
    /// 调用方保证 `text` 是合法 UTF-8（`peekTargetOf` 已经用 `clipChars` 验过
    /// 整段序列）；万一还是撞上坏字节，就什么都不念，绝不把非法的整段丢给
    /// `append`——它自己会静默丢弃，结果一样，但这里写明白意图。
    fn appendClipped(self: *SayBuilder, text: []const u8, reserve: usize) void {
        const budget = self.room(reserve + 1);
        if (budget == 0) return;
        var i: usize = 0;
        var chars: usize = 0;
        while (i < text.len and chars < budget) {
            const size = std.unicode.utf8ByteSequenceLength(text[i]) catch return;
            if (i + size > text.len) return;
            _ = std.unicode.utf8Decode(text[i .. i + size]) catch return;
            i += size;
            chars += 1;
        }
        if (i >= text.len) {
            self.append(text);
            return;
        }
        self.append(text[0..i]);
        self.append("…");
    }
};

/// Hard limits of the write guard. None of these is read from settings.
const Guard = struct {
    /// Target ids: the bridge's own identifier alphabet, nothing else.
    const max_id: usize = 64;
    /// 用户手写的评论文本上限（字符）。
    const max_user_text: usize = 200;
    /// 桥接文本进入桌宠嘴里之前的截断（字符）。`peek` 另有一份 200 字的
    /// 副本，见 `Snapshot.peek_chars`；这个 60 只管正常播报。
    const max_feed_text: usize = 60;
    const max_author: usize = 24;
    const max_url: usize = 300;
    const max_error: usize = 60;
    const daily_min: i64 = 1;
    const daily_max: i64 = 50;
    // `_s` 是设置项里的秒数上下限，`_ms` 是内部按毫秒算的时长；两者别相加。
    const cooldown_min_s: i64 = 10;
    const cooldown_max_s: i64 = 600;
    /// 写入发出后等回执的上限；超时视为回执丢失，解除在途锁定，免得一次
    /// 丢包把写入永久锁死。冷却照常生效，所以超时后的重试仍可能被冷却拦住。
    /// 这个窗口只管在途：时钟回拨（当前时间早于发出时间）不去判过期，而是
    /// 由 `settleClock` 把时间戳重锚到当前时间，并按在途继续拦住——最多让
    /// 用户多等一个窗口。时钟往前跳超过这个窗口只是让在途放行，冷却按自己的
    /// `cooldown_ms` 独立计算（配到 600 秒时比这个窗口长），所以前跳 130 秒、
    /// 冷却 600 秒时在途已过期、冷却仍然拦得住。
    const in_flight_timeout_ms: i64 = 120_000;
    /// 自动写入的许可只看**兴趣命中**，热度与点赞只用来挑选、排序，换不来一次
    /// 写入。阈值取标题命中一个兴趣词的得分：作者名命中只有 600，够不到这条线，
    /// 所以「作者名里恰好带个词」不会替你写。
    const auto_interest_score: f64 = 2_000;
    /// 超时重试时被顶替的旧 token 名单上限。名单只用于事后识别回执并播报
    /// 结果；每日写入额度在被顶替那一刻就计数，所以名单再丢也不会放宽封顶。
    const stale_write_max: usize = 3;
    /// 拒绝理由的缓冲：最长一条是「正文超过 200 字，守门已拒绝写入，先改短再
    /// 试」，按 UTF-8 计约 62 字节；留到 96 是给字数上限改成四位数时也不至于溢出。
    const refusal_reason_capacity: usize = 96;
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

/// 滚动窗口的长度：最长的一条标记是 "ignorealltheprevious"（20 字节），留到
/// 32 连「全角折半角 + 同形字折拉丁」之后的形式也放得下。
const marker_window: usize = 32;

/// 输入超过这么多个字节就直接判可疑。展示通道最多念 60 字，`peek` 的净化副本
/// 最多留 200 字（UTF-8 下至多 800 字节），正常内容远远到不了 8 KB。不设「扫到
/// 第几个码点就收工」的位置额度：那种额度要么按原始码点算，凭空塞空白、组合符
/// 就能把攻击句推出额度之外；要么按会被念出来的码点算，规则一多又会重新出现
/// 「扫到的部分算干净、没扫到的尾巴也算干净」的缝。超出上限整条拦下，就不存在
/// 没扫到的尾巴。
const max_detect_bytes: usize = 8 * 1024;

/// 全角 ASCII（U+FF01–U+FF5E）折成半角，全角空格折成普通空格（与 `isBlank`
/// 的口径对齐）。折叠只作用于检测视图，绝不改写要展示、要发送的文本。
fn foldWidth(cp: u21) u21 {
    if (cp >= 0xFF01 and cp <= 0xFF5E) return cp - 0xFEE0;
    if (cp == 0x3000) return ' ';
    return cp;
}

/// 常见同形字：西里尔与希腊字母里和拉丁字母形状一致的那些。这张表覆盖不了
/// 所有同形字（数学字母、亚美尼亚语、各种符号变体都还在），它只是把「看着
/// 像英文的句子」也拉进比对，不承担全部保证——真正的保证是写操作的来源证明。
fn foldHomoglyph(cp: u21) u21 {
    return switch (cp) {
        0x0430, 0x0410 => 'a',
        0x0435, 0x0415 => 'e',
        0x043E, 0x041E => 'o',
        0x0440, 0x0420 => 'p',
        0x0441, 0x0421 => 'c',
        0x0445, 0x0425 => 'x',
        0x0443 => 'y',
        0x0456, 0x0406 => 'i',
        0x0458 => 'j',
        0x0455 => 's',
        0x04CF => 'l',
        0x03B1 => 'a',
        0x03B5 => 'e',
        0x03BF => 'o',
        0x03C1 => 'p',
        0x03C7 => 'x',
        0x03B9 => 'i',
        0x03BA => 'k',
        0x03BD => 'v',
        0x03C4 => 't',
        0x03C5 => 'u',
        else => cp,
    };
}

/// 标点与符号类：紧凑视图里不要它们，「忽 略，之 前」才能压回「忽略之前」。
/// 变体选择符（U+FE00–U+FE0F）走不到这条判断：`isProjectionSkip` 在投影前就
/// 把它们跳过了，这里的 FE00–FE1F 区间只兜竖向排版形式（U+FE10–U+FE1F）。
/// 全角 ASCII（U+FF01–U+FF5E）在 `foldWidth` 里已经折成半角、也走不到这条
/// 判断，所以这里的全角区只留折不掉的半角标点（U+FF5F–U+FF65）。
fn isSymbolOrPunct(cp: u21) bool {
    return (cp >= 0x2000 and cp <= 0x206F)
        or (cp >= 0x2190 and cp <= 0x2BFF)
        or (cp >= 0x2E00 and cp <= 0x2E7F)
        or (cp >= 0x3000 and cp <= 0x303F)
        or (cp >= 0xFE00 and cp <= 0xFE1F)
        or (cp >= 0xFE30 and cp <= 0xFE6F)
        or (cp >= 0xFF5F and cp <= 0xFF65)
        or (cp >= 0x1F000 and cp <= 0x1FAFF);
}

/// 紧凑视图的一个码点：字母与数字留下（ASCII 转小写、全角折半角、同形字折
/// 拉丁），空白、标点、符号与 emoji 全部丢掉。`忽 略 之 前`、
/// `Ｉｇｎｏｒｅ ｐｒｅｖｉｏｕｓ`、`ignоre.previous` 在这张视图上是同一句话。
fn compactCodepoint(cp: u21) ?u21 {
    const folded = foldHomoglyph(foldWidth(cp));
    // 空白必须先挡掉：U+00A0 / U+1680 / U+202F / U+205F 都在 0x80 以上，
    // 不在这里拦就会留在紧凑视图里，把「ignore previous」拆成两段反而更
    // 容易漏判；`isBlank` 定义在后面，Zig 允许前向引用。
    if (isBlank(folded)) return null;
    if (folded < 0x80) {
        const byte: u8 = @intCast(folded);
        return if (std.ascii.isAlphanumeric(byte)) std.ascii.toLower(byte) else null;
    }
    return if (isSymbolOrPunct(folded)) null else folded;
}

/// 形状视图的一个码点：全角折半角、同形字折拉丁、ASCII 小写化，标点与符号
/// 原样保留——`http://`、`system:`、反引号这类标记靠形状本身识别，紧凑视图
/// 会把它们压没。空白由调用点压成单个空格。
fn shapedCodepoint(cp: u21) u21 {
    const folded = foldHomoglyph(foldWidth(cp));
    if (folded < 0x80) return std.ascii.toLower(@intCast(folded));
    return folded;
}

/// 只保留最后 `tail.len` 个字节：标记都比窗口短，判定「刚喂进来的字符有没有
/// 凑齐一个标记」只需要这段尾巴。整段文本因此是常数内存的线性扫描，多长的
/// 标题都不会把栈撑爆。
fn pushTail(tail: []u8, used: *usize, bytes: []const u8) void {
    if (bytes.len >= tail.len) {
        @memcpy(tail, bytes[bytes.len - tail.len ..]);
        used.* = tail.len;
        return;
    }
    if (used.* + bytes.len > tail.len) {
        const drop = used.* + bytes.len - tail.len;
        std.mem.copyForwards(u8, tail[0 .. used.* - drop], tail[drop..used.*]);
        used.* -= drop;
    }
    @memcpy(tail[used.* .. used.* + bytes.len], bytes);
    used.* += bytes.len;
}

/// 尾巴是否以任一标记结尾。标记的比对按「喂进来一个码点就看一眼」的方式做，
/// 所以它等价于「这段文本里出现过这个（归一化后的）子串」。
fn endsWithAny(tail: []const u8, markers: []const []const u8) bool {
    for (markers) |marker| {
        if (std.mem.endsWith(u8, tail, marker)) return true;
    }
    return false;
}

/// 折叠后仍长成词的标记，在紧凑视图上比对：词间空格、标点、全角与常见同形字
/// 都已经吃掉了，所以拆开写的变体照样命中。中文只收「忽略 / 无视 + 前文」、
/// 「你的新指令」「从现在起你」与「泄露系统提示」这几族；英文只收
/// 「ignore / forget / disregard + previous / above」与「换系统提示」两族。
///
/// 宁可漏掉一种绕法，也不能把日常文案整条吞掉：`disregard`、`新的指令`、
/// `系统指令`、`覆盖之前`、`忽略所有` 这类裸词每天都在正常标题里出现
/// （「我 disregard 了他的建议」「Linux 常用系统指令合集」「我妈说忽略所有的
/// 烦恼」），收进来只会把一条正常内容判成注入；它们必须带上「前文 / 系统提示
/// 词」这类搭配才算数。
const compact_markers = [_][]const u8{
    "忽略之前", "忽略以上", "忽略前面", "忽略上述",
    "无视之前", "无视以上", "无视上述", "无视前面",
    "系统提示词", "你的新指令", "你现在扮演", "从现在起你", "从现在开始你",
    "泄露提示词", "泄露系统提示",
    "ignoreprevious", "ignoretheprevious", "ignoreabove", "ignoretheabove",
    "ignoreallprevious", "ignorealltheprevious",
    "forgetprevious", "forgetallprevious", "forgeteverything",
    "disregardprevious", "disregardabove", "disregardallprevious",
    "disregardtheprevious", "disregardtheabove",
    "systemprompt", "developerprompt",
};

/// 形状本身就是特征的标记：冒号、斜杠、反引号、尖括号是它们的一部分，压成
/// 紧凑视图就没了，所以单独在形状视图上比对。
const shaped_markers = [_][]const u8{
    "assistant:", "system:", "developer:", "javascript:", "data:text/html",
    "http://", "https://", "<script", "```", "tool_call", "function_call",
    "post /", "get /",
};

/// 这段桥接文本像不像提示词注入。两道判定：
///
/// 1. 任何一个看不见的字符（控制符、零宽、双向、标签字符……）本身就是可疑
///    信号，直接命中；
/// 2. 归一化之后再看两遍：紧凑视图上比对长成词的标记，形状视图上比对靠标点
///    成形的标记。组合符（emoji 组合符、组合变音符）不参与投影——它们不承载
///    字符，留在视图里只会把词拆开，让 `sys+ZWJ+tem:` 这种写法躲过 `system:`。
///
/// 两张视图都只是「比对用的投影」，从不展示、从不发送。写守门不读它们：它看
/// 的是开关、目标 id 的格式与来源证明、目标的「可疑标记」，以及用户手写的正文
/// （`bodyRefusal` 只判定、不改写）。
fn looksLikeInjection(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text.len > max_detect_bytes) return true;
    var view = std.unicode.Utf8View.init(text) catch return true;
    var iterator = view.iterator();
    var compact_tail: [marker_window]u8 = undefined;
    var compact_used: usize = 0;
    var shaped_tail: [marker_window]u8 = undefined;
    var shaped_used: usize = 0;
    var pending_space = false;
    while (iterator.nextCodepoint()) |raw| {
        if (isInvisible(raw)) return true;
        if (isProjectionSkip(raw)) continue;
        if (isBlank(foldWidth(raw))) {
            // 置位而不是立刻写空格：连续空白在形状视图里只留一个空格，和
            // `sanitize` 念出来的样子一致。
            if (shaped_used > 0) pending_space = true;
            continue;
        }
        var encoded: [4]u8 = undefined;
        if (compactCodepoint(raw)) |cp| {
            const size: usize = std.unicode.utf8Encode(cp, &encoded) catch 0;
            pushTail(&compact_tail, &compact_used, encoded[0..size]);
            if (endsWithAny(compact_tail[0..compact_used], &compact_markers)) return true;
        }
        const shaped = shapedCodepoint(raw);
        if (pending_space) {
            pushTail(&shaped_tail, &shaped_used, " ");
            pending_space = false;
        }
        const size: usize = std.unicode.utf8Encode(shaped, &encoded) catch 0;
        pushTail(&shaped_tail, &shaped_used, encoded[0..size]);
        if (endsWithAny(shaped_tail[0..shaped_used], &shaped_markers)) return true;
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
/// The author side is capped at one hit: several interests matching the handle
/// must not add up into a title-sized score, or a creator with a lucky name
/// would be auto-favorited with no keyword in the title at all.
fn interestScore(interests: []const dfy.Value, title: []const u8, author: []const u8) f64 {
    var score: f64 = 0;
    var author_counted = false;
    for (interests) |interest| {
        if (!isString(interest)) continue;
        const word = interest.string;
        if (word.len == 0) continue;
        if (std.mem.indexOf(u8, title, word) != null) score += 2_000;
        if (!author_counted and std.mem.indexOf(u8, author, word) != null) {
            author_counted = true;
            score += 600;
        }
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
// 文本通道：展示清洗与发送守门
// ---------------------------------------------------------------------------

/// Characters that carry no visible glyph but can carry meaning: C0/C1
/// controls, zero-width spaces and joiners, bidi overrides (the classic "hide
/// the real sentence" trick), Unicode tag characters (a whole ASCII payload can
/// ride in them invisibly), line and paragraph separators, the Mongolian vowel
/// separator, the blank-rendering fillers that make text look empty while it is
/// not, the soft hyphen, and the Arabic letter mark (the bidi control that is
/// easy to miss when only the U+200x range is filtered).
///
/// Emoji combiners are deliberately absent: U+200D joins a family emoji and
/// U+FE00..U+FE0F picks how a glyph is drawn, neither carries a payload, and
/// rejecting them would refuse the most ordinary hand-written reply (a red
/// heart is U+2764 U+FE0F). They still do not count as visible content - see
/// `isCombiner`.
fn isInvisible(cp: u21) bool {
    return switch (cp) {
        0x00...0x1F, 0x7F...0x9F => true,
        0x00AD => true,
        0x061C => true,
        0x115F...0x1160 => true,
        0x180E => true,
        0x200B...0x200C, 0x200E...0x200F => true,
        0x2028...0x2029 => true,
        0x202A...0x202E => true,
        0x2060...0x206F => true,
        0x2800 => true,
        0x3164 => true,
        0xFEFF => true,
        0xFFA0 => true,
        0xFFF9...0xFFFB => true,
        0xE0000...0xE007F => true,
        else => false,
    };
}

/// Emoji combiners: they shape the character before them instead of adding
/// text of their own. Safe to send verbatim (the user typed them), but they are
/// not content either - a body made only of these would render as nothing.
fn isCombiner(cp: u21) bool {
    return cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F);
}

/// 组合标记：Unicode `General_Category=Mark`（Mn / Mc / Me）的全部码点，按属性
/// 数据生成、已排序且互不重叠。它们不承载独立字符，只决定前一个字形怎么画；留在
/// 投影里就能把 `ignore` 拆成 `igno` + U+064E + `re`，让紧凑视图拼不出
/// `ignoreprevious`、形状视图拼不出 `system:`。手抄区块表会漏掉泰文、老挝文、
/// 藏文、缅甸文、高棉文这些能插在拉丁字母之间的标记，也会把同段里的可见标点
/// 一起吞掉，所以这里直接收全量属性表，不做「主要区块」近似。
///
/// 只用于检测投影：`sanitize` 不删它们（那不是不可见字符），`bodyRefusal` 也不拦
/// 用户手打的组合标记。
fn isCombiningMark(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = mark_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = mark_ranges[mid];
        if (cp < range[0]) {
            hi = mid;
        } else if (cp > range[1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// `General_Category=Mark` 的全部区间（Unicode 18.0 属性数据，333 个区间）。表是照
/// `extracted/DerivedGeneralCategory.txt` 里 Mn / Mc / Me 三段生成的，不是手挑区块。
/// 下面列举的是 Unicode 18.0 相对 17.0 新增的**码点**（12 段、共 37 个）：U+05C8..
/// U+05C9、U+0B53..U+0B54、U+1ADE..U+1ADF、U+1AEC..U+1AF0、U+10ECB..U+10ECF、
/// U+10EF0..U+10EF9、U+11DF0、U+1D127..U+1D128、U+1D250..U+1D252、U+1D25B..U+1D25C、
/// U+1D25F、U+1D280..U+1D281。表里有些区间是和 17.0 已有的相邻区**合并**成一条的，
/// 所以不跟上面逐条对应：U+05C8..U+05C9 并进 `.{ 0x05C7, 0x05C9 }`，U+0B53..U+0B54
/// 并进 `.{ 0x0B53, 0x0B57 }`，U+1ADE..U+1AF0 并进 `.{ 0x1AB0, 0x1AF0 }`，
/// U+10EF0..U+10EF9 并进 `.{ 0x10EF0, 0x10EFF }`（紧接 17.0 已有的 U+10EFA..U+10EFF）。
/// 写宽或写窄都算错：`test-plugin.ts` 按码点穷举表内每一段，并探每段两侧的相邻码点，
/// 多收一个就会在「sys<cp>tem:」上误命中。下次 Unicode 再添 Mark，穷举 check 会点名
/// 没覆盖到的码点，照着补进来即可。
const mark_ranges = [_][2]u21{
    .{ 0x0300, 0x036F }, .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05BD }, .{ 0x05BF, 0x05BF },
    .{ 0x05C1, 0x05C2 }, .{ 0x05C4, 0x05C5 }, .{ 0x05C7, 0x05C9 }, .{ 0x0610, 0x061A },
    .{ 0x064B, 0x065F }, .{ 0x0670, 0x0670 }, .{ 0x06D6, 0x06DC }, .{ 0x06DF, 0x06E4 },
    .{ 0x06E7, 0x06E8 }, .{ 0x06EA, 0x06ED }, .{ 0x0711, 0x0711 }, .{ 0x0730, 0x074A },
    .{ 0x07A6, 0x07B0 }, .{ 0x07EB, 0x07F3 }, .{ 0x07FD, 0x07FD }, .{ 0x0816, 0x0819 },
    .{ 0x081B, 0x0823 }, .{ 0x0825, 0x0827 }, .{ 0x0829, 0x082D }, .{ 0x0859, 0x085B },
    .{ 0x0897, 0x089F }, .{ 0x08CA, 0x08E1 }, .{ 0x08E3, 0x0903 }, .{ 0x093A, 0x093C },
    .{ 0x093E, 0x094F }, .{ 0x0951, 0x0957 }, .{ 0x0962, 0x0963 }, .{ 0x0981, 0x0983 },
    .{ 0x09BC, 0x09BC }, .{ 0x09BE, 0x09C4 }, .{ 0x09C7, 0x09C8 }, .{ 0x09CB, 0x09CD },
    .{ 0x09D7, 0x09D7 }, .{ 0x09E2, 0x09E3 }, .{ 0x09FE, 0x09FE }, .{ 0x0A01, 0x0A03 },
    .{ 0x0A3C, 0x0A3C }, .{ 0x0A3E, 0x0A42 }, .{ 0x0A47, 0x0A48 }, .{ 0x0A4B, 0x0A4D },
    .{ 0x0A51, 0x0A51 }, .{ 0x0A70, 0x0A71 }, .{ 0x0A75, 0x0A75 }, .{ 0x0A81, 0x0A83 },
    .{ 0x0ABC, 0x0ABC }, .{ 0x0ABE, 0x0AC5 }, .{ 0x0AC7, 0x0AC9 }, .{ 0x0ACB, 0x0ACD },
    .{ 0x0AE2, 0x0AE3 }, .{ 0x0AFA, 0x0AFF }, .{ 0x0B01, 0x0B03 }, .{ 0x0B3C, 0x0B3C },
    .{ 0x0B3E, 0x0B44 }, .{ 0x0B47, 0x0B48 }, .{ 0x0B4B, 0x0B4D }, .{ 0x0B53, 0x0B57 },
    .{ 0x0B62, 0x0B63 }, .{ 0x0B82, 0x0B82 }, .{ 0x0BBE, 0x0BC2 }, .{ 0x0BC6, 0x0BC8 },
    .{ 0x0BCA, 0x0BCD }, .{ 0x0BD7, 0x0BD7 }, .{ 0x0C00, 0x0C04 }, .{ 0x0C3C, 0x0C3C },
    .{ 0x0C3E, 0x0C44 }, .{ 0x0C46, 0x0C48 }, .{ 0x0C4A, 0x0C4D }, .{ 0x0C55, 0x0C56 },
    .{ 0x0C62, 0x0C63 }, .{ 0x0C81, 0x0C83 }, .{ 0x0CBC, 0x0CBC }, .{ 0x0CBE, 0x0CC4 },
    .{ 0x0CC6, 0x0CC8 }, .{ 0x0CCA, 0x0CCD }, .{ 0x0CD5, 0x0CD6 }, .{ 0x0CE2, 0x0CE3 },
    .{ 0x0CF3, 0x0CF3 }, .{ 0x0D00, 0x0D03 }, .{ 0x0D3B, 0x0D3C }, .{ 0x0D3E, 0x0D44 },
    .{ 0x0D46, 0x0D48 }, .{ 0x0D4A, 0x0D4D }, .{ 0x0D57, 0x0D57 }, .{ 0x0D62, 0x0D63 },
    .{ 0x0D81, 0x0D83 }, .{ 0x0DCA, 0x0DCA }, .{ 0x0DCF, 0x0DD4 }, .{ 0x0DD6, 0x0DD6 },
    .{ 0x0DD8, 0x0DDF }, .{ 0x0DF2, 0x0DF3 }, .{ 0x0E31, 0x0E31 }, .{ 0x0E34, 0x0E3A },
    .{ 0x0E47, 0x0E4E }, .{ 0x0EB1, 0x0EB1 }, .{ 0x0EB4, 0x0EBC }, .{ 0x0EC8, 0x0ECE },
    .{ 0x0F18, 0x0F19 }, .{ 0x0F35, 0x0F35 }, .{ 0x0F37, 0x0F37 }, .{ 0x0F39, 0x0F39 },
    .{ 0x0F3E, 0x0F3F }, .{ 0x0F71, 0x0F84 }, .{ 0x0F86, 0x0F87 }, .{ 0x0F8D, 0x0F97 },
    .{ 0x0F99, 0x0FBC }, .{ 0x0FC6, 0x0FC6 }, .{ 0x102B, 0x103E }, .{ 0x1056, 0x1059 },
    .{ 0x105E, 0x1060 }, .{ 0x1062, 0x1064 }, .{ 0x1067, 0x106D }, .{ 0x1071, 0x1074 },
    .{ 0x1082, 0x108D }, .{ 0x108F, 0x108F }, .{ 0x109A, 0x109D }, .{ 0x135D, 0x135F },
    .{ 0x1712, 0x1715 }, .{ 0x1732, 0x1734 }, .{ 0x1752, 0x1753 }, .{ 0x1772, 0x1773 },
    .{ 0x17B4, 0x17D3 }, .{ 0x17DD, 0x17DD }, .{ 0x180B, 0x180D }, .{ 0x180F, 0x180F },
    .{ 0x1885, 0x1886 }, .{ 0x18A9, 0x18A9 }, .{ 0x1920, 0x192B }, .{ 0x1930, 0x193B },
    .{ 0x1A17, 0x1A1B }, .{ 0x1A55, 0x1A5E }, .{ 0x1A60, 0x1A7C }, .{ 0x1A7F, 0x1A7F },
    .{ 0x1AB0, 0x1AF0 }, .{ 0x1B00, 0x1B04 }, .{ 0x1B34, 0x1B44 }, .{ 0x1B6B, 0x1B73 },
    .{ 0x1B80, 0x1B82 }, .{ 0x1BA1, 0x1BAD }, .{ 0x1BE6, 0x1BF3 }, .{ 0x1C24, 0x1C37 },
    .{ 0x1CD0, 0x1CD2 }, .{ 0x1CD4, 0x1CE8 }, .{ 0x1CED, 0x1CED }, .{ 0x1CF4, 0x1CF4 },
    .{ 0x1CF7, 0x1CF9 }, .{ 0x1DC0, 0x1DFF }, .{ 0x20D0, 0x20F0 }, .{ 0x2CEF, 0x2CF1 },
    .{ 0x2D7F, 0x2D7F }, .{ 0x2DE0, 0x2DFF }, .{ 0x302A, 0x302F }, .{ 0x3099, 0x309A },
    .{ 0xA66F, 0xA672 }, .{ 0xA674, 0xA67D }, .{ 0xA69E, 0xA69F }, .{ 0xA6F0, 0xA6F1 },
    .{ 0xA802, 0xA802 }, .{ 0xA806, 0xA806 }, .{ 0xA80B, 0xA80B }, .{ 0xA823, 0xA827 },
    .{ 0xA82C, 0xA82C }, .{ 0xA880, 0xA881 }, .{ 0xA8B4, 0xA8C5 }, .{ 0xA8E0, 0xA8F1 },
    .{ 0xA8FF, 0xA8FF }, .{ 0xA926, 0xA92D }, .{ 0xA947, 0xA953 }, .{ 0xA980, 0xA983 },
    .{ 0xA9B3, 0xA9C0 }, .{ 0xA9E5, 0xA9E5 }, .{ 0xAA29, 0xAA36 }, .{ 0xAA43, 0xAA43 },
    .{ 0xAA4C, 0xAA4D }, .{ 0xAA7B, 0xAA7D }, .{ 0xAAB0, 0xAAB0 }, .{ 0xAAB2, 0xAAB4 },
    .{ 0xAAB7, 0xAAB8 }, .{ 0xAABE, 0xAABF }, .{ 0xAAC1, 0xAAC1 }, .{ 0xAAEB, 0xAAEF },
    .{ 0xAAF5, 0xAAF6 }, .{ 0xABE3, 0xABEA }, .{ 0xABEC, 0xABED }, .{ 0xFB1E, 0xFB1E },
    .{ 0xFE00, 0xFE0F }, .{ 0xFE20, 0xFE2F }, .{ 0x101FD, 0x101FD }, .{ 0x102E0, 0x102E0 },
    .{ 0x10376, 0x1037A }, .{ 0x10A01, 0x10A03 }, .{ 0x10A05, 0x10A06 }, .{ 0x10A0C, 0x10A0F },
    .{ 0x10A38, 0x10A3A }, .{ 0x10A3F, 0x10A3F }, .{ 0x10AE5, 0x10AE6 }, .{ 0x10D24, 0x10D27 },
    .{ 0x10D69, 0x10D6D }, .{ 0x10EAB, 0x10EAC }, .{ 0x10ECB, 0x10ECF }, .{ 0x10EF0, 0x10EFF },
    .{ 0x10F46, 0x10F50 }, .{ 0x10F82, 0x10F85 }, .{ 0x11000, 0x11002 }, .{ 0x11038, 0x11046 },
    .{ 0x11070, 0x11070 }, .{ 0x11073, 0x11074 }, .{ 0x1107F, 0x11082 }, .{ 0x110B0, 0x110BA },
    .{ 0x110C2, 0x110C2 }, .{ 0x11100, 0x11102 }, .{ 0x11127, 0x11134 }, .{ 0x11145, 0x11146 },
    .{ 0x11173, 0x11173 }, .{ 0x11180, 0x11182 }, .{ 0x111B3, 0x111C0 }, .{ 0x111C9, 0x111CC },
    .{ 0x111CE, 0x111CF }, .{ 0x1122C, 0x11237 }, .{ 0x1123E, 0x1123E }, .{ 0x11241, 0x11241 },
    .{ 0x112DF, 0x112EA }, .{ 0x11300, 0x11303 }, .{ 0x1133B, 0x1133C }, .{ 0x1133E, 0x11344 },
    .{ 0x11347, 0x11348 }, .{ 0x1134B, 0x1134D }, .{ 0x11357, 0x11357 }, .{ 0x11362, 0x11363 },
    .{ 0x11366, 0x1136C }, .{ 0x11370, 0x11374 }, .{ 0x113B8, 0x113C0 }, .{ 0x113C2, 0x113C2 },
    .{ 0x113C5, 0x113C5 }, .{ 0x113C7, 0x113CA }, .{ 0x113CC, 0x113D0 }, .{ 0x113D2, 0x113D2 },
    .{ 0x113E1, 0x113E2 }, .{ 0x11435, 0x11446 }, .{ 0x1145E, 0x1145E }, .{ 0x114B0, 0x114C3 },
    .{ 0x115AF, 0x115B5 }, .{ 0x115B8, 0x115C0 }, .{ 0x115DC, 0x115DD }, .{ 0x11630, 0x11640 },
    .{ 0x116AB, 0x116B7 }, .{ 0x1171D, 0x1172B }, .{ 0x1182C, 0x1183A }, .{ 0x11930, 0x11935 },
    .{ 0x11937, 0x11938 }, .{ 0x1193B, 0x1193E }, .{ 0x11940, 0x11940 }, .{ 0x11942, 0x11943 },
    .{ 0x119D1, 0x119D7 }, .{ 0x119DA, 0x119E0 }, .{ 0x119E4, 0x119E4 }, .{ 0x11A01, 0x11A0A },
    .{ 0x11A33, 0x11A39 }, .{ 0x11A3B, 0x11A3E }, .{ 0x11A47, 0x11A47 }, .{ 0x11A51, 0x11A5B },
    .{ 0x11A8A, 0x11A99 }, .{ 0x11B60, 0x11B67 }, .{ 0x11C2F, 0x11C36 }, .{ 0x11C38, 0x11C3F },
    .{ 0x11C92, 0x11CA7 }, .{ 0x11CA9, 0x11CB6 }, .{ 0x11D31, 0x11D36 }, .{ 0x11D3A, 0x11D3A },
    .{ 0x11D3C, 0x11D3D }, .{ 0x11D3F, 0x11D45 }, .{ 0x11D47, 0x11D47 }, .{ 0x11D8A, 0x11D8E },
    .{ 0x11D90, 0x11D91 }, .{ 0x11D93, 0x11D97 }, .{ 0x11DF0, 0x11DF0 }, .{ 0x11EF3, 0x11EF6 },
    .{ 0x11F00, 0x11F01 }, .{ 0x11F03, 0x11F03 }, .{ 0x11F34, 0x11F3A }, .{ 0x11F3E, 0x11F42 },
    .{ 0x11F5A, 0x11F5A }, .{ 0x13440, 0x13440 }, .{ 0x13447, 0x13455 }, .{ 0x1611E, 0x1612F },
    .{ 0x16AF0, 0x16AF4 }, .{ 0x16B30, 0x16B36 }, .{ 0x16F4F, 0x16F4F }, .{ 0x16F51, 0x16F87 },
    .{ 0x16F8F, 0x16F92 }, .{ 0x16FE4, 0x16FE4 }, .{ 0x16FF0, 0x16FF1 }, .{ 0x1BC9D, 0x1BC9E },
    .{ 0x1CF00, 0x1CF2D }, .{ 0x1CF30, 0x1CF46 }, .{ 0x1D127, 0x1D128 }, .{ 0x1D165, 0x1D169 },
    .{ 0x1D16D, 0x1D172 }, .{ 0x1D17B, 0x1D182 }, .{ 0x1D185, 0x1D18B }, .{ 0x1D1AA, 0x1D1AD },
    .{ 0x1D242, 0x1D244 }, .{ 0x1D250, 0x1D252 }, .{ 0x1D25B, 0x1D25C }, .{ 0x1D25F, 0x1D25F },
    .{ 0x1D280, 0x1D281 }, .{ 0x1DA00, 0x1DA36 }, .{ 0x1DA3B, 0x1DA6C }, .{ 0x1DA75, 0x1DA75 },
    .{ 0x1DA84, 0x1DA84 }, .{ 0x1DA9B, 0x1DA9F }, .{ 0x1DAA1, 0x1DAAF }, .{ 0x1E000, 0x1E006 },
    .{ 0x1E008, 0x1E018 }, .{ 0x1E01B, 0x1E021 }, .{ 0x1E023, 0x1E024 }, .{ 0x1E026, 0x1E02A },
    .{ 0x1E08F, 0x1E08F }, .{ 0x1E130, 0x1E136 }, .{ 0x1E2AE, 0x1E2AE }, .{ 0x1E2EC, 0x1E2EF },
    .{ 0x1E4EC, 0x1E4EF }, .{ 0x1E5EE, 0x1E5EF }, .{ 0x1E6E3, 0x1E6E3 }, .{ 0x1E6E6, 0x1E6E6 },
    .{ 0x1E6EE, 0x1E6EF }, .{ 0x1E6F5, 0x1E6F5 }, .{ 0x1E8D0, 0x1E8D6 }, .{ 0x1E944, 0x1E94A },
    .{ 0xE0100, 0xE01EF },

};

/// 检测投影里整个跳过的码点：emoji 组合符与组合标记都不承载字符，只改前一个
/// 字符的字形。留在视图里会白白把词拆开——`sys` 夹一个 ZWJ 再接 `tem:` 时，
/// 紧凑视图只剩半截词（ZWJ 被标点过滤掉，`systemprompt` 这类标记拼不出来），
/// 形状视图又因为多出那个 ZWJ 拼不出 `system:`。跳过之后两张视图都回到「人眼
/// 看到的那个词」。只用于检测投影：`sanitize` 保留组合符（emoji 才不会散架），
/// `bodyRefusal` 放行用户手打的组合符，两者都不经过这里。
fn isProjectionSkip(cp: u21) bool {
    return isCombiner(cp) or isCombiningMark(cp);
}

/// Whitespace, including the Unicode space separators. `bodyRefusal` uses it to
/// answer "is there at least one visible character at all"; `sanitize` uses it
/// to fold runs of whitespace into one space. Leaving the separator block out
/// would let a body made only of U+2003 (em space) pass as "visible" and be
/// posted verbatim - the bridge would reject it as empty after the write had
/// already taken the cooldown.
fn isBlank(cp: u21) bool {
    return cp == ' ' or cp == '\t' or cp == '\n' or cp == '\r'
        or cp == 0x00A0 or cp == 0x1680
        or (cp >= 0x2000 and cp <= 0x200A)
        or cp == 0x202F or cp == 0x205F or cp == 0x3000;
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
/// `scratch` 只用来拼「超过多少字」那一条，调用点给一块几十字节的栈缓冲就够。
/// 返回 null 表示可以逐字发送，否则返回拒绝理由（命令路径念给用户听）。
fn bodyRefusal(text: []const u8, scratch: []u8) ?[]const u8 {
    var view = std.unicode.Utf8View.init(text) catch return "正文不是有效的 UTF-8，守门已拒绝写入";
    var it = view.iterator();
    var chars: usize = 0;
    var saw_visible = false;
    while (it.nextCodepoint()) |cp| {
        chars += 1;
        // 换行与制表符单独说：它们在 `isInvisible` 里也算控制符，但「不能换行」
        // 是用户能直接改的一条，说成「不可见字符」只会让人去猜。
        if (cp == '\n' or cp == '\r' or cp == '\t') return "正文不能换行或带制表符，守门已拒绝写入";
        if (isInvisible(cp)) return "正文里有不可见字符，守门已拒绝写入";
        // 组合符（ZWJ、变体选择符）放行但不算内容：只有它们时照样是「没有
        // 可见字符」，不能靠它们凑出一句空正文发出去。
        if (!isBlank(cp) and !isCombiner(cp)) saw_visible = true;
    }
    // 全空白正文在桥接侧会被当成空评论退回来（400），冷却照占、额度不占，
    // 理由见 `isBlank`；首尾空格是用户写的原文，所以只拦「一个可见字符都没有」。
    if (!saw_visible) return "正文只有空白，守门已拒绝写入";
    if (chars > Guard.max_user_text) {
        return std.fmt.bufPrint(
            scratch,
            "正文超过 {d} 字，守门已拒绝写入，先改短再试",
            .{Guard.max_user_text},
        ) catch "正文超过上限，守门已拒绝写入，先改短再试";
    }
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

/// Escape one string into a JSON string body. Callers hand in either a target
/// id that already passed `validId` (ASCII alphanumerics, `_` and `-` only) or
/// the body that already passed `bodyRefusal` (valid UTF-8, no control
/// characters); either gate leaves only the two structural characters to
/// escape, so a quote in the user's own text can never break out of the JSON
/// document.
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
/// does not speak it (sequence exhaustion excepted). A refused body is not this
/// function's business: `bodyRefusal` handles it — the command path speaks that
/// reason, the automatic path leaves a status line.
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

/// 可疑标记与 `peek` 副本一起写。标记对正文和作者名各算一次，任一命中整条
/// 算可疑；命中时再分开记 `suspectBody` / `suspectAuthor`，`peek` 才知道该把
/// 哪一部分当可疑内容标出来——副本截到 200 字，标记可能正好落在截断之外，
/// 只靠副本重扫会漏。作者名的播报副本只有 24 字（`Guard.max_author`），命中
/// 点完全可能在其后，所以作者名也单独留一份 200 字净本（`peekAuthor`）：
/// 否则 `peek` 会念一段干净前缀，用户看不到触发原因。
/// 副本还要受 `Snapshot.peek_budget_bytes` 总量约束：先到先得，超出预算的可疑
/// 节点只留标记，不再堆副本。
fn writeSuspect(writer: *dfy.Json, raw_text: []const u8, raw_author: []const u8) !void {
    const body_suspect = looksLikeInjection(raw_text);
    const author_suspect = looksLikeInjection(raw_author);
    try writer.key("suspect");
    try writer.boolean(body_suspect or author_suspect);
    if (!body_suspect and !author_suspect) return;
    try writer.key("suspectBody");
    try writer.boolean(body_suspect);
    try writer.key("suspectAuthor");
    try writer.boolean(author_suspect);
    if (body_suspect and raw_text.len != 0) {
        var peek_buffer: [Snapshot.peek_chars * 4]u8 = undefined;
        const peek_text = sanitize(&peek_buffer, raw_text, Snapshot.peek_chars);
        const cost = jsonStringLength(peek_text);
        if (peek_budget_used + cost <= Snapshot.peek_budget_bytes) {
            peek_budget_used += cost;
            try writer.key("peekText");
            try writer.str(peek_text);
        }
    }
    if (author_suspect and raw_author.len != 0) {
        var peek_author_buffer: [Snapshot.peek_chars * 4]u8 = undefined;
        const peek_author = sanitize(&peek_author_buffer, raw_author, Snapshot.peek_chars);
        const cost = jsonStringLength(peek_author);
        if (peek_budget_used + cost <= Snapshot.peek_budget_bytes) {
            peek_budget_used += cost;
            try writer.key("peekAuthor");
            try writer.str(peek_author);
        }
    }
}

/// `Json.writeString` 会给引号、反斜杠与控制字符加转义。写入副本前先按同样
/// 规则估算输出长度，快照预算才不会被不可见字符悄悄撑爆。
fn jsonStringLength(text: []const u8) usize {
    var length: usize = 2;
    for (text) |byte| {
        length += switch (byte) {
            '"', '\\' => 2,
            '\n', '\r', '\t', 0x08, 0x0c => 2,
            else => if (byte < 0x20) 6 else 1,
        };
    }
    return length;
}

/// 只在写本轮快照时使用；每次重建快照前清零，防上一次调用的账本漏进来。
var peek_budget_used: usize = 0;

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
    try writeSuspect(writer, raw_text, raw_author);
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
    try writeSuspect(writer, raw_text, raw_author);
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
/// 标题/作者不可疑不代表评论区可信，所以标记是逐条算的；被标记的条目另外
/// 留一份 200 字的净化副本供 `peek`，正常条目只有 60 字的播报副本。
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
    try writeSuspect(writer, raw_title, raw_author);
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
    peek_budget_used = 0;
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
// 选择与查看：browse / pick / comments / peek / pick-comment / pick-reply
// ---------------------------------------------------------------------------

const withheld_note = "「疑似注入，已拦下」";
const withheld_hint = "（发 peek 看被拦下的内容）";

fn appendWithheldNote(builder: *SayBuilder) void {
    builder.append(withheld_note);
}

fn appendWithheldHint(builder: *SayBuilder) void {
    builder.append(withheld_hint);
}

/// 单条播报用这个：拦下标记 + 一句怎么查看。
fn appendWithheld(builder: *SayBuilder) void {
    appendWithheldNote(builder);
    builder.append("；");
    appendWithheldHint(builder);
}

/// 被拦下的东西分三类，`peek` 的文案要按类说清楚拦下来的是标题还是正文。
const PeekKind = enum { video, comment, reply };

fn peekName(kind: PeekKind) []const u8 {
    return switch (kind) {
        .video => "video",
        .comment => "comment",
        .reply => "reply",
    };
}

fn peekKindOfName(name: []const u8) ?PeekKind {
    if (dfy.eql(name, "video")) return .video;
    if (dfy.eql(name, "comment")) return .comment;
    if (dfy.eql(name, "reply")) return .reply;
    return null;
}

/// 记下「最近一次被拦下的是哪一条」。`browse` / `comments` 不选中任何东西，没
/// 这个指针，`peek` 就找不到用户刚看到的那条；正文与标记仍然从当前快照重读。
/// 一次调用同时写完两个键，避免同一轮里先删后写同一键。
///
/// 写入时机看调用点：`tick` 每轮按播报顺序 视频 → 评论 → 回复 重记一次，整页
/// 都没有可疑条目就清空；`browse` / `comments` 只在本页见到可疑条目时记，翻到
/// 干净的一页保留旧指针——刚记下的那条不该被一次翻页抹掉；`pick` /
/// `pick-comment` / `pick-reply` 只在选中的条目可疑时写，选中干净条目时**不写
/// 也不清**——否则用户随手选一条正常内容，刚被拦下的那条就查不到了。
fn recordWithheld(reply: *dfy.Reply, kind: ?PeekKind, id: []const u8) !void {
    // `kind == null` 是「这一轮没有可拦下的目标」，清掉旧指针。有 kind 却没
    // 有 id 是调用点自己没取到 id：写不出有效指针，也不该顺手把上一轮还查得到
    // 的那条清掉——宁可不写，让 `peek` 退回全层扫描。
    const value = kind orelse {
        try reply.stateRemove("withheldKind");
        try reply.stateRemove("withheldId");
        return;
    };
    if (id.len == 0) return;
    try reply.stateStr("withheldKind", peekName(value));
    try reply.stateStr("withheldId", id);
}

/// `browse` / `comments` 都只把**本页第一条**可疑条目留给 `peek`：后面的照样
/// 标成「已拦下」，但不再抢指针；提示也只在列表末尾补一次。两处记账逻辑一样，
/// 抽出来免得各自漏掉一个分支。
const WithheldList = struct {
    any: bool = false,
    kind: ?PeekKind = null,
    id: []const u8 = "",

    fn note(self: *WithheldList, item: dfy.Value, kind: PeekKind) void {
        self.any = true;
        if (self.kind != null) return;
        self.kind = kind;
        self.id = dfy.getStr(item, "id") orelse "";
    }

    fn appendHint(self: *const WithheldList, builder: *SayBuilder) void {
        if (!self.any) return;
        builder.append("；");
        appendWithheldHint(builder);
    }

    fn record(self: *const WithheldList, reply: *dfy.Reply) !void {
        if (self.kind) |kind| try recordWithheld(reply, kind, self.id);
    }
};

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
    // `lastReplyAuthor` / `lastReplyText` / `lastReplySuspect` 是 0.4.x 写下的
    // 副本，0.5.1 起改为每次回快照重读，这里保留删除只为清掉旧版本残留。
    try reply.stateRemove("lastReplyAuthor");
    try reply.stateRemove("lastReplyText");
    try reply.stateRemove("lastReplySuspect");
    try reply.stateRemove("replyIndex");
}

fn clearCommentSelection(reply: *dfy.Reply) !void {
    try reply.stateRemove("lastCommentId");
    // 同上：评论正文与标记的副本已不再写入，只清理旧版本留下的键。
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
    // `browse` 不选中任何东西，被拦下的条目要当场记下来，`peek` 才有目标；
    // 只记本页第一条，后面的可疑条目照样列出来，但不再抢 `peek` 的位置。
    var withheld = WithheldList{};
    var index = start;
    while (index < stop) : (index += 1) {
        const item = videos[index];
        const title = dfy.getStr(item, "title") orelse "";
        const author = dfy.getStr(item, "author") orelse "";
        const suspect = dfy.getBool(item, "suspect") orelse false;
        var index_buffer: [24]u8 = undefined;
        const prefix = std.fmt.bufPrint(&index_buffer, "{d}.", .{index + 1}) catch continue;
        if (suspect) {
            builder.append(prefix);
            appendWithheldNote(&builder);
            withheld.note(item, .video);
        } else {
            // 标题 60 字、作者 24 字都是**字**不是字节：最坏 4 字节一个码点，
            // 加上「」与 `@`，240 + 96 + 6 = 342 字节。按这个上限留足，否则
            // `bufPrint` 失败会让前缀变成孤零零的序号。
            var entry_buffer: [Guard.max_feed_text * 4 + Guard.max_author * 4 + 16]u8 = undefined;
            const entry = std.fmt.bufPrint(
                &entry_buffer,
                "「{s}」@{s}",
                .{
                    if (title.len == 0) @as([]const u8, "（无标题）") else title,
                    if (author.len == 0) @as([]const u8, "未知作者") else author,
                },
            ) catch continue;
            builder.append(prefix);
            builder.append(entry);
        }
        if (index + 1 < stop) builder.append("；");
    }
    withheld.appendHint(&builder);
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, counter);
    try reply.stateInt("browsePage", @intCast(page));
    // 这一页没有可疑条目就保持上一次的指针不动：翻页翻到干净的一页，不该顺手
    // 把刚记下的那条清掉。
    try withheld.record(reply);
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
    var withheld = WithheldList{};
    var index: usize = 0;
    while (index < comments.len) : (index += 1) {
        const item = comments[index];
        const text = dfy.getStr(item, "text") orelse "";
        const author = dfy.getStr(item, "author") orelse "";
        const suspect = dfy.getBool(item, "suspect") orelse false;
        var index_buffer: [24]u8 = undefined;
        const prefix = std.fmt.bufPrint(&index_buffer, "{d}.", .{index + 1}) catch continue;
        if (suspect) {
            builder.append(prefix);
            appendWithheldNote(&builder);
            withheld.note(item, .comment);
        } else {
            // 评论正文准入上限是 300 字节，作者名 24 字最坏 96 字节，再加
            // 「」与 `@`。留足后 `bufPrint` 不会失败，序号也就不会落单。
            var entry_buffer: [Snapshot.max_comment_bytes + Guard.max_author * 4 + 16]u8 = undefined;
            const entry = std.fmt.bufPrint(
                &entry_buffer,
                "「{s}」@{s}",
                .{
                    if (text.len == 0) @as([]const u8, "（空）") else text,
                    if (author.len == 0) @as([]const u8, "未知作者") else author,
                },
            ) catch continue;
            builder.append(prefix);
            builder.append(entry);
        }
        if (index + 1 < comments.len) builder.append("；");
    }
    withheld.appendHint(&builder);
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, counter);
    try clearCommentSelection(reply);
    try withheld.record(reply);
}

/// `peek` 的候选目标：正文按条目类型兜底，作者统一兜底成「未知作者」。
/// `body_suspect` / `author_suspect` 分开记，因为作者名单独中招时念法不同：
/// 正文照常引，作者名要单独标成「作者名」而不是当成正文的一部分。
const PeekTarget = struct {
    kind: PeekKind,
    label: []const u8,
    text: []const u8,
    author: []const u8,
    body_suspect: bool,
    author_suspect: bool,
    /// `body_suspect or author_suspect`，外加快照自己记的标记：快照副本已经
    /// 截过，标记可能正好落在截断之外，不能因为副本没再命中就把它当正常内容。
    suspect: bool,
};

fn peekLabel(kind: PeekKind) []const u8 {
    return switch (kind) {
        .video => "视频标题",
        .comment => "评论正文",
        .reply => "回复正文",
    };
}

fn peekEmpty(kind: PeekKind) []const u8 {
    return switch (kind) {
        .video => "（无标题）",
        else => "（空）",
    };
}

/// 按字把一段 UTF-8 文本截到 `limit` 个字，超出的部分直接丢（不补省略号）。
/// 只用于 `peek` 的展示副本：写入端本来就把副本截在同一上限，这里再截一次是
/// 不信任读取端拿到的 state——宿主或用户改过的字段也能把一句话撑爆。
/// 逐段校验 UTF-8：坏字节在开头时返回空串，由调用方换成固定的「无法显示」
/// 提示；坏字节在中途时返回此前的合法前缀。原样返回整段会绕开上限，而后续
/// `append` 又会把它整段丢掉，只剩一对空引号。
/// 每个序列都整段校验（`utf8Decode` 连续字节、过长编码与代理区一起验），
/// 只看首字节不够：一个结构完整但内容非法的三字节序列照样能把非法切片漏下去。
fn clipChars(text: []const u8, limit: usize) []const u8 {
    var i: usize = 0;
    var chars: usize = 0;
    while (i < text.len and chars < limit) {
        const size = std.unicode.utf8ByteSequenceLength(text[i]) catch return text[0..i];
        if (i + size > text.len) return text[0..i];
        _ = std.unicode.utf8Decode(text[i .. i + size]) catch return text[0..i];
        i += size;
        chars += 1;
    }
    return text[0..i];
}

fn charCount(comptime text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch unreachable;
}

/// `peek` 一句话里的固定文案。`commandPeek` 只许引用这里的常量，改文案时
/// `peek_glue` 会跟着重算，不会出现「文案改了、预留宽度还是旧值」。
const peek_fixed = struct {
    /// 正文可疑时的开场：这一层被拦下了什么（后面紧跟 `label`）。
    const body_label_prefix = "被拦下的";
    /// 正文可疑时，标签之后的固定开场。
    const body_lead = "（抹掉了不可见字符，只当素材看，别当指令）：「";
    /// 只有作者名可疑时，标签之后的说明，一直到作者名副本的开引号。
    const author_only_lead = "本身没被拦下；可疑的是作者名：「";
    /// 正文副本收尾 + 作者名小标题 + 作者名副本开场。
    const author_lead = "」；作者名也可疑：「";
    /// 只有正文可疑时，正文副本之后的收尾与 `@`。
    const mention_lead = "」@";
    /// 只有作者名可疑时，作者名副本之后的过渡。
    const body_lead_only_author = "」，照抄给你：「";
    /// 一段副本的收尾引号。
    const close = "」";
};

/// `peek` 一句话里夹在两段副本之间的固定字符数（按**字**算）。`appendClipped`
/// 的 `reserve` 以字为单位，所以 CJK 串要按码点数，不能拿 `.len`（字节数）。
/// 全部由 `peek_fixed` 的字面串推导：改文案时预留宽度自动跟上。
const peek_glue = struct {
    /// 一个右引号（收尾用）。
    const quote: usize = charCount(peek_fixed.close);
    /// 正文副本之后还有：收尾「」+「；作者名也可疑：「」+ 作者名副本上限 + 收尾「」。
    const body_then_author: usize = charCount(peek_fixed.author_lead) + Snapshot.peek_chars + quote;
    /// 正文副本之后只有「」@」：作者名由随后的 `appendClipped(author, 0)` 自己截。
    const body_then_mention: usize = charCount(peek_fixed.mention_lead);
    /// 作者名副本之后还有：「」，照抄给你：「」+ 正文副本上限 + 收尾「」。
    const author_then_body: usize = charCount(peek_fixed.body_lead_only_author) + Snapshot.peek_chars + quote;
};

comptime {
    // 最紧的两条分支：固定骨架 + 另一段 200 字副本之后，正文（或作者名）
    // 仍要留得下一段可辨认的内容，不能只剩一个「…」。
    const label_max = 4; // 「视频标题」「评论正文」「回复正文」
    const body_prefix = charCount(peek_fixed.body_label_prefix) + label_max + charCount(peek_fixed.body_lead);
    if (SayBuilder.max_chars - body_prefix - peek_glue.body_then_author < 20) {
        @compileError("peek 两段都可疑时正文预算过窄");
    }
    const author_prefix = label_max + charCount(peek_fixed.author_only_lead);
    if (SayBuilder.max_chars - author_prefix - peek_glue.author_then_body < 20) {
        @compileError("peek 只作者名可疑时作者名预算过窄");
    }
    // 第三条分支（正文可疑、作者名干净）撑不满 400，但要保证正文副本之后
    // 的「」@」一定留在句子里，作者名才不会被挤成空。
    const mention_prefix = body_prefix + Snapshot.peek_chars;
    if (mention_prefix + peek_glue.body_then_mention > SayBuilder.max_chars) {
        @compileError("peek 只有正文可疑时收尾「」@」放不下");
    }
}

/// `peek` 副本不是合法 UTF-8 时的占位说明（宿主或用户改坏了 state）。
const peek_unreadable = "（副本不是合法 UTF-8，无法显示）";

/// `peek` 读的正文：可疑条目在快照里另存了一份更长的净化文本（`peekText`），
/// 正常条目只有播报用的那份（`text`）。两份都过过 `sanitize`，所以念出来
/// 不带不可见字符——这里给的是「被拦下的那句话」，不是原始字节。`peek` 这个
/// 旧键名是字段与命令撞名的遗留，0.5.0 的快照里还可能有，读一次兜底。
///
/// 视频条目从来只写 `title`，升级前的快照也没有上面三个副本键：这时必须退回
/// 标题，否则会一边说「拦下的是视频标题」一边念「（无标题）」，把它自己说成
/// 什么都没拦下。评论与回复没有这个兜底——它们的正文键就是 `text`。
fn peekBody(item: dfy.Value, kind: PeekKind) []const u8 {
    if (dfy.getStr(item, "peekText")) |body| return body;
    if (dfy.getStr(item, "peek")) |body| return body;
    if (dfy.getStr(item, "text")) |body| return body;
    if (kind == .video) return dfy.getStr(item, "title") orelse "";
    return "";
}

/// 从快照里的一条拼出 `peek` 目标。快照里的标记是**抓取那一刻**用完整原文算
/// 的，比截过的副本可靠：写入时分开记的 `suspectBody` / `suspectAuthor` 优先。
/// 副本只有前 60 字（播报用）与前 200 字（`peek` 用），命中点可能落在副本之外，
/// 所以存下来的 `true` 一律按可疑保留——它是按完整原文算出来的，把它当噪声忽略
/// 只会放过副本外面的注入。重扫副本只能**补**上漏标的命中，不能用来否定抓取时的
/// 结论。
///
/// 旧快照缺拆分字段时没有「正文可疑 / 作者可疑」的分工——作者名可疑并不排除
/// 正文也可疑，正文副本又可能截在命中点之前——所以只能退回「整条可疑即正文也可
/// 疑」：宁可多标一句被拦下，也不能反过来断言「正文本身没被拦下」。
///
/// 判定读原文，展示只读截到 `Snapshot.peek_chars` 的副本：`say` 一句话 400 字，
/// 两段副本各自最多 200 字，骨架再挤就念不下了。写入端本来就把副本截在同一
/// 上限，这里重截是为了不让被改过的 state（宿主或用户本人）把 `peek` 撑爆。
fn peekTargetOf(item: dfy.Value, kind: PeekKind) ?PeekTarget {
    if (item != .object) return null;
    const raw_body = peekBody(item, kind);
    // 作者名优先读可疑时另存的 200 字副本：播报副本只有 24 字，命中点可能
    // 落在其后。旧快照没有 `peekAuthor`，退回 24 字的 `author`。
    const raw_author = dfy.getStr(item, "peekAuthor") orelse dfy.getStr(item, "author") orelse "";
    const stored = dfy.getBool(item, "suspect") orelse false;
    const split_body = dfy.getBool(item, "suspectBody");
    const split_author = dfy.getBool(item, "suspectAuthor");
    // 拆分字段由插件成对写入。规则分两层：
    //
    // 1. 任何一个存在的 `true` 都必须算数——它只可能来自抓取时对完整原文的
    //    命中，副本之外看不看得见都不影响这条结论。只有 `suspectBody:true` 而
    //    `suspectAuthor` 缺失时，正文仍要按可疑处理，不能被整条 `suspect`
    //    的旧值盖过去。
    // 2. 只有两个字段都在、且不自相矛盾时，才承认其中的 `false` 是抓取时的
    //    结论。单独的 `suspectBody:false` 不能给整条 `suspect:true` 免死；两个
    //    都在却都说 `false` 而整条仍可疑，说明 state 被改过，同样不认。
    //
    // 不认 `false` 时正文退回整条 `suspect`：宁可多标一句被拦下，也不能反过来
    // 断言「正文本身没被拦下」。作者名没有可靠的整条兜底（整条可疑可能只因为
    // 正文），所以只在字段为 `true` 或副本重扫命中时才算可疑。
    const paired = split_body != null and split_author != null;
    const contradicted = paired and !(split_body.? or split_author.?) and stored;
    const trust_false = paired and !contradicted;
    const author_suspect = (split_author orelse false) or looksLikeInjection(raw_author);
    const body_suspect = (if (split_body) |flag| (flag or (!trust_false and stored)) else stored)
        or looksLikeInjection(raw_body);
    const body_view = clipChars(raw_body, Snapshot.peek_chars);
    const author_view = clipChars(raw_author, Snapshot.peek_chars);
    return .{
        .kind = kind,
        .label = peekLabel(kind),
        .text = if (raw_body.len == 0) peekEmpty(kind) else if (body_view.len == 0) peek_unreadable else body_view,
        .author = if (raw_author.len == 0) "未知作者" else if (author_view.len == 0) peek_unreadable else author_view,
        .body_suspect = body_suspect,
        .author_suspect = author_suspect,
        .suspect = stored or body_suspect or author_suspect,
    };
}

/// 按 id 在**当前**快照里找回条目。评论与回复要扫全部视频：`lastCommentId`
/// 只在选中它那条视频的评论区里成立，而 `peek` 的目标可能来自 `comments`
/// 命令（选中视频不变）或上一轮 tick。
///
/// 同一 id 在快照里出现多次时取**第一条**（`findById` 按顺序返回首个匹配）；
/// 快照本身不按 id 去重，桥接重复喂同一个 id 时以先出现的那条为准。
fn findInSnapshot(state: dfy.Value, kind: PeekKind, id: []const u8) ?dfy.Value {
    if (id.len == 0) return null;
    if (kind == .video) return findById(snapshotItems(state), id);
    for (snapshotItems(state)) |video| {
        if (video != .object) continue;
        const comments = dfy.getList(video, "comments");
        if (kind == .comment) {
            if (findById(comments, id)) |hit| return hit;
            continue;
        }
        for (comments) |comment| {
            if (comment != .object) continue;
            if (findById(dfy.getList(comment, "replies"), id)) |hit| return hit;
        }
    }
    return null;
}

const PeekScan = struct {
    /// 至少有一个可查看的目标，哪怕它没被拦下。
    any: bool,
    /// 第一个被拦下的目标；`null` 表示这轮没有可念的拦下内容。
    withheld: ?PeekTarget,
};

/// 由近及远扫「回复 → 评论 → 视频」，返回第一个**可疑**的目标。最近一层
/// 干净不代表别的层也干净：刚挑了一条干净回复时，被拦下的评论仍然要给出来。
fn scanPeek(state: dfy.Value) PeekScan {
    var scan = PeekScan{ .any = false, .withheld = null };
    const layers = [_]struct { kind: PeekKind, key: []const u8 }{
        .{ .kind = .reply, .key = "lastReplyId" },
        .{ .kind = .comment, .key = "lastCommentId" },
        .{ .kind = .video, .key = "lastId" },
    };
    for (layers) |layer| {
        const id = dfy.getStr(state, layer.key) orelse "";
        const item = findInSnapshot(state, layer.kind, id) orelse continue;
        const target = peekTargetOf(item, layer.kind) orelse continue;
        scan.any = true;
        if (target.suspect) {
            scan.withheld = target;
            return scan;
        }
    }
    return scan;
}

/// 只有用户显式发 `peek` 才把被拦下的正文念出来，而且它仍然只是素材：
/// 这段文字不参与任何判定，也绝不会进入写请求。目标按「回复 → 评论 → 视频」
/// 由近及远解析，`suspect` 从当前快照重新读——state 里那份副本只说明上一次
/// 选中时看到过什么，快照换了一轮就不再可信。
///
/// `browse` / `comments` 不选中任何东西，所以先看本轮记下的那条；它和选中
/// 目标一样要回快照里重新核对，找不到或已经不可疑就退回全层扫描。
fn commandPeek(ctx: *dfy.Context, counter: i64) !void {
    const reply = ctx.reply;
    var any = false;
    var withheld: ?PeekTarget = null;
    const recorded_kind = peekKindOfName(dfy.getStr(ctx.state, "withheldKind") orelse "");
    const recorded_id = dfy.getStr(ctx.state, "withheldId") orelse "";
    if (recorded_kind) |kind| {
        if (findInSnapshot(ctx.state, kind, recorded_id)) |item| {
            if (peekTargetOf(item, kind)) |target| {
                any = true;
                if (target.suspect) withheld = target;
            }
        }
    }
    if (withheld == null) {
        const scanned = scanPeek(ctx.state);
        any = any or scanned.any;
        withheld = scanned.withheld;
    }
    const target = withheld orelse {
        if (any) {
            try reply.say("这条没有被拦下的内容。");
            reply.status("这条没有被拦下", null, counter);
        } else {
            try reply.say("没有可查看的目标，先 pick 一条。");
            reply.status("没有可查看的目标", null, counter);
        }
        return;
    };
    var builder = SayBuilder{};
    if (target.body_suspect) {
        builder.append(peek_fixed.body_label_prefix);
        builder.append(target.label);
        builder.append(peek_fixed.body_lead);
        if (target.author_suspect) {
            // 正文与作者名各中一部分：分开念，别混成一句话。
            builder.appendClipped(target.text, peek_glue.body_then_author);
            builder.append(peek_fixed.author_lead);
            builder.appendClipped(target.author, peek_glue.quote);
            builder.append(peek_fixed.close);
        } else {
            builder.appendClipped(target.text, peek_glue.body_then_mention);
            builder.append(peek_fixed.mention_lead);
            builder.appendClipped(target.author, 0);
        }
    } else {
        // 正文本身干净，被拦下的只是作者名：说清拦的是哪一部分，正文照抄。
        builder.append(target.label);
        builder.append(peek_fixed.author_only_lead);
        builder.appendClipped(target.author, peek_glue.author_then_body);
        builder.append(peek_fixed.body_lead_only_author);
        builder.appendClipped(target.text, peek_glue.quote);
        builder.append(peek_fixed.close);
    }
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, counter);
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
        // 旧版本在这里留下了标题 / 作者 / 可疑标记的副本，0.5.0 还额外写下
        // `lastFetchAt` 与 `available` 两个没人读的计数；0.5.1 起只认快照、那两个
        // 计数也不再写，这几条删除保留，专门清理旧版本留下的键。
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
        try recordWithheld(reply, null, "");
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
    if (dfy.eql(name, "peek")) {
        try commandPeek(ctx, counter);
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
    if (suspect) {
        appendWithheld(&builder);
    } else {
        builder.append("「");
        builder.append(if (title.len == 0) "（无标题）" else title);
        builder.append("」@");
        builder.append(if (author.len == 0) "未知作者" else author);
    }
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, dfy.getInt(ctx.state, "counter") orelse 0);

    try reply.stateStr("lastId", id);
    if (dfy.getStr(item, "url")) |url| {
        if (isHttpsUrl(url)) try reply.stateStr("lastUrl", url);
    }
    try reply.stateInt("pickIndex", @intCast(index));
    try clearCommentSelection(reply);
    // 选中的是可疑条目，才把指针给 `peek`；干净条目不动指针——选中一条正常
    // 视频不该把刚被拦下的那条从 `peek` 里抹掉。
    if (suspect) try recordWithheld(reply, .video, id);
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
    if (suspect) {
        appendWithheld(&builder);
    } else {
        builder.append("「");
        builder.append(text);
        builder.append("」@");
        builder.append(if (author.len == 0) "未知作者" else author);
    }
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, dfy.getInt(ctx.state, "counter") orelse 0);

    try reply.stateStr("lastCommentId", id);
    try reply.stateInt("commentIndex", @intCast(index));
    try clearReplySelection(reply);
    if (suspect) try recordWithheld(reply, .comment, id);
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
    if (suspect) {
        appendWithheld(&builder);
    } else {
        builder.append("「");
        builder.append(text);
        builder.append("」@");
        builder.append(if (author.len == 0) "未知作者" else author);
    }
    try reply.say(builder.slice());
    reply.status(builder.slice(), null, dfy.getInt(ctx.state, "counter") orelse 0);

    try reply.stateStr("lastReplyId", id);
    try reply.stateInt("replyIndex", @intCast(index));
    if (suspect) try recordWithheld(reply, .reply, id);
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
/// 会被说成「桥接地址太长」，用户根本无从恢复。`no_bridge` 与 `already_wrote`
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
    // `.failed`——它的文案是「地址太长」，会指错方向。这里先单独回
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

/// 写守门的目标判定：把当前快照里那条内容重新拼成 `peek` 目标再取 `suspect`，
/// 而不是盲信 state 里孤零零的一个布尔值。副本重扫只能补上漏标的命中；存下来的
/// `true` 照样按可疑拦住（见 `peekTargetOf`），所以旧版本、状态迁移或手改状态把
/// 标记改成 false，也放不出副本里仍带注入特征的内容。找不到目标、或者目标读不出
/// 内容时一律按可疑拦住。
fn targetIsSuspect(state: dfy.Value, kind: WriteKind) bool {
    const video_id = dfy.getStr(state, "lastId") orelse "";
    const video = findById(snapshotItems(state), video_id) orelse return true;
    if (kind != .reply and kind != .comment_like) {
        return (peekTargetOf(video, .video) orelse return true).suspect;
    }
    const comment_id = dfy.getStr(state, "lastCommentId") orelse "";
    const comment = findById(dfy.getList(video, "comments"), comment_id) orelse return true;
    const reply_id = dfy.getStr(state, "lastReplyId") orelse "";
    if (kind == .comment_like or reply_id.len == 0) {
        return (peekTargetOf(comment, .comment) orelse return true).suspect;
    }
    const selected_reply = findById(dfy.getList(comment, "replies"), reply_id) orelse return true;
    return (peekTargetOf(selected_reply, .reply) orelse return true).suspect;
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

    // 这一行缓冲既装拒绝行也装发送回显。拒绝行只有「动作名：理由」，理由最多
    // 96 字节、写在 `reason_buffer` 里；真正撑尺寸的是下面的发送回显
    // 「正在{动作}：「{正文}」（逐字发送）」，正文最多 200 字 × 4 字节。按最坏
    // 情况开满，回显才不会被截断。
    var line_buffer: [Guard.max_user_text * 4 + 128]u8 = undefined;
    var reason_buffer: [Guard.refusal_reason_capacity]u8 = undefined;
    // 正文守门：空正文已经在 `writeRefusal` 里拦过，这里管「有正文但不能原样发」。
    const reason: ?[]const u8 = if (refusal) |r|
        r
    else if (kind.needsText())
        bodyRefusal(text, &reason_buffer)
    else
        null;
    if (reason) |r| {
        // A command always answers with the reason; silence would look like a
        // broken button.
        const line = std.fmt.bufPrint(&line_buffer, "{s}：{s}", .{ kind.doneLabel(), r }) catch r;
        try reply.say(line);
        reply.status(line, null, counter);
        return;
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
            // 空地址、本事件已写过一笔、超长正文都已在上游拦掉；拼请求时还能
            // 撑爆缓冲的就只剩桥接地址，说清楚免得用户以为请求已经发出去了。
            try reply.say("桥接地址太长，这次没发出去。");
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
                        // 失败理由也来自桥接，和 feed 文本一样可能被喂进攻击句；
                        // 命中就只说一句「已拦下」，不把原文念出来。
                        const shown = if (reason.len == 0)
                            "桥接没有响应"
                        else if (looksLikeInjection(written.reason))
                            "理由像注入样本，已拦下"
                        else
                            reason;
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
                    // 桥接可以让 `writesToday` 永远不涨，每笔都「无法确认」，每日
                    // 写入额度就静默失效了。饱和加一的理由同 `emitWrite` 那一处。
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
            const raw_reason = dfy.getStr(feed, "error") orelse "桥接没有响应";
            var reason_buffer: [Guard.max_error * 4]u8 = undefined;
            const reason = sanitize(&reason_buffer, raw_reason, Guard.max_error);
            var buffer: [200]u8 = undefined;
            // 桥接的错误理由同样是不可信输入：命中注入特征就只说「已拦下」。
            const line = if (looksLikeInjection(raw_reason))
                "刷不动了：桥接返回的理由像注入样本，已拦下"
            else
                std.fmt.bufPrint(&buffer, "刷不动了：{s}", .{reason}) catch "刷不动了。";
            reply.status(line, null, counter);
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
        try reply.stateInt("browsePage", -1);

        var best: ?dfy.Value = null;
        var best_score: f64 = -1e18;
        // 兴趣分单独记一份：`best_score` 只管「挑哪条给你看」，写不写由兴趣本身
        // 决定。两者混在一起时，热度或点赞一旦越过阈值就等于自动写，违背
        // 「只认命中兴趣」。加权开着时两种写法等价：挑选分是热度（封顶 1_000）
        // 加兴趣分，而作者名那条最多只计一次 600，够不到 2_000，所以只有标题
        // 命中才可能过线。加权关掉时挑选只剩热度，闸门读的仍是被挑中那条的
        // 兴趣分，也就是只有它自己命中标题才会写。旧写法会把「排序开关」连带
        // 变成「写入开关」，那不是这个开关该管的事。
        var best_interest: f64 = 0;
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
            const interest = interestScore(interests, title, author);
            // `interestBoost` 只是排序权重：关掉它就不再按兴趣给推荐加分，但
            // 「这条命中兴趣」是内容本身的事实，自动写入的许可不跟着关。
            var score = hotScore(item);
            if (boost) score += interest;
            if (score > best_score) {
                best_score = score;
                best_interest = interest;
                best = item;
            }
        }

        const picked = best orelse {
            // 这一轮一个字都不念，也没有评估任何一层（视频 / 评论 / 回复）的
            // 可疑标记：指针**不能**在这里清空。快照虽然换过一轮，但同一批
            // 已见条目往往还在里面；清掉指针会让 `peek` 再也找不到那条被拦下的
            // 内容。留着的指针在 `peek` 时会回新快照核对：id 不在了、或不再
            // 可疑，`peek` 自己会退回「回复 → 评论 → 视频」扫描，不会卡死。
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

        // 评论：按兴趣 + 点赞挑一条，念出来就是「评价」。只在快照保留的
        // 前 `Snapshot.comments` 条里挑，保证念到的评论一定可写。
        var best_comment: ?dfy.Value = null;
        var best_comment_score: f64 = -1e18;
        var best_comment_interest: f64 = 0;
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
            // 点赞同样折叠到 1_000 以内，理由和 `hotScore` 一样：排序分要能
            // 压住点赞数的量级差异，却不能反过来盖过兴趣命中。封顶高过 2_000
            // 时，一条一万赞的闲话会把命中兴趣的评论挤出「被念出来」的位置，
            // 于是闸门永远落在没命中兴趣的那条上——`autoReply` 等于形同虚设。
            var score: f64 = if (likes < 0) 0 else if (likes > 1_000) 1_000 else likes;
            // 评论挑选不看「兴趣加权」：那个开关管的是推荐流排序，念哪条评论
            // 只看内容本身，所以兴趣分无条件入账。
            const interest = interestScore(interests, comment_text, "");
            score += interest;
            if (score > best_comment_score) {
                best_comment_score = score;
                best_comment_interest = interest;
                best_comment = comment;
            }
        }

        // 评论可疑与否只算一次：拼播报和下面写来源证明读的是同一份结论，
        // 同一段文字不重扫。
        const comment_suspect = if (best_comment) |comment|
            looksLikeInjection(dfy.getStr(comment, "text") orelse "")
                or looksLikeInjection(dfy.getStr(comment, "author") orelse "")
        else
            false;

        var builder = SayBuilder{};
        builder.append("刷到：");
        if (video_suspect) {
            appendWithheld(&builder);
        } else {
            builder.append("「");
            builder.append(title);
            builder.append("」@");
            builder.append(author);
        }
        if (best_comment) |comment| {
            const raw_comment_text = dfy.getStr(comment, "text") orelse "";
            const raw_comment_author = dfy.getStr(comment, "author") orelse "";
            // 可疑正文一个字都不进嘴里，连标题作者也不带出来。
            builder.append("；评论：");
            if (comment_suspect) {
                appendWithheld(&builder);
            } else {
                var comment_text_buffer: [Guard.max_feed_text * 4]u8 = undefined;
                const comment_text = sanitize(
                    &comment_text_buffer,
                    raw_comment_text,
                    Guard.max_feed_text,
                );
                var comment_author_buffer: [Guard.max_author * 4]u8 = undefined;
                const comment_author = sanitize(
                    &comment_author_buffer,
                    raw_comment_author,
                    Guard.max_author,
                );
                builder.append("「");
                builder.append(comment_text);
                builder.append("」@");
                builder.append(if (comment_author.len == 0) "未知作者" else comment_author);
            }
        }
        // 本轮要记下的那一条：视频优先，其次是评论，最后才是自动回复的目标——
        // 播报先念标题，所以标题可疑时指针就停在标题上。回复的正文本身不进播报
        // （它只是自动回复的对象），被拦下时靠 `peek` 才看得到。`peek` 的回退
        // 扫描方向相反（由近及远 回复 → 评论 → 视频），两者不冲突：指针先查，
        // 查不到才扫描。指针在这一轮重记，三类都不可疑才清空；`browse` /
        // `comments` 与选择命令只在真的遇上可疑条目时才写，不会替这里刷新指针。
        var withheld_kind: ?PeekKind = null;
        var withheld_id: []const u8 = "";
        var video_evaluated = false;
        var comment_evaluated = false;
        var reply_evaluated = false;
        if (video_suspect) {
            withheld_kind = .video;
            withheld_id = item_id;
        }
        video_evaluated = true;
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
        if (isHttpsUrl(url)) try reply.stateStr("lastUrl", url);
        // 新一轮抓取就把选择游标归零：第一次 pick / pick-comment 落在第一条。
        try reply.stateInt("pickIndex", -1);

        // The one id an autonomous reply may use, taken from this very fetch.
        var auto_reply_target: []const u8 = "";
        var auto_reply_suspect = true;

        // Provenance for later writes: only ids the bridge actually returned.
        if (best_comment) |comment| {
            const comment_id = dfy.getStr(comment, "id") orelse "";
            try reply.stateStr("lastCommentId", comment_id);
            try reply.stateInt("commentIndex", -1);
            if (comment_suspect and withheld_kind == null) {
                withheld_kind = .comment;
                withheld_id = comment_id;
            }
            comment_evaluated = true;
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
                const reply_suspect = looksLikeInjection(dfy.getStr(item, "text") orelse "")
                    or looksLikeInjection(dfy.getStr(item, "author") orelse "");
                try reply.stateStr("lastReplyId", reply_id);
                try reply.stateInt("replyIndex", -1);
                if (reply_suspect and withheld_kind == null) {
                    withheld_kind = .reply;
                    withheld_id = reply_id;
                }
                reply_evaluated = true;
                // 目标回复可疑时退回评论；评论也可疑就由 auto_reply_suspect
                // 保持为 true，整轮自动回复作废。
                if (validId(reply_id) and !reply_suspect) {
                    auto_reply_target = reply_id;
                }
            } else {
                try reply.stateRemove("lastReplyId");
                // 旧版本留下的副本，仅清理。
                try reply.stateRemove("lastReplyAuthor");
                try reply.stateRemove("lastReplyText");
                try reply.stateRemove("lastReplySuspect");
                try reply.stateRemove("replyIndex");
            }
        } else {
            try clearCommentSelection(reply);
        }

        if (withheld_kind) |withheld_target| {
            try recordWithheld(reply, withheld_target, withheld_id);
        } else if (video_evaluated and comment_evaluated and reply_evaluated) {
            try recordWithheld(reply, null, "");
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
            and best_comment_interest >= Guard.auto_interest_score
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
            // `writeRefusal` 的拒绝在自动路径上完全安静：用户没按任何按钮，
            // `tick` 抓回来的一句话不该替他在桌面上嚷「每日写入额度用完了」。
            if (refusal == null) {
                // 正文不合规是另一回事：用户开了自动回复却永远等不到，会以为
                // 插件坏了，所以这里留一行状态，指明手动执行 `reply` 能看到
                // 具体原因。正文本身一个字也不改。
                var reason_buffer: [Guard.refusal_reason_capacity]u8 = undefined;
                if (bodyRefusal(user_reply, &reason_buffer) == null) {
                    switch (try emitWrite(ctx, &write_seq, .reply, bridge, auto_reply_target, user_reply)) {
                        .sent => wrote_this_round = true,
                        // 序号用尽与「请求拼不出来」是两回事：前者唯一的出口是
                        // `reset`，静默按「没发出去」处理会让用户永远等不到恢复。
                        .sequence_exhausted => {
                            try reply.say("自动回复没发出去：写入序号已经用尽，先执行 reset 重置写入序号。");
                            reply.status("写入序号用尽", null, counter + 1);
                            write_blocked = true;
                        },
                        .failed, .no_bridge, .already_wrote => {
                            reply.status("自动回复没发出去", null, counter + 1);
                            // 回复与收藏共用同一个桥接地址和事件预算：回复请求
                            // 拼不出来时，收藏分支再试只会重复同一条失败提示
                            // （甚至让人以为要发两笔）。本轮到此为止。
                            write_blocked = true;
                        },
                    }
                } else {
                    reply.status("自动回复没发出去：设置里的回复正文不合规，手动执行一次 reply 会说明原因", null, counter + 1);
                    // 回复优先于收藏：用户打开的是自动回复，正文不合规时不能
                    // 悄悄降级成一次收藏。`write_blocked` 每个 tick 都会重新置上，
                    // 所以这条视频在回复正文修好之前会一直停在「不收藏」，不是
                    // 只停这一轮。
                    write_blocked = true;
                }
            }
        }

        if (!wrote_this_round
            and !write_blocked
            and auto_favorite
            and allow_writes
            and bridge.len > 0
            and best_interest >= Guard.auto_interest_score
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
