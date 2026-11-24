/**
 * 本机桥接示例：把一份抖音推荐流喂给「刷抖音」插件。
 *
 *   node tools/bridge.ts                  # 用 tools/feed.json，缺省时用内置示例
 *   node tools/bridge.ts --port 8787      # 换端口
 *   node tools/bridge.ts --feed D:/x.json # 指向你自己的数据
 *
 * 端点：
 *   GET  /feed?limit=20  -> { "items": [ { "id", "title", "author", "url", "hot"? } ] }
 *   GET  /status         -> { "ok": true, "account", "source", "count" }
 *   POST /message        -> 405（预留，插件不会调用）
 *
 * 这个进程只读本地 JSON、只监听 127.0.0.1，不登录抖音、不抓取、不上传任何内容。
 * 想接入真实数据，就把它换成你自己可信的数据源——只要 /feed 的形状不变。
 */
import { createServer } from 'node:http';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const DEMO: FeedItem[] = [
  { id: 'demo-1', title: 'Zig 写插件真香', author: '某鱼', url: 'https://www.douyin.com/', hot: 1200 },
  { id: 'demo-2', title: '三分钟看懂 WASM 沙箱', author: '沙箱研究所', url: 'https://www.douyin.com/', hot: 86000 },
  { id: 'demo-3', title: '桌面宠物的一天', author: '桌宠频道', url: 'https://www.douyin.com/', hot: 4300 },
  { id: 'demo-4', title: '今天也在认真吃饭', author: '干饭人', url: 'https://www.douyin.com/', hot: 2100000 },
];

interface FeedItem {
  id: string;
  title: string;
  author: string;
  url: string;
  hot?: number;
}

interface FeedFile {
  items?: unknown;
}

function argument(name: string, fallback: string): string {
  const index = process.argv.indexOf(`--${name}`);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  return value && !value.startsWith('--') ? value : fallback;
}

const port = Number(argument('port', process.env.DFY_BRIDGE_PORT ?? '8787'));
const feedPath = argument('feed', join(import.meta.dirname, 'feed.json'));

/** 读一次 feed 文件；缺字段的条目丢掉，`url` 不是 https 的也丢掉。 */
function loadFeed(): { items: FeedItem[]; source: string } {
  if (!existsSync(feedPath)) return { items: DEMO, source: 'builtin' };
  try {
    const parsed = JSON.parse(readFileSync(feedPath, 'utf8')) as FeedFile;
    const raw = Array.isArray(parsed.items) ? parsed.items : [];
    const items: FeedItem[] = [];
    for (const entry of raw) {
      if (!entry || typeof entry !== 'object') continue;
      const record = entry as Record<string, unknown>;
      const id = typeof record.id === 'string' ? record.id : '';
      const title = typeof record.title === 'string' ? record.title : '';
      const author = typeof record.author === 'string' ? record.author : '';
      const url = typeof record.url === 'string' ? record.url : '';
      if (!id || !title || !url.startsWith('https://')) continue;
      const hot = typeof record.hot === 'number' && Number.isFinite(record.hot) ? record.hot : undefined;
      items.push({ id, title, author, url, ...(hot === undefined ? {} : { hot }) });
    }
    return { items, source: feedPath };
  } catch {
    return { items: [], source: `${feedPath}（解析失败）` };
  }
}

const server = createServer((request, response) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? '127.0.0.1'}`);
  const send = (status: number, body: unknown): void => {
    const text = JSON.stringify(body);
    response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
    response.end(text);
  };

  if (request.method === 'GET' && url.pathname === '/feed') {
    const { items, source } = loadFeed();
    const limit = Math.min(50, Math.max(1, Number(url.searchParams.get('limit') ?? '20') || 20));
    send(200, { source, items: items.slice(0, limit) });
    return;
  }
  if (request.method === 'GET' && url.pathname === '/status') {
    const { items, source } = loadFeed();
    send(200, { ok: true, account: '本机示例', source, count: items.length });
    return;
  }
  if (request.method === 'POST' && url.pathname === '/message') {
    send(405, { ok: false, error: '预留端点：本示例不会发送任何内容。' });
    return;
  }
  send(404, { ok: false, error: '未知端点' });
});

server.on('error', (error: NodeJS.ErrnoException) => {
  if (error.code === 'EADDRINUSE') {
    console.error(`端口 ${port} 已被占用，换一个：node tools/bridge.ts --port ${port + 1}`);
  } else {
    console.error(`桥接启动失败：${error.message}`);
  }
  process.exit(1);
});

server.listen(port, '127.0.0.1', () => {
  const { items, source } = loadFeed();
  console.log(`桥接已启动：http://127.0.0.1:${port}`);
  console.log(`数据来源：${source}（${items.length} 条）`);
  console.log('在面板里把「桥接地址」填成上面的地址即可。Ctrl+C 退出。');
});
