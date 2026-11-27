/**
 * Validates every plugin in `plugins/` against the market index: the manifest
 * parses, the module exists at the recorded size, and the SHA-256 matches.
 *
 * The index rules below are the ones the Flutter app enforces in
 * `DaFeiYu-Max/lib/core/market.dart`; a green run here means the app accepts
 * `index.json` as published. Current status is documented in the main
 * repository's `docs/plugin-market.md`.
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
const PATH_SEGMENT_PATTERN = /^[A-Za-z0-9._-]+$/;
const SCHEME_PATTERN = /^[a-zA-Z][a-zA-Z0-9+.-]*:/;

/** The same ceilings the app applies before it will read a market document. */
const MAX_INDEX_BYTES = 512 * 1024;
const MAX_MANIFEST_BYTES = 64 * 1024;
const MAX_WASM_BYTES = 4 * 1024 * 1024;
const MAX_PLUGINS = 500;

/**
 * One `index.json` entry, as `lib/core/market.dart` reads it. Fields the app
 * does not consume (`harness`, `source`) are deliberately absent.
 */
interface IndexEntry {
  id: string;
  version: string;
  kind: string;
  name: string;
  description: string;
  author: string;
  permissions: string[];
  labels?: Record<string, string>;
  tags?: string[];
  homepage?: string;
  manifest: string;
  wasm: string;
  size: number;
  sha256: string;
}

const failures: string[] = [];
/** Directory name → manifest, so index entries can be checked against the files. */
const manifests = new Map<string, Record<string, unknown>>();

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

  const manifestBytes = statSync(manifestPath).size;
  if (manifestBytes > MAX_MANIFEST_BYTES) {
    failures.push(`${name}: plugin.json 有 ${manifestBytes} 字节，超过 64 KiB`);
    continue;
  }
  let manifest: Record<string, unknown>;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    failures.push(`${name}: plugin.json 不是合法 JSON（${error instanceof Error ? error.message : error}）`);
    continue;
  }
  manifests.set(name, manifest);
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
  if (bytes.byteLength > MAX_WASM_BYTES) failures.push(`${name}: ${entry} 超过 4 MiB`);
}

const indexPath = join(root, 'index.json');
if (!existsSync(indexPath)) {
  failures.push('缺少 index.json');
} else {
  const indexBytes = readFileSync(indexPath);
  if (indexBytes.byteLength > MAX_INDEX_BYTES) {
    failures.push(`index.json 有 ${indexBytes.byteLength} 字节，超过 512 KiB`);
  }
  let index: { schemaVersion?: unknown; generatedAt?: unknown; plugins?: IndexEntry[] };
  try {
    index = JSON.parse(indexBytes.toString('utf8'));
  } catch (error) {
    index = {};
    failures.push(`index.json 不是合法 JSON（${error instanceof Error ? error.message : error}）`);
  }
  if (index.schemaVersion !== 1) failures.push(`index.json: schemaVersion 必须是 1（当前 ${String(index.schemaVersion)}）`);
  if (typeof index.generatedAt !== 'string' || !index.generatedAt || index.generatedAt.length > 40) {
    failures.push('index.json: generatedAt 必须是 40 字符以内的非空字符串');
  }
  const plugins = Array.isArray(index.plugins) ? index.plugins : [];
  if (plugins.length > MAX_PLUGINS) failures.push(`index.json: 条目数 ${plugins.length} 超过上限 ${MAX_PLUGINS}`);
  const seen = new Set<string>();
  for (const entry of plugins) {
    if (!entry || typeof entry !== 'object') {
      failures.push('index.json: plugins 里有非法条目');
      continue;
    }
    const id = typeof entry.id === 'string' ? entry.id : String(entry.id);
    if (seen.has(id)) failures.push(`index.json: id 重复 ${id}`);
    seen.add(id);
    if (!ID_PATTERN.test(id) || id.length > 64) failures.push(`${id}: id 必须是 64 字符以内的小写 kebab-case`);
    if (entry.kind !== 'script') failures.push(`${id}: kind 必须是 script`);
    if (typeof entry.version !== 'string' || !VERSION_PATTERN.test(entry.version)) {
      failures.push(`${id}: version 必须是 x.y.z`);
    }
    checkText(id, 'name', entry.name, 80);
    checkText(id, 'description', entry.description, 240);
    checkText(id, 'author', entry.author, 80);
    if (typeof entry.homepage === 'string') {
      if (!entry.homepage.startsWith('https://') || entry.homepage.length > 300) {
        failures.push(`${id}: homepage 必须是 300 字符以内的 https 地址`);
      }
    }
    if (!Array.isArray(entry.permissions) || entry.permissions.length === 0) {
      failures.push(`${id}: permissions 必须是非空数组`);
    } else {
      const unique = new Set(entry.permissions);
      if (unique.size !== entry.permissions.length) failures.push(`${id}: permissions 有重复项`);
      for (const permission of entry.permissions) {
        if (!REQUIRED_PERMISSIONS.has(String(permission))) failures.push(`${id}: 未知权限 ${String(permission)}`);
      }
    }
    if (entry.labels !== undefined) {
      if (typeof entry.labels !== 'object' || entry.labels === null) {
        failures.push(`${id}: labels 必须是对象`);
      } else {
        for (const [key, value] of Object.entries(entry.labels)) {
          if (key !== 'zh' && key !== 'en') failures.push(`${id}: labels 只认 zh / en，出现了 ${key}`);
          if (typeof value !== 'string' || !value || value.length > 80) {
            failures.push(`${id}: labels.${key} 必须是 80 字符以内的非空字符串`);
          }
        }
      }
    }
    if (entry.tags !== undefined) {
      if (!Array.isArray(entry.tags)) {
        failures.push(`${id}: tags 必须是数组`);
      } else {
        if (entry.tags.length > 12) failures.push(`${id}: tags 超过 12 个`);
        for (const tag of entry.tags) {
          if (typeof tag !== 'string' || !tag || tag.length > 32) {
            failures.push(`${id}: tags 只接受 32 字符以内的非空字符串`);
          }
        }
      }
    }
    if (!SHA_PATTERN.test(String(entry.sha256))) failures.push(`${id}: sha256 必须是 64 位小写十六进制`);
    if (!Number.isInteger(entry.size) || entry.size <= 0 || entry.size > MAX_WASM_BYTES) {
      failures.push(`${id}: size 必须是 1 到 ${MAX_WASM_BYTES} 之间的整数`);
    }
    // The app only accepts repository-relative paths it can sanitise, and it
    // builds the download URL from them verbatim, so the index has to name the
    // canonical location of the files that live next to it.
    if (!isMarketPath(entry.manifest, `plugins/${id}/plugin.json`)) {
      failures.push(`${id}: manifest 必须是 plugins/${id}/plugin.json`);
    }
    const manifest = manifests.get(id);
    if (!manifest) {
      failures.push(`${id}: 没有对应的 plugins/${id}/plugin.json`);
    } else {
      const script = manifest.script as Record<string, unknown> | undefined;
      const entryName = String(script?.entry ?? '');
      if (!isMarketPath(entry.wasm, `plugins/${id}/${entryName}`)) {
        failures.push(`${id}: wasm 必须是 plugins/${id}/${entryName}`);
      }
      if (String(manifest.version) !== entry.version) {
        failures.push(`${id}: 索引版本 ${entry.version} 与清单版本 ${String(manifest.version)} 不一致`);
      }
    }
    const wasmPath = join(root, String(entry.wasm));
    if (!existsSync(wasmPath)) {
      failures.push(`${id}: wasm 路径不存在 ${String(entry.wasm)}`);
      continue;
    }
    const bytes = readFileSync(wasmPath);
    if (bytes.byteLength !== entry.size) {
      failures.push(`${id}: 大小不一致（索引 ${entry.size}，实际 ${bytes.byteLength}）`);
    }
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (actual !== entry.sha256) {
      failures.push(`${id}: SHA-256 不一致（索引 ${entry.sha256}，实际 ${actual}）`);
    }
  }
  for (const id of manifests.keys()) {
    if (!seen.has(id)) failures.push(`${id}: 在 index.json 中没有条目`);
  }
}

