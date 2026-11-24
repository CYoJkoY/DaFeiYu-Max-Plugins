/**
 * 本机桥接示例：把一份抖音推荐流（含评论）喂给「刷抖音」插件，并把插件的
 * 写请求记在内存里。
 *
 *   node tools/bridge.ts                  # 用 tools/feed.json，缺省时用内置示例
 *   node tools/bridge.ts --port 8787      # 换端口
 *   node tools/bridge.ts --feed D:/x.json # 指向你自己的数据
 *
 * 读端点：
 *   GET  /feed?limit=20  -> { "items": [ { "id", "title", "author", "url", "hot"?, "comments"? } ] }
 *   GET  /status         -> { "ok": true, "account", "source", "count" }
 *   GET  /log            -> { "writes": [ { "at", "action", "target", "text"? } ] }
 *
 * 写端点（只有插件在守门放行时才会调到这里）：
 *   POST /like      { "id": "..." }
 *   POST /favorite  { "id": "..." }
 *   POST /comment   { "id": "...", "text": "..." }
 *   POST /reply     { "target": "...", "text": "..." }
 *
 * 正文是 JSON。示例不校验 Content-Type，因为主应用的 ABI 只保证发正文，
 * 不保证请求头。
 *
 * 这个进程只读本地 JSON、只监听 127.0.0.1，不登录抖音、不抓取、不上传任何内容。
 * 写请求也只记在本进程内存里——想真的落地，就把这一段换成你自己的接口，并
 * 自己再做一次鉴权：插件侧的守门只保证"发什么"，不替你的下游做权限判断。
 */
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

interface Reply {
  id: string;
  author: string;
  text: string;
}

interface Comment {
  id: string;
  author: string;
  text: string;
  likes?: number;
  replies?: Reply[];
}

interface FeedItem {
  id: string;
  title: string;
  author: string;
  url: string;
  hot?: number;
  comments?: Comment[];
}

interface FeedFile {
  items?: unknown;
}

interface WriteRecord {
  at: string;
  action: string;
  target: string;
  text?: string;
}

const DEMO: FeedItem[] = [
  {
    id: 'demo-1', title: 'Zig 写插件真香', author: '某鱼', url: 'https://www.douyin.com/', hot: 1200,
    comments: [{ id: 'demo-c1', author: '沙箱研究所', text: '四个 --export 少了就白编译', likes: 210 }],
  },
  { id: 'demo-2', title: '三分钟看懂 WASM 沙箱', author: '沙箱研究所', url: 'https://www.douyin.com/', hot: 86000 },
  {
    id: 'demo-3', title: '桌面宠物的一天', author: '桌宠频道', url: 'https://www.douyin.com/', hot: 4300,
    comments: [
      {
        id: 'demo-c3', author: '路过的鱼', text: '它今天也很努力', likes: 42,
        replies: [{ id: 'demo-r3', author: '桌宠频道', text: '谢谢喜欢' }],
      },
    ],
  },
  { id: 'demo-4', title: '今天也在认真吃饭', author: '干饭人', url: 'https://www.douyin.com/', hot: 2100000 },
];

const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const TEXT_LIMIT = 200;
const LOG_LIMIT = 200;

function argument(name: string, fallback: string): string {
  const index = process.argv.indexOf(`--${name}`);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  return value && !value.startsWith('--') ? value : fallback;
}

const port = Number(argument('port', process.env.DFY_BRIDGE_PORT ?? '8787'));
const feedPath = argument('feed', join(import.meta.dirname, 'feed.json'));
const writes: WriteRecord[] = [];

