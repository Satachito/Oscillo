import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
const root = resolve('.');
const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.md': 'text/plain' };
createServer(async (req, res) => {
  const path = resolve(root, `.${decodeURIComponent(new URL(req.url, 'http://localhost').pathname)}`);
  if (path !== root && !path.startsWith(root + '/')) { res.writeHead(403).end(); return; }
  const file = path === root ? resolve(root, 'index.html') : path;
  try {
    // Read before answering. Writing the header first leaves nothing to say
    // when the file turns out to be missing, and the second writeHead throws
    // out of an async handler — which takes the whole server down.
    const body = await readFile(file);
    res.writeHead(200, { 'Content-Type': types[extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    res.end(body);
  } catch { res.writeHead(404).end('Not found'); }
}).listen(4173, '127.0.0.1', () => console.log('PiLyzer Web: http://localhost:4173'));
