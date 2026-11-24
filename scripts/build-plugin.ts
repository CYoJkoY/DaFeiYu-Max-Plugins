/**
 * Compiles every `plugins/<id>/src/main.zig` with the local Zig and compares
 * the result against the committed `plugin.wasm`.
 *
 *   node scripts/build-plugin.ts --check    # CI：源码必须能编译，且与模块逐字节一致
 *   node scripts/build-plugin.ts --write    # 作者改完源码后刷新 plugin.wasm
 *
 * 之后仍需运行 `node scripts/build-index.ts` 更新 size / sha256。
 * 只依赖 Node 与 Zig，不引入其它语言或运行时。
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = process.cwd();
const pluginsDirectory = join(root, 'plugins');
const sdkPath = join(root, 'sdk', 'dfy.zig');
const write = process.argv.includes('--write');
const check = !write;

/** 与主应用「安装本地插件」完全一致的编译参数。 */
const FLAGS = [
  'build-exe', '-O', 'ReleaseSmall', '-target', 'wasm32-freestanding', '-fno-entry',
  '--export=dfy_abi_version', '--export=dfy_alloc', '--export=dfy_free', '--export=dfy_invoke',
  'main.zig',
];

if (!existsSync(pluginsDirectory)) {
  console.error('plugins/ 目录不存在。');
  process.exit(1);
}
if (!existsSync(sdkPath)) {
  console.error('sdk/dfy.zig 不存在。');
  process.exit(1);
}

const probe = spawnSync('zig', ['version'], { encoding: 'utf8' });
if (probe.status !== 0) {
  console.error('找不到 zig。请安装 Zig 0.17+ 并把 zig 放进 PATH。');
  process.exit(1);
}
console.log(`zig ${probe.stdout.trim()}`);

const digest = (path: string): string => createHash('sha256').update(readFileSync(path)).digest('hex');
const problems: string[] = [];
const withoutSource: string[] = [];
let built = 0;

for (const name of readdirSync(pluginsDirectory).sort()) {
  const directory = join(pluginsDirectory, name);
  if (!statSync(directory).isDirectory()) continue;
  if (!existsSync(join(directory, 'plugin.json'))) continue;
  const sourcePath = join(directory, 'src', 'main.zig');
  const wasmPath = join(directory, 'plugin.wasm');
  if (!existsSync(sourcePath)) {
    withoutSource.push(name);
    continue;
  }
  if (!existsSync(wasmPath)) {
    problems.push(`${name}: 有源码但缺少 plugin.wasm`);
    continue;
  }
  const work = mkdtempSync(join(tmpdir(), 'dfy-plugin-'));
  try {
    copyFileSync(sdkPath, join(work, 'dfy.zig'));
    copyFileSync(sourcePath, join(work, 'main.zig'));
    const result = spawnSync('zig', FLAGS, { cwd: work, encoding: 'utf8' });
    if (result.status !== 0) {
      const detail = (result.stderr || result.stdout || '').trim().split('\n').slice(-6).join('\n');
      problems.push(`${name}: 编译失败\n${detail}`);
      continue;
    }
    const outputPath = join(work, 'main.wasm');
    if (!existsSync(outputPath)) {
      problems.push(`${name}: 编译结束但没有产物 main.wasm`);
      continue;
    }
    built += 1;
    if (write) {
      copyFileSync(outputPath, wasmPath);
      console.log(`${name}: 已用新编译结果覆盖 plugin.wasm（记得重建 index.json）。`);
      continue;
    }
    const expected = digest(wasmPath);
    const actual = digest(outputPath);
    if (expected !== actual) {
      problems.push(
        `${name}: 源码编译结果与提交的模块不一致\n  提交: ${expected}\n  源码: ${actual}\n` +
        '  说明 plugin.wasm 与 src/main.zig 不同步，请运行 node scripts/build-plugin.ts --write。',
      );
    }
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

for (const name of withoutSource) {
  console.warn(`${name}: 没有 src/main.zig，跳过源码一致性检查。`);
}

if (problems.length) {
  console.error(write ? '刷新失败：' : '源码与模块不一致：');
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log(write
  ? `已刷新 ${built} 个插件模块。`
  : `源码一致性通过：${built} 个插件可从源码逐字节重建。`);
if (check && built === 0) console.log('没有可校验的源码插件。');
