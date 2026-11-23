/**
 * Validates every plugin in `plugins/` against the market index: the manifest
 * parses, the module exists at the recorded size, and the SHA-256 matches.
 *
 * Run with `node scripts/validate.ts` from the repository root.
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const VERSION_PATTERN = /^\d+\.\d+\.\d+(?:[-+][\w.-]+)?$/;
const SHA_PATTERN = /^[a-f0-9]{64}$/;
const REQUIRED_PERMISSIONS = new Set(['pet', 'bridge', 'net']);

interface IndexEntry {
  id: string;
  version: string;
  kind: string;
  manifest: string;
  wasm: string;
  size: number;
  sha256: string;
}

const failures: string[] = [];
const manifestPaths: string[] = [];

const root = process.cwd();
const pluginsDirectory = join(root, 'plugins');
if (!existsSync(pluginsDirectory)) {
  console.error('plugins/ 目录不存在。');
  process.exit(1);
}

for (const name of readdirSync(pluginsDirectory).sort()) {
  const directory = join(pluginsDirectory, name);
  if (!statSync(directory).isDirectory()) continue;
  const manifestPath = join(directory, 'plugin.json');
  if (!existsSync(manifestPath)) continue;
  manifestPaths.push(manifestPath);

  let manifest: Record<string, unknown>;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    failures.push(`${name}: plugin.json 不是合法 JSON（${error instanceof Error ? error.message : error}）`);
    continue;
  }
  if (manifest.id !== name) failures.push(`${name}: 清单 id「${manifest.id}」与目录名不一致`);
  if (!ID_PATTERN.test(String(manifest.id ?? ''))) failures.push(`${name}: id 必须是小写 kebab-case`);
  if (!VERSION_PATTERN.test(String(manifest.version ?? ''))) failures.push(`${name}: version 必须是 x.y.z`);
  if (manifest.kind !== 'script') failures.push(`${name}: kind 必须是 "script"`);
  const script = manifest.script as Record<string, unknown> | undefined;
  if (!script) {
    failures.push(`${name}: 缺少 script 段`);
    continue;
  }
  if (script.abi !== 1) failures.push(`${name}: script.abi 必须是 1`);
  const entry = String(script.entry ?? '');
  if (!/^[A-Za-z0-9._-]+\.wasm$/.test(entry)) failures.push(`${name}: entry 必须是插件目录内的 .wasm 文件名`);
  const permissions = Array.isArray(script.permissions) ? script.permissions : [];
  if (!permissions.length) failures.push(`${name}: permissions 不能为空`);
  for (const permission of permissions) {
    if (!REQUIRED_PERMISSIONS.has(String(permission))) failures.push(`${name}: 未知权限 ${String(permission)}`);
  }
  if (permissions.includes('net') && !Array.isArray(script.allowHosts)) {
    failures.push(`${name}: net 权限必须声明 allowHosts`);
  }

  const wasmPath = join(directory, entry);
  if (!existsSync(wasmPath)) {
    failures.push(`${name}: 找不到 ${entry}`);
    continue;
  }
  const bytes = readFileSync(wasmPath);
  if (bytes.byteLength === 0) failures.push(`${name}: ${entry} 是空文件`);
  if (bytes.byteLength > 4 * 1024 * 1024) failures.push(`${name}: ${entry} 超过 4 MiB`);
}

const indexPath = join(root, 'index.json');
if (!existsSync(indexPath)) {
  failures.push('缺少 index.json');
} else {
  let index: { plugins?: IndexEntry[] };
  try {
    index = JSON.parse(readFileSync(indexPath, 'utf8'));
  } catch (error) {
    index = {};
    failures.push(`index.json 不是合法 JSON（${error instanceof Error ? error.message : error}）`);
  }
  const plugins = Array.isArray(index.plugins) ? index.plugins : [];
  const seen = new Set<string>();
  for (const entry of plugins) {
    if (!entry || typeof entry !== 'object') {
      failures.push('index.json: plugins 里有非法条目');
      continue;
    }
    if (seen.has(entry.id)) failures.push(`index.json: id 重复 ${entry.id}`);
    seen.add(entry.id);
    if (entry.kind !== 'script') failures.push(`${entry.id}: kind 必须是 script`);
    if (!SHA_PATTERN.test(entry.sha256)) failures.push(`${entry.id}: sha256 必须是 64 位小写十六进制`);
    const manifestPath = join(root, entry.manifest);
    if (!existsSync(manifestPath)) failures.push(`${entry.id}: 清单路径不存在 ${entry.manifest}`);
    const wasmPath = join(root, entry.wasm);
    if (!existsSync(wasmPath)) {
      failures.push(`${entry.id}: wasm 路径不存在 ${entry.wasm}`);
      continue;
    }
    const bytes = readFileSync(wasmPath);
    if (bytes.byteLength !== entry.size) {
      failures.push(`${entry.id}: 大小不一致（索引 ${entry.size}，实际 ${bytes.byteLength}）`);
    }
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (actual !== entry.sha256) {
      failures.push(`${entry.id}: SHA-256 不一致（索引 ${entry.sha256}，实际 ${actual}）`);
    }
  }
  for (const manifestPath of manifestPaths) {
    const directory = statSync(manifestPath.slice(0, manifestPath.lastIndexOf('plugin.json'))).isDirectory()
      ? manifestPath.replace(/[\\/]plugin\.json$/, '')
      : manifestPath;
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    if (!seen.has(String(manifest.id))) {
      failures.push(`${manifest.id}: 在 index.json 中没有条目`);
    }
  }
}

if (failures.length) {
  console.error(`校验失败（${failures.length} 个问题）：`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('校验通过：清单、模块与索引一致。');