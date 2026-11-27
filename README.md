# DaFeiYu-Max-Plugins

<p align="center"><img src="assets/brand/plugin-icon.png" width="220" alt="DaFeiYu-Max 插件库"></p>

蓝色大肥鱼（DaFeiYu）的云端插件市场仓库。主应用读取这里的 `index.json`，
按需下载 `plugin.json` 清单与 `plugin.wasm` 模块，全部校验后才安装到本地。

## 它是什么

- 每个 `plugins/<id>/` 目录包含一份 `plugin.json` 清单、编译好的 `plugin.wasm`
  和（可选的）`src/main.zig` 源码。
- 插件是 **Zig 源码编译出的 WASM 模块**，运行在主应用的 worker 沙箱里。
- 主应用通过 SHA-256 与大小双重校验，保证下载到的模块与索引记录完全一致。

## 它不是什么

- 不托管任何会自动执行、自动安装或自动发送内容的组件。
- 不收集任何用户数据；安装行为完全由用户在主应用面板里手动触发。
- 不是 Magpie 页面，也不是桌宠本体。

## 语言约定

整个项目最多三种编程语言：**Dart + Zig + TypeScript**。Dart 只留在主应用
（DaFeiYu-Max）里写 Flutter 界面；本仓库只需要后两种——**Zig** 写插件与 SDK，
**TypeScript** 写校验、构建与测试脚本。除此之外的语言——JavaScript（含 `.cjs` /
`.mjs`）、Python、PowerShell、Shell / 批处理、Rust、C / C++、C#、Kotlin、Ruby、
Lua——都不进仓库。

`node scripts/check-languages.ts` 以受版本控制的文件为基准检查这条上限（CI 第一步
就运行）；出现第四种语言的扩展名、CI 漏掉本检查，或文档没写明语言约定都会失败。

## 目录结构

```
sdk/dfy.zig                 插件开发 SDK（主应用同款）
assets/brand/plugin-icon.png  市场图标 PNG 母版
assets/brand/plugin-icon.ico  Windows 图标（由 PNG 母版生成）
plugins/<id>/plugin.json    声明 ABI、权限、设置项与命令
plugins/<id>/src/main.zig   可读源码
plugins/<id>/plugin.wasm    编译产物（与清单 script.entry 同名）
schema/index.schema.json    市场索引 JSON Schema
scripts/icons.ts            从 PNG 母版重新生成 ICO
scripts/check-languages.ts  检查全仓库只有 Zig + TypeScript
scripts/lib/png.ts          PNG 编解码、缩放与 ICO 容器（仅标准库）
scripts/validate.ts         校验清单、模块与索引一致性
scripts/build-index.ts      按现有模块重算 size / sha256 并重建 index.json
scripts/build-plugin.ts     用 Zig 重编译并比对（--write 刷新模块）
scripts/test-plugin.ts      把编好的模块放进 Node 的 WASM 运行时跑确定性测试
```

`node scripts/icons.ts` 会从 `assets/brand/plugin-icon.png` 重新生成
`assets/brand/plugin-icon.ico`；PNG 与 ICO 都随仓库提交。

## 如何发布一个插件

1. 在 `plugins/` 下新建目录（kebab-case，与清单 `id` 一致）。
2. 写 `src/main.zig`，顶部 `const dfy = @import("dfy.zig");`，底部
   `comptime { dfy.install(onEvent); }`。
3. 编译（Zig 0.17+）：

   ```sh
   zig build-exe -O ReleaseSmall -target wasm32-freestanding -fno-entry \
     --export=dfy_abi_version --export=dfy_alloc --export=dfy_free --export=dfy_invoke \
     main.zig
   ```

   产物重命名为 `plugin.wasm`，放在 `plugins/<id>/` 下（与 `script.entry` 一致）。
   也可以直接运行 `node scripts/build-plugin.ts --write`，它会按同样的参数编译
   每个 `src/main.zig` 并覆盖对应的 `plugin.wasm`。
4. 写 `plugin.json`，声明 `kind: "script"`、`permissions`、`settings`、`commands`。
5. 运行 `node scripts/validate.ts` 确认本地一致。
6. 运行 `node scripts/build-index.ts` 重建 `index.json`，提交并推送。

CI 除了校验清单与索引，还会用 Zig 0.17.1 把每个 `src/main.zig` 重新编译一遍，
要求结果与提交的 `plugin.wasm` 逐字节相同。源码和模块不同步会直接失败，
避免市场里出现「源码是一套、跑的是另一套」的模块。

## 本地试跑（刷抖音）

`plugins/douyin-scroll` 需要一份本机桥接数据。仓库自带一个零依赖示例：

```sh
node tools/bridge.ts            # http://127.0.0.1:8787，读 tools/feed.json
node tools/bridge.ts --port 8766 --feed D:/我的数据.json
```

它只监听 `127.0.0.1`、只读本地 JSON，提供 `GET /feed?limit=20`、`GET /status`，
不登录抖音、不抓取、不上传。把主应用里的「桥接地址」填成同一个地址，插件就会
从这份数据里按兴趣挑一条念给你听。想接真实数据源，就替换这个进程——只要
`/feed` 的返回形状不变。

推荐流里可以带 `comments`（含 `replies`），插件会挑一条热念念出来。若在设置里
打开「允许写入」，插件还会向上表的 `POST /like`、`/favorite`、`/comment`、
`/reply` 发请求；示例桥接只把它们记在内存里，用 `GET /log` 查看。写操作在插件
内部有强制守门（详见 `plugins/douyin-scroll/README.md`）。

## 测试

```sh
node scripts/test-plugin.ts
```

它不起服务、不联网：把 `plugins/douyin-scroll/plugin.wasm` 实例化到 Node 自带的
WebAssembly 运行时里，用假宿主喂事件、读回包，断言写操作守门与文本清洗的行为。

## 两条红线

- 只声明真正需要的权限；`net` 必须列出 `allowHosts`。
- 不上传用户数据，不要求越权权限，不承诺应用没有实现过的行为。
