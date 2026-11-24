# 贡献一个插件

## 目录约定

```
plugins/<id>/
  plugin.json      清单（必填）
  plugin.wasm      编译产物（必填，与 script.entry 同名）
  src/main.zig     源码（建议随附，便于审阅）
  README.md        说明（建议）
```

`<id>` 必须是小写 kebab-case，且与 `plugin.json` 的 `id` 完全一致。

## 清单要点

- `schemaVersion` 固定为 `1`，`kind` 固定为 `"script"`。
- `script.abi` 固定为 `1`，`script.entry` 是该目录内的 `.wasm` 文件名。
- `script.permissions` 只能取 `pet`、`bridge`、`net`；用 `net` 时必须同时写
  `script.allowHosts`，且只列真正需要的主机名。
- 设置项 `script.settings` 支持 `url` / `number` / `text` / `boolean` 四种类型。
- 命令名 `script.commands` 只能是小写字母开头，最长 25 字符。

## 编译

```sh
zig build-exe -O ReleaseSmall -target wasm32-freestanding -fno-entry \
  --export=dfy_abi_version --export=dfy_alloc --export=dfy_free --export=dfy_invoke \
  src/main.zig
```

四个 `--export=` 参数缺一不可：Zig 0.17 会做 section 回收，缺了它们 ABI 导出会被
链接器丢弃，主应用加载时会直接拒绝。

把 `main.wasm` 重命名为 `plugin.wasm`。

## 提交前自检

```sh
node scripts/validate.ts     # 清单、模块、哈希与索引一致
node scripts/build-plugin.ts --check  # 源码重编译后必须与 plugin.wasm 逐字节一致
node scripts/build-index.ts  # 重算 size / sha256 并写回 index.json
```

三条都通过后再提交 `index.json`。CI 也会跑同样的检查。

改完 `src/main.zig` 不想手抄编译参数时，直接运行
`node scripts/build-plugin.ts --write`：它用与主应用完全相同的参数逐个编译
`src/main.zig` 并覆盖 `plugin.wasm`，之后照常重建索引即可。

## 红线

- 只声明真正需要的权限，能不用 `net` 就不用。
- 不收集、不上传用户数据。
- 不承诺主应用没有实现的行为；插件不能自己联网、自己点开窗口或自动发送内容。
