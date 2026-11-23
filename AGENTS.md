# 为 DaFeiYu-Max-Plugins 编码的代理须知

- 这是**云端插件市场仓库**，不是主应用仓库。不要把主应用代码（`src/`、`dist/`、
  Electron、面板）复制进来。
- 插件源码只用 Zig；工具脚本只用 TypeScript（`node scripts/*.ts`）。
- `plugins/<id>/` 的目录名必须与 `plugin.json` 的 `id` 一致。
- 每次修改 Zig 源码后必须重新编译并更新 `plugin.wasm`，再运行
  `node scripts/build-index.ts` 同步 `index.json` 的 `size` 与 `sha256`。
- 编译命令必须带四个 `--export=` 参数，否则链接器会丢弃 ABI 导出。
- 不提交 `zig-cache/`、`zig-out/` 或任何临时构建产物。
- 中文文案；不夸大能力，不承诺应用没有实现过的行为。