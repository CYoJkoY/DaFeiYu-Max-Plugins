/**
 * Rebuilds `index.json` from every `plugins/<id>/plugin.json`, recomputing the
 * module size and SHA-256. Run after each Zig rebuild.
 *
 * Run with `node scripts/build-index.ts` from the repository root.
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const pluginsDirectory = join(root, 'plugins');
if (!existsSync(pluginsDirectory)) {
  console.error('plugins/ 目录不存在。');
  process.exit(1);
}

interface Entry {
  id: string;
  version: string;
  kind: 'script';
  name: string;
  labels?: Record<string, string>;
  description: string;
  author: string;
  homepage?: string;
  tags: string[];
  permissions: string[];
  harness: string;
  size: number;
  sha256: string;
  manifest: string;
  wasm: string;
  source?: string;
}

const entries: Entry[] = [];
const problems: string[] = [];

for (const name of readdirSync(pluginsDirectory).sort()) {
  const directory = join(pluginsDirectory, name);
  if (!statSync(directory).isDirectory()) continue;
  const manifestPath = join(directory, 'plugin.json');
  if (!existsSync(manifestPath)) continue;
  const relative = (suffix: string): string => `plugins/${name}/${suffix}`;
  let manifest: Record<string, unknown>;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  } catch (error) {
    problems.push(`${name}: ${error instanceof Error ? error.message : error}`);
    continue;
  }
  if (manifest.id !== name) {
    problems.push(`${name}: 清单 id「${String(manifest.id)}」与目录名不一致`);
    continue;
  }
  const script = manifest.script as Record<string, unknown> | undefined;
  if (!script) {
    problems.push(`${name}: 缺少 script 段`);
    continue;
  }
  const entryName = String(script.entry ?? 'plugin.wasm');
  const wasmPath = join(directory, entryName);
  if (!existsSync(wasmPath)) {
    problems.push(`${name}: 找不到 ${entryName}`);
    continue;
  }
  const bytes = readFileSync(wasmPath);
  const sourcePath = join(directory, 'src/main.zig');
  const entry: Entry = {
    id: String(manifest.id),
    version: String(manifest.version),
    kind: 'script',
    name: String(manifest.name),
    description: String(manifest.description),
    author: String(manifest.author ?? 'CYoJkoY'),
    tags: Array.isArray(manifest.tags) ? manifest.tags.map(String) : [],
    permissions: Array.isArray(script.permissions) ? script.permissions.map(String) : [],
    harness: 'zig-wasm32-freestanding/abi1',
    size: bytes.byteLength,
    sha256: createHash('sha256').update(bytes).digest('hex'),
    manifest: relative('plugin.json'),
    wasm: relative(entryName),
  };
  if (manifest.labels && typeof manifest.labels === 'object') entry.labels = manifest.labels as Record<string, string>;
  if (typeof manifest.homepage === 'string') entry.homepage = manifest.homepage;
  if (existsSync(sourcePath)) entry.source = relative('src/main.zig');
  entries.push(entry);
}

if (problems.length) {
  console.error('重建索引时发现问题：');
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

const index = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  plugins: entries,
};
writeFileSync(join(root, 'index.json'), `${JSON.stringify(index, null, 2)}\n`);
console.log(`已重建 index.json，包含 ${entries.length} 个插件。`);
