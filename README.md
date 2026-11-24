# DaFeiYu-Max-Plugins

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

## 目录结构

```
sdk/dfy.zig                 插件开发 SDK（主应用同款）
plugins/<id>/plugin.json    声明 ABI、权限、设置项与命令
plugins/<id>/src/main.zig   可读源码
plugins/<id>/plugin.wasm    编译产物（与清单 script.entry 同名）
schema/index.schema.json    市场索引 JSON Schema
scripts/validate.ts         校验清单、模块与索引一致性
scripts/build-index.ts      按现有模块重算 size / sha256 并重建 index.json
```

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
4. 写 `plugin.json`，声明 `kind: "script"`、`permissions`、`settings`、`commands`。
5. 运行 `node scripts/validate.ts` 确认本地一致。
6. 运行 `node scripts/build-index.ts` 重建 `index.json`，提交并推送。

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

## 两条红线

- 只声明真正需要的权限；`net` 必须列出 `allowHosts`。
- 不上传用户数据，不要求越权权限，不承诺应用没有实现过的行为。