const brandPngPath = join(root, 'assets', 'brand', 'plugin-icon.png');
const brandIcoPath = join(root, 'assets', 'brand', 'plugin-icon.ico');
if (!existsSync(brandPngPath)) {
  failures.push('缺少 assets/brand/plugin-icon.png');
} else {
  const png = readFileSync(brandPngPath);
  if (png.length < 24 || png.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a') {
    failures.push('assets/brand/plugin-icon.png 不是合法 PNG');
  } else {
    const width = png.readUInt32BE(16);
    const height = png.readUInt32BE(20);
    if (width !== height || width < 256) {
      failures.push(`assets/brand/plugin-icon.png 必须是至少 256px 的正方形（当前 ${width}x${height}）`);
    }
  }
}
if (!existsSync(brandIcoPath)) {
  failures.push('缺少 assets/brand/plugin-icon.ico');
} else {
  const ico = readFileSync(brandIcoPath);
  if (ico.length < 6 || ico.readUInt16LE(0) !== 0 || ico.readUInt16LE(2) !== 1) {
    failures.push('assets/brand/plugin-icon.ico 不是合法 ICO');
  } else {
    const count = ico.readUInt16LE(4);
    const sizes = new Set<number>();
    for (let index = 0; index < count; index += 1) {
      const entry = 6 + 16 * index;
      if (entry + 16 > ico.length) {
        failures.push('assets/brand/plugin-icon.ico 条目被截断');
        break;
      }
      const width = ico.readUInt8(entry) || 256;
      const height = ico.readUInt8(entry + 1) || 256;
      const length = ico.readUInt32LE(entry + 8);
      const offset = ico.readUInt32LE(entry + 12);
      if (width !== height || offset + length > ico.length) {
        failures.push(`assets/brand/plugin-icon.ico 含损坏的 ${width}x${height} 条目`);
        break;
      }
      sizes.add(width);
    }
    for (const size of [16, 32, 48, 256]) {
      if (!sizes.has(size)) failures.push(`assets/brand/plugin-icon.ico 缺少 ${size}px 条目`);
    }
  }
}

if (failures.length) {
  console.error(`校验失败（${failures.length} 个问题）：`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log('校验通过：清单、模块与索引一致，索引符合主应用的接受契约。');

/** Non-empty text with the same length ceiling the app applies. */
function checkText(id: string, field: string, value: unknown, max: number): void {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max) {
    failures.push(`${id}: ${field} 必须是 ${max} 字符以内的非空字符串`);
  }
}

/**
 * A repository-relative path, mirroring the app's `sanitizeMarketPath`:
 * no absolute paths, no `..`, no backslashes, no URL scheme, forward slashes
 * only, 200 characters at most, and nothing outside `expected` when given.
 */
function isMarketPath(value: unknown, expected?: string): boolean {
  if (typeof value !== 'string') return false;
  const text = value.trim();
  if (!text || text.length > 200) return false;
  if (text.includes('\\') || text.startsWith('/') || text.includes('..')) return false;
  if (SCHEME_PATTERN.test(text)) return false;
  if (expected !== undefined && text !== expected) return false;
  return text.split('/').every((segment) => segment.length > 0 && PATH_SEGMENT_PATTERN.test(segment));
}
