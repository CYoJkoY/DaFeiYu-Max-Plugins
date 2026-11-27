# 为 DaFeiYu-Max-Plugins 编码的代理须知

- 这是**云端插件市场仓库**，不是主应用仓库。不要把主应用代码（`src/`、`dist/`、
  Electron、面板）复制进来。
- 全仓库最多三种编程语言：Dart + Zig + TypeScript。Dart 留在主应用
  （DaFeiYu-Max），本仓库只用 **Zig**（`plugins/<id>/src/main.zig`、`sdk/dfy.zig`）
  与 **TypeScript**（`scripts/*.ts`、`tools/bridge.ts`）。
- 除这两种之外不要引入任何语言：JavaScript（含 `.cjs` / `.mjs`）、Python、PowerShell、
  Shell / 批处理、Rust、C / C++、C#、Kotlin、Ruby、Lua 一律不允许。
  `node scripts/check-languages.ts` 以 `git ls-files` 为基准扫描，CI 第一步就跑它。
- `plugins/<id>/` 的目录名必须与 `plugin.json` 的 `id` 一致。
- 每次修改 Zig 源码后必须重新编译并更新 `plugin.wasm`，再运行
  `node scripts/build-index.ts` 同步 `index.json` 的 `size` 与 `sha256`。
- `node scripts/build-plugin.ts --check` 会用 Zig 重新编译每个 `src/main.zig` 并要求
  与 `plugin.wasm` 逐字节相同；改完源码用 `--write` 刷新模块，CI 跑的是 `--check`。
- 编译命令必须带四个 `--export=` 参数，否则链接器会丢弃 ABI 导出。
- 不提交 `zig-cache/`、`zig-out/` 或任何临时构建产物。
- 中文文案；不夸大能力，不承诺应用没有实现过的行为。
