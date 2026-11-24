# dfy.zig · 插件 SDK

`dfy.zig` 是主应用内置的同一份 SDK：插件顶部 `@import("dfy.zig")`，底部
`comptime { dfy.install(onEvent); }`，即可得到一个 `wasm32-freestanding` 模块。

## 事件

主应用把事件序列化成 JSON 交给 `dfy_invoke`，SDK 解析成 `dfy.Context`：

| `ctx.event.type` | 何时发生 |
| --- | --- |
| `install` | 模块刚被加载，回一句状态即可 |
| `activate` | 用户启用插件 |
| `deactivate` | 用户停用插件 |
| `tick` | 到达上次 `schedule` 定的时间 |
| `command` | 用户点了命令，名称在 `ctx.event.name` |
| `effect-result` | 之前的 `httpGet` 等副作用执行完了 |

## 上下文里有什么

- `ctx.config`：`interests`（兴趣关键词）、`options`（面板里填的设置）、`locale`。
- `ctx.state`：这个插件上一次保存的 JSON 状态。
- `ctx.now`：当前毫秒时间戳。

## 只能「申请」，不能「执行」

插件返回值里描述的是**意图**：`reply.say`、`reply.play`、`reply.notify`、
`reply.httpGet`、`reply.schedule`、`reply.status` 以及 `reply.state*`。主应用
逐条检查权限后才会真的去做，插件自身没有网络、没有窗口、没有磁盘。

## 想继续跑，就得排期

`tick` 不是定时轮询：主应用只在上一轮返回值里带 `reply.schedule(ms)` 时才会
再叫你一次，否则这个插件就停在原地，直到用户重新启用或点命令。所以每个「还
想继续」的分支都要排期，包括出错、空结果和等待配置这些终止分支；只有真的想
收工（比如用户点了停用）才可以不排期。`ms` 会被夹到 0.5 秒到 1 小时之间。

## 状态是合并，不是覆盖

`ctx.state` 是上次保存的整份 JSON。回包里的 `state` 会**合并**回去：

- 你写了的键覆盖旧值；
- 你没写的键原样保留；
- 想删掉一个键，用 `reply.stateRemove("key")`，而不是「不写它」。

所以一次 `tick` 只写 `counter` 就够了，不会把上次的 `seen`、`lastTitle` 一起
抹掉。反过来，删除一律显式写出来，调试时也一眼看得见。合并后的结果仍受
48 KB 上限约束。
