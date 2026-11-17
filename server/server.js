// Servidor de Apuntes: sincronización + web. Sin dependencias externas.
'use strict';
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

const PORT = Number(process.env.PORT || 8080);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const WEB_DIR = process.env.WEB_DIR || path.join(__dirname, 'web');
const PASSWORD = process.env.APP_PASSWORD || '';
const MAX_BODY = 50 * 1024 * 1024;

if (!PASSWORD || PASSWORD.length < 8) {
  console.error('ERROR: define APP_PASSWORD (mínimo 8 caracteres).');
  process.exit(1);
}

fs.mkdirSync(DATA_DIR, { recursive: true });
const BLOB_DIR = path.join(DATA_DIR, 'blobs');
fs.mkdirSync(BLOB_DIR, { recursive: true });
const db = new DatabaseSync(path.join(DATA_DIR, 'apuntes.db'));
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS records (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    parent TEXT NOT NULL,
    data TEXT NOT NULL,
    updated_at INTEGER NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    seq INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS records_seq ON records(seq);
  CREATE TABLE IF NOT EXISTS tokens (
    token TEXT PRIMARY KEY,
    created INTEGER NOT NULL
  );
`);

const stmt = {
  get: db.prepare('SELECT updated_at FROM records WHERE id = ?'),
  maxSeq: db.prepare('SELECT COALESCE(MAX(seq), 0) AS m FROM records'),
  upsert: db.prepare(`INSERT INTO records (id, kind, parent, data, updated_at, deleted, seq)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, parent=excluded.parent, data=excluded.data,
      updated_at=excluded.updated_at, deleted=excluded.deleted, seq=excluded.seq`),
  pull: db.prepare('SELECT * FROM records WHERE seq > ? ORDER BY seq LIMIT ?'),
  all: db.prepare('SELECT * FROM records ORDER BY seq'),
  tokenGet: db.prepare('SELECT token FROM tokens WHERE token = ?'),
  tokenAdd: db.prepare('INSERT INTO tokens (token, created) VALUES (?, ?)'),
};

function rowToRec(r) {
  return {
    id: r.id, kind: r.kind, parent: r.parent, data: JSON.parse(r.data),
    updatedAt: Number(r.updated_at), deleted: !!r.deleted, seq: Number(r.seq),
  };
}

function send(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
      catch (e) { reject(e); }
    });
    req.on('error', reject);
  });
}

function readRaw(req) {
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function authed(req) {
  const h = req.headers['authorization'] || '';
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  return t.length > 0 && !!stmt.tokenGet.get(t);
}

let failedLogins = 0;
function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(a).digest();
  const hb = crypto.createHash('sha256').update(b).digest();
  return crypto.timingSafeEqual(ha, hb);
}

const isStr = (v) => typeof v === 'string' && v.length > 0 && v.length < 200;

async function api(req, res, url) {
  const p = url.pathname;
  if (p === '/api/health') return send(res, 200, { ok: true });

  if (p === '/api/login' && req.method === 'POST') {
    const body = await readBody(req);
    // Pequeña pausa creciente ante fallos para frenar ataques de fuerza bruta.
    if (failedLogins > 0) await new Promise((r) => setTimeout(r, Math.min(failedLogins, 10) * 500));
    if (typeof body.password === 'string' && safeEqual(body.password, PASSWORD)) {
      failedLogins = 0;
      const token = crypto.randomBytes(32).toString('hex');
      stmt.tokenAdd.run(token, Date.now());
      return send(res, 200, { token });
    }
    failedLogins++;
    return send(res, 401, { error: 'Contraseña incorrecta' });
  }

  if (!authed(req)) return send(res, 401, { error: 'No autorizado' });

  if (p === '/api/push' && req.method === 'POST') {
    const body = await readBody(req);
    const recs = Array.isArray(body.records) ? body.records : [];
    let seq = Number(stmt.maxSeq.get().m);
    let accepted = 0;
    db.exec('BEGIN');
    try {
      for (const r of recs) {
        if (!r || !isStr(r.id) || !isStr(r.kind) || typeof r.parent !== 'string') continue;
        const updatedAt = Number(r.updatedAt);
        if (!Number.isFinite(updatedAt)) continue;
        const cur = stmt.get.get(r.id);
        if (cur && Number(cur.updated_at) >= updatedAt) continue; // el servidor ya tiene algo igual o más nuevo
        seq++;
        stmt.upsert.run(r.id, r.kind, r.parent, JSON.stringify(r.data ?? {}), updatedAt, r.deleted ? 1 : 0, seq);
        accepted++;
      }
      db.exec('COMMIT');
    } catch (e) { db.exec('ROLLBACK'); throw e; }
    return send(res, 200, { accepted, seq });
  }

  if (p === '/api/pull' && req.method === 'GET') {
    const since = Number(url.searchParams.get('since') || 0);
    const limit = Math.min(Number(url.searchParams.get('limit') || 1000), 5000);
    const rows = stmt.pull.all(since, limit + 1);
    const more = rows.length > limit;
    const recs = rows.slice(0, limit).map(rowToRec);
    const last = recs.length ? recs[recs.length - 1].seq : since;
    return send(res, 200, { records: recs, last, more });
  }

  const blob = p.match(/^\/api\/blob\/([a-z0-9]{10,40})$/);
  if (blob) {
    const file = path.join(BLOB_DIR, blob[1]);
    if (req.method === 'PUT') {
      const data = await readRaw(req);
      fs.writeFileSync(file + '.tmp', data);
      fs.renameSync(file + '.tmp', file);
      return send(res, 200, { ok: true, size: data.length });
    }
    if (req.method === 'GET') {
      if (!fs.existsSync(file)) return send(res, 404, { error: 'No encontrado' });
      res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'private, max-age=31536000, immutable' });
      return fs.createReadStream(file).pipe(res);
    }
  }

  if (p === '/api/export' && req.method === 'GET') {
    const recs = stmt.all.all().map(rowToRec);
    res.writeHead(200, {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Disposition': `attachment; filename="apuntes-copia-${new Date().toISOString().slice(0, 10)}.json"`,
    });
    return res.end(JSON.stringify({ exported: Date.now(), records: recs }));
  }

  return send(res, 404, { error: 'No encontrado' });
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json', '.wasm': 'application/wasm', '.css': 'text/css', '.png': 'image/png',
  '.ico': 'image/x-icon', '.svg': 'image/svg+xml', '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2',
  '.symbols': 'application/octet-stream', '.bin': 'application/octet-stream', '.frag': 'application/octet-stream',
};
const NO_CACHE = new Set(['index.html', 'flutter_bootstrap.js', 'flutter_service_worker.js', 'manifest.json', 'version.json', 'main.dart.js']);

function serveStatic(req, res, url) {
  const root = path.resolve(WEB_DIR);
  let rel = decodeURIComponent(url.pathname);
  if (rel.endsWith('/')) rel += 'index.html';
  let file = path.resolve(root, '.' + rel);
  if (!file.startsWith(root + path.sep)) { res.writeHead(403); return res.end(); }
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) file = path.join(root, 'index.html');
  if (!fs.existsSync(file)) {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end('Servidor de Apuntes funcionando (la app web no está instalada en WEB_DIR).');
  }
  const base = path.basename(file);
  res.writeHead(200, {
    'Content-Type': MIME[path.extname(file)] || 'application/octet-stream',
    'Cache-Control': NO_CACHE.has(base) ? 'no-cache' : 'public, max-age=3600',
  });
  fs.createReadStream(file).pipe(res);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname.startsWith('/api/')) return await api(req, res, url);
    return serveStatic(req, res, url);
  } catch (e) {
    console.error(e);
    if (!res.headersSent) send(res, 500, { error: 'Error interno' });
  }
});

server.listen(PORT, () => console.log(`Apuntes escuchando en el puerto ${PORT}`));
