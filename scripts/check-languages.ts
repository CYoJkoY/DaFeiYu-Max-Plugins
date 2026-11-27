/**
 * 守住本仓库的语言上限：插件源码只用 Zig，工具脚本只用 TypeScript。
 *
 * 主应用仓库（DaFeiYu-Max）的上限是 Dart + Zig + TypeScript；这个插件市场仓库
 * 不承载 Flutter 代码，所以只用后两种，同样不引入第四种语言。
 *
 * 以 `git ls-files`（受版本控制的文件）为基准，本地缓存与构建产物不参与判断。
 * 运行 `node scripts/check-languages.ts`，CI 与提交前都可以直接跑。
 */
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { extname, join, relative, sep } from 'node:path';

/** 允许出现的编程语言扩展名。 */
const ALLOWED_CODE_EXTENSIONS = new Set(['.zig', '.ts']);

/** 除 Zig / TypeScript 之外的编程语言扩展名，出现即失败。 */
const BANNED_EXTENSIONS = new Set([
  // JavaScript 家族：源码只写 TypeScript，不提交任何 JS 文件或产物。
  '.js',
  '.cjs',
  '.mjs',
  '.jsx',
  // Dart 留在主应用，不进插件市场仓库。
  '.dart',
  // Python
  '.py',
  '.pyc',
  '.pyi',
  '.pyw',
  // PowerShell、Shell 与批处理
  '.ps1',
  '.psm1',
  '.psd1',
  '.sh',
  '.bash',
  '.zsh',
  '.fish',
  '.bat',
  '.cmd',
  // 系统与托管运行时语言
  '.rs',
  '.go',
  '.java',
  '.kt',
  '.kts',
  '.scala',
  '.groovy',
  '.cs',
  '.fs',
  '.vb',
  // 其他脚本语言
  '.rb',
  '.php',
  '.lua',
  '.pl',
  '.pm',
  '.jl',
  '.ex',
  '.exs',
  '.erl',
  '.hs',
  '.clj',
  '.nim',
  // C 家族与 Apple 平台语言
  '.c',
  '.h',
  '.cpp',
  '.hpp',
  '.cc',
  '.cxx',
  '.hh',
  '.m',
  '.mm',
  '.swift',
]);

/** TypeScript 的其他扩展名同样算 TypeScript，但仓库统一只用 `.ts`。 */
const TYPESCRIPT_DIALECTS = new Set(['.mts', '.cts', '.tsx']);

const SKIPPED_DIRECTORIES = new Set([
  '.azflow',
  '.git',
  '.zig-cache',
  'dist',
  'node_modules',
  'zig-cache',
  'zig-out',
]);

const failures: string[] = [];
const root = process.cwd();
const tracked = listTrackedFiles();

for (const path of tracked) {
  const extension = extname(path).toLowerCase();
  if (!extension) continue;
  if (ALLOWED_CODE_EXTENSIONS.has(extension)) continue;
  if (TYPESCRIPT_DIALECTS.has(extension)) {
    failures.push(`${path}: TypeScript 统一用 .ts，不要用 ${extension}`);
    continue;
  }
  if (BANNED_EXTENSIONS.has(extension)) {
    failures.push(`${path}: 插件仓库只用 Zig + TypeScript，${extension} 属于第四种语言`);
  }
}

if (!tracked.some((path) => path.endsWith('.zig'))) {
  failures.push('仓库里没有 .zig 源码，插件必须由 Zig 编译');
}
if (!tracked.some((path) => path.endsWith('.ts'))) {
  failures.push('仓库里没有 .ts 工具脚本，构建与校验脚本必须用 TypeScript');
}

const workflowPath = join(root, '.github', 'workflows', 'validate.yml');
if (!existsSync(workflowPath)) {
  failures.push('缺少 .github/workflows/validate.yml');
} else {
  const workflow = readFileSync(workflowPath, 'utf8');
  if (!workflow.includes('node scripts/check-languages.ts')) {
    failures.push('CI 没有运行 node scripts/check-languages.ts');
  }
  if (!workflow.includes('mlugg/setup-zig')) {
    failures.push('CI 缺少 mlugg/setup-zig 步骤');
  }
  for (const retired of ['npm ci', 'npm run', 'npx ', 'cargo build', 'pip install', 'dotnet build']) {
    if (workflow.includes(retired)) failures.push(`CI 仍在调用 ${retired}`);
  }
}

for (const document of ['AGENTS.md', 'README.md']) {
  const path = join(root, document);
  if (!existsSync(path)) {
    failures.push(`缺少 ${document}`);
    continue;
  }
  const text = readFileSync(path, 'utf8');
  for (const language of ['Zig', 'TypeScript']) {
    if (!text.includes(language)) failures.push(`${document} 必须写明允许的语言：${language}`);
  }
}

if (failures.length) {
  console.error(`语言检查失败（${failures.length} 个问题）：`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}
console.log(`语言检查通过：${tracked.length} 个受版本控制的文件里只有 Zig + TypeScript。`);

/** 受版本控制的文件才是仓库的语言契约；没有 Git 时退回目录扫描。 */
function listTrackedFiles(): string[] {
  try {
    const output = execFileSync('git', ['ls-files', '-z'], {
      cwd: root,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const paths = output
      .split('\u0000')
      .filter((entry) => entry.length > 0)
      .map(normalize);
    if (paths.length) return paths;
  } catch {
    // 没有安装 Git：退回目录扫描。
  }
  return walk(root).map((path) => normalize(relative(root, path)));
}

function walk(directory: string): string[] {
  const files: string[] = [];
  for (const name of readdirSync(directory)) {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) {
      if (SKIPPED_DIRECTORIES.has(name)) continue;
      files.push(...walk(path));
    } else {
      files.push(path);
    }
  }
  return files;
}

function normalize(path: string): string {
  return sep === '/' ? path : path.split(sep).join('/');
}
