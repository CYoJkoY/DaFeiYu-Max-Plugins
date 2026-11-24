# 刷抖音（douyin-scroll）

让桌宠替你「刷」抖音：从本机抖音桥接读取推荐流，按你的兴趣挑一条，念一句
`刷到：标题 @作者`，然后隔一段时间再来一次。**不会点赞、不会评论、不会发送、
不会上传任何数据。**

## 它依赖什么

插件自身不联网，也读不到浏览器。它只通过主应用的 `bridge` 权限向**本机**的抖音
桥接服务发一次 `GET`，剩下的（请求、桌宠动作、状态持久化）都由主应用执行。

桥接服务需要由你自己运行（例如一个本机小服务），并实现三个端点：

| 方法 | 路径 | 要求 |
| --- | --- | --- |
| `GET` | `/feed?limit=20` | 返回 `{ "items": [ { "id", "title", "author", "url", "hot"? } ] }` |
| `GET` | `/status` | 返回 `{ "ok": true, "account": "..." }`，可选 |
| `POST` | `/message` | 预留：主应用不会主动调用它 |

`items[].id` 必填且需唯一；`url` 必须是 `https://` 链接才会被采纳。

仓库自带的 `tools/bridge.ts` 就是一份可直接运行的示例：

```sh
node tools/bridge.ts            # http://127.0.0.1:8765，读 tools/feed.json
```

## 设置项

| id | 类型 | 说明 |
| --- | --- | --- |
| `bridgeUrl` | url | 桥接地址，例如 `http://127.0.0.1:8765` |
| `intervalSeconds` | number | 刷新间隔，5–300 秒，默认 20 |
| `interestBoost` | boolean | 是否优先推送命中兴趣关键词的内容，默认开 |

兴趣关键词来自主应用的「兴趣」设置，命中标题加分高于命中作者。

## 命令

- `next`：立刻刷一条。
- `reset`：清零累计计数并清空去重记录。
- `stats`：让桌宠念出累计刷了多少条。

## 本地开发

```sh
zig build-exe -O ReleaseSmall -target wasm32-freestanding -fno-entry \
  --export=dfy_abi_version --export=dfy_alloc --export=dfy_free --export=dfy_invoke \
  src/main.zig
```

把生成的 `main.wasm` 重命名为 `plugin.wasm` 放在本目录，然后在仓库根运行
`node scripts/validate.ts` 与 `node scripts/build-index.ts`。

想先在本地试跑而不发布，可以把这份 `main.zig` 直接拖进主应用的「安装本地插件」，
它会用你机器上的 Zig 编译并装进本地插件目录，完全不上传。
