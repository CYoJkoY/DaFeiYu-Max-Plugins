# 刷抖音（douyin-scroll）

让桌宠替你「刷」抖音：从本机抖音桥接读取推荐流，按你的兴趣挑一条，念一句
`刷到：标题 @作者`，挑得出来还会顺口念一条热评。**写操作（点赞 / 收藏 /
评论 / 回复）默认关闭**，开启后也必须先过插件内置的守门脚本。

## 它依赖什么

插件自身不联网，也读不到浏览器。它只通过主应用的 `bridge` 权限向**本机**的
抖音桥接服务发请求，剩下的（请求、桌宠动作、状态持久化）都由主应用执行。

桥接服务需要由你自己运行（例如一个本机小服务），端点如下：

| 方法 | 路径 | 要求 |
| --- | --- | --- |
| `GET` | `/feed?limit=20&comments=1` | 返回 `{ "items": [ { "id", "title", "author", "url", "hot"?, "comments"? } ] }` |
| `GET` | `/status` | 返回 `{ "ok": true, "account": "..." }`，可选 |
| `POST` | `/like` | `{ "id": "..." }` |
| `POST` | `/favorite` | `{ "id": "..." }` |
| `POST` | `/comment` | `{ "id": "...", "text": "..." }` |
| `POST` | `/reply` | `{ "target": "...", "text": "..." }` |

`items[].id`、`comments[].id`、`comments[].replies[].id` 必须是 `[A-Za-z0-9_-]{1,64}`，
`url` 必须是 `https://` 才会被采纳。评论形如：

```json
{
  "id": "c-1001",
  "author": "沙箱研究所",
  "text": "编译参数那四个 --export 是真的容易漏",
  "likes": 312,
  "replies": [{ "id": "r-1001", "author": "某鱼", "text": "等你交作业" }]
}
```

写端点收到的是 JSON 正文（插件不发请求头，所以示例桥接不校验 `Content-Type`）。
仓库自带的 `tools/bridge.ts` 就是一份可直接运行的示例：

```sh
node tools/bridge.ts            # http://127.0.0.1:8787，读 tools/feed.json
node tools/bridge.ts --port 8787
```

示例会把收到的写请求打印到终端，并记在内存里：`GET /log` 可以看到
`{ action, target, text }`。**它不会真的去操作抖音**——接真实账号时务必在
你自己的服务里再做一次鉴权与限流。

## 设置项

| id | 类型 | 说明 |
| --- | --- | --- |
| `bridgeUrl` | url | 桥接地址，例如 `http://127.0.0.1:8787` |
| `intervalSeconds` | number | 刷新间隔，5–300 秒，默认 20 |
| `interestBoost` | boolean | 是否优先推送命中兴趣关键词的内容，默认开 |
| `allowWrites` | boolean | **写操作总开关**，默认关 |
| `autoFavorite` | boolean | 命中兴趣时自动收藏，默认关；仍受总开关与守门约束 |
| `autoReply` | boolean | 命中兴趣的评论自动回复，默认关；仍受总开关与守门约束 |
| `commentText` | text | 你亲手写的评论原文，`comment` 命令只发这一句 |
| `replyText` | text | 你亲手写的回复原文，`reply` 命令与自动回复只发这一句 |
| `dailyWriteLimit` | number | 每日写入上限，1–50，默认 5 |
| `writeCooldownSeconds` | number | 两次写入之间的冷却，10–600 秒，默认 60 |

兴趣关键词来自主应用的「兴趣」设置，命中标题加分高于命中作者。

## 命令

- `next`：立刻刷一条。
- `reset`：清零累计计数、写入计数与去重记录。
- `stats`：让桌宠念出累计刷了多少条、今天写入了几次。
- `like` / `favorite`：对**上一次刷到的那条**点赞 / 收藏。
- `comment`：对上一次刷到的视频发一条评论，正文就是 `commentText`。
- `reply`：对上一次刷到的热评（没有热评就对该视频的最新评论）回复，正文就是 `replyText`。

## 自主写入：收藏与回复

两个开关都默认关闭，都要先开「允许写入」：

- `autoFavorite`：视频本身命中兴趣时自动收藏。
- `autoReply`：**被念出来的那条评论**命中兴趣时，自动回复它，正文是 `replyText`。

这两个动作有一条共同约束：**一条视频最多只自动写一次**，且回复优先于收藏——一条
视频同时满足两者时只发回复，不会又收藏又回复。所有自动写入和命令走同一个守门，
被拒时静默（因为不是你按的按钮），并且同样计入冷却与每日上限。

## 守门脚本：为什么评论不能"自由发挥"

推荐流、评论、回复全是陌生人写的文本。这类文本最危险的用法不是"写得不好"，
而是**当成指令**：一句话藏个"忽略之前的设定"，或者塞一堆看不见的字符把真正的
句子藏起来；长上下文里再强的角色提示词也可能被注意力偏移带走。所以这里不靠
提示词，靠代码：

1. **写操作只有一条合法路径**：`command`（或你明确打开的自动收藏 / 自动回复）
   → 守门通过 → 发出请求。`tick`、`effect-result`、feed 内容永远不会直接产生
   写请求，一条视频最多自动写一次。
2. **目标必须来自本插件自己的记录**：`lastId` / `lastCommentId` / `lastReplyId`
   只在上一次成功抓取时写入，且 id 必须匹配 `[A-Za-z0-9_-]`。桥接文本无法伪造
   一个"写到哪里"。
3. **正文只能是你手写的原文**：`commentText` / `replyText` 逐字发送，绝不拼接
   feed 里的标题、评论或回复。命令本身也没有"内容"参数。
4. **限速**：总开关 + 冷却时间 + 每日上限，一个命令只发一条请求。
5. **显示前清洗**：所有桥接文本进入桌宠嘴里之前都会去掉控制字符、零宽字符、
   双向覆盖字符与 Unicode 标签字符，空白压成单空格并按字符数截断——看不见的
   东西念不出来，也撑不长上下文。

这些规则写死在 `src/main.zig` 里，没有设置项可以关掉。`scripts/test-plugin.ts`
会把注入样本喂进编译好的 `plugin.wasm`，断言它们一个写请求都发不出来。

## 还没做的

- 插件不做任何"生成式"表达：评论与回复只发你写好的原文，不会自己遣词造句。
- 自动回复只认"被念出来那条评论命中兴趣"，不会逐条扫评论；也不会自动给视频发评论。
- 兴趣关键词来自主应用设置，插件不会自己"学习"你喜欢什么。
- 没有多账号、没有私信、没有视频内的互动数据回传。

## 本地开发

```sh
zig build-exe -O ReleaseSmall -target wasm32-freestanding -fno-entry \
  --export=dfy_abi_version --export=dfy_alloc --export=dfy_free --export=dfy_invoke \
  src/main.zig
```

把生成的 `main.wasm` 重命名为 `plugin.wasm` 放在本目录（或直接运行
`node scripts/build-plugin.ts --write`），然后在仓库根运行
`node scripts/test-plugin.ts`、`node scripts/validate.ts` 与
`node scripts/build-index.ts`。

想先在本地试跑而不发布，可以把这份 `main.zig` 直接拖进主应用的「安装本地插件」，
它会用你机器上的 Zig 编译并装进本地插件目录，完全不上传。