/** 只收结构正确的评论：缺 id / text 的、id 不是 id 形状的一律丢掉。 */
function readComment(entry: unknown): Comment | null {
  if (!entry || typeof entry !== 'object') return null;
  const record = entry as Record<string, unknown>;
  const id = typeof record.id === 'string' ? record.id : '';
  const text = typeof record.text === 'string' ? record.text : '';
  if (!ID_PATTERN.test(id) || !text) return null;
  const author = typeof record.author === 'string' ? record.author : '';
  const likes = typeof record.likes === 'number' && Number.isFinite(record.likes) ? record.likes : undefined;
  const replies: Reply[] = [];
  if (Array.isArray(record.replies)) {
    for (const item of record.replies) {
      if (replies.length >= 20) break;
      if (!item || typeof item !== 'object') continue;
      const raw = item as Record<string, unknown>;
      const replyId = typeof raw.id === 'string' ? raw.id : '';
      const replyText = typeof raw.text === 'string' ? raw.text : '';
      if (!ID_PATTERN.test(replyId) || !replyText) continue;
      replies.push({
        id: replyId,
        author: typeof raw.author === 'string' ? raw.author : '',
        text: replyText,
      });
    }
  }
  return {
    id,
    author,
    text,
    ...(likes === undefined ? {} : { likes }),
    ...(replies.length ? { replies } : {}),
  };
}

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
      if (!ID_PATTERN.test(id) || !title || !url.startsWith('https://')) continue;
      const hot = typeof record.hot === 'number' && Number.isFinite(record.hot) ? record.hot : undefined;
      const comments: Comment[] = [];
      if (Array.isArray(record.comments)) {
        for (const comment of record.comments) {
          const parsedComment = readComment(comment);
          if (parsedComment) comments.push(parsedComment);
        }
      }
      items.push({
        id, title, author, url,
        ...(hot === undefined ? {} : { hot }),
        ...(comments.length ? { comments } : {}),
      });
    }
    return { items, source: feedPath };
  } catch {
    return { items: [], source: `${feedPath}（解析失败）` };
  }
}

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > 32_000) {
        reject(new Error('正文过大'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function parseBody(text: string): Record<string, unknown> | null {
  if (!text.trim()) return null;
  try {
    const parsed = JSON.parse(text) as unknown;
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

const server = createServer(async (request: IncomingMessage, response: ServerResponse) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? '127.0.0.1'}`);
  const send = (status: number, body: unknown): void => {
    const text = JSON.stringify(body);
    response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
    response.end(text);
  };

  if (request.method === 'GET' && url.pathname === '/feed') {
    const { items, source } = loadFeed();
    const limit = Math.min(50, Math.max(1, Number(url.searchParams.get('limit') ?? '20') || 20));
    const withComments = url.searchParams.get('comments') === '1';
    const sliced = items.slice(0, limit).map(item => (
      withComments || !item.comments ? item : { ...item, comments: undefined }
    ));
    send(200, { source, items: sliced });
    return;
  }
  if (request.method === 'GET' && url.pathname === '/status') {
    const { items, source } = loadFeed();
    send(200, { ok: true, account: '本机示例', source, count: items.length, writes: writes.length });
    return;
  }
  if (request.method === 'GET' && url.pathname === '/log') {
    send(200, { writes });
    return;
  }

  if (request.method === 'POST') {
    const action = url.pathname.replace(/^\//, '');
    if (!['like', 'favorite', 'comment', 'reply'].includes(action)) {
      send(404, { ok: false, error: '未知端点' });
      return;
    }
    let body: Record<string, unknown> | null;
    try {
      body = parseBody(await readBody(request));
    } catch (error) {
      send(413, { ok: false, error: error instanceof Error ? error.message : '读取正文失败' });
      return;
    }
    if (!body) {
      send(400, { ok: false, error: '正文必须是 JSON 对象' });
      return;
    }
    const target = action === 'reply' ? body.target : body.id;
    if (typeof target !== 'string' || !ID_PATTERN.test(target)) {
      send(400, { ok: false, error: '目标 id 无效' });
      return;
    }
    let text: string | undefined;
    if (action === 'comment' || action === 'reply') {
      if (typeof body.text !== 'string' || !body.text.trim() || body.text.length > TEXT_LIMIT) {
        send(400, { ok: false, error: `正文缺失或超过 ${TEXT_LIMIT} 字` });
        return;
      }
      text = body.text;
    }
    const record: WriteRecord = { at: new Date().toISOString(), action, target, ...(text === undefined ? {} : { text }) };
    writes.unshift(record);
    if (writes.length > LOG_LIMIT) writes.length = LOG_LIMIT;
    console.log(`[写入] ${action} ${target}${text === undefined ? '' : `：${text}`}`);
    send(200, { ok: true, ...record });
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
  console.log('写请求只记在本进程内存里，用 GET /log 查看；Ctrl+C 退出。');
});
