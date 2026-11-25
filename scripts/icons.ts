/**
 * Builds `assets/brand/plugin-icon.ico` from the committed PNG master.
 *
 * Run with `node scripts/icons.ts`. The ICO carries 16–256 px frames so
 * Windows Explorer and the taskbar can pick a native size instead of scaling
 * a single bitmap.
 */
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildIco, decodePng } from './lib/png.ts';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ICON_SIZES = [16, 24, 32, 48, 64, 128, 256];

export function buildPluginIcon(base = root): Buffer {
  const masterPath = join(base, 'assets', 'brand', 'plugin-icon.png');
  if (!existsSync(masterPath)) throw new Error(`Missing icon master: ${masterPath}`);
  const master = decodePng(readFileSync(masterPath));
  if (master.width !== master.height || master.width < 256) {
    throw new Error(`Expected a square master of at least 256 px: ${masterPath}`);
  }
  return buildIco(master, ICON_SIZES);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const target = join(root, 'assets', 'brand', 'plugin-icon.ico');
  const bytes = buildPluginIcon();
  writeFileSync(target, bytes);
  console.log(`Built assets/brand/plugin-icon.ico (${bytes.length} bytes, ${ICON_SIZES.length} sizes).`);
}
