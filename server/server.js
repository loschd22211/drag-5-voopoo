'use strict';

/**
 * Локальный сервер инструмента «Gemini на кнопку питания».
 * Слушает 0.0.0.0 на PORT (по умолчанию 7676), без внешних зависимостей.
 */

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const adb = require('./adb');

const PORT = Number(process.env.PORT || 7676);
// По умолчанию слушаем только локальный интерфейс: у сервера есть доступ к adb shell,
// поэтому выставлять его в локальную сеть без необходимости не стоит.
// HOST=0.0.0.0 — если нужно открыть с другого устройства в сети.
const HOST = process.env.HOST || '127.0.0.1';
const PUBLIC_DIR = path.join(__dirname, 'public');

/** Снимки настроек живут в памяти процесса. */
const snapshots = new Map();

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
};

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > 2 * 1024 * 1024) {
        reject(new Error('слишком большое тело запроса'));
        req.destroy();
        return;
      }
      data += chunk;
    });
    req.on('end', () => {
      if (!data) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch (err) {
        reject(new Error(`невалидный JSON: ${err.message}`));
      }
    });
    req.on('error', reject);
  });
}

function serveStatic(req, res, urlPath) {
  const clean = urlPath === '/' ? '/index.html' : urlPath;
  const full = path.join(PUBLIC_DIR, path.normalize(clean).replace(/^([/\\])+/, ''));
  if (!full.startsWith(PUBLIC_DIR)) {
    res.writeHead(403).end('forbidden');
    return;
  }
  fs.readFile(full, (err, buf) => {
    if (err) {
      res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('not found');
      return;
    }
    res.writeHead(200, {
      'content-type': MIME[path.extname(full)] || 'application/octet-stream',
      'cache-control': 'no-store',
    });
    res.end(buf);
  });
}

/** Достаёт serial из тела запроса или берёт первый подключённый. */
async function resolveSerial(body) {
  if (body && body.serial) return body.serial;
  const list = await adb.listDevices();
  const first = list.devices.find((d) => d.state === 'device');
  return first ? first.serial : null;
}

const routes = {
  'GET /api/env': async () => {
    const version = await adb.adbVersion();
    return {
      ...version,
      node: process.version,
      platform: `${process.platform}/${process.arch}`,
      port: PORT,
      defaultAdb: adb.ADB_BIN,
      commandsPreview: {
        assignAssistant:
          'adb shell settings put secure assistant <pkg>/<Service>\nadb shell settings put secure voice_interaction_service <pkg>/<Service>',
      },
    };
  },

  'GET /api/devices': async () => adb.listDevices(),

  'POST /api/pair': async (body) => {
    if (body.code) return adb.pair(body.hostPort, body.code);
    return adb.connect(body.hostPort);
  },

  'POST /api/tcpip': async (body) => adb.enableTcpip(body.port || 5555),

  'POST /api/diagnose': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.diagnose(serial);
  },

  'POST /api/set-assistant': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.setAssistant(serial, body.component);
  },

  'POST /api/open': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.openTarget(serial, body.target, body.component);
  },

  'POST /api/test-assist': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.testAssistant(serial);
  },

  'POST /api/grant-mic': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.grantMic(serial, body.package);
  },

  'POST /api/battery': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.disableBatteryOpt(serial, body.package || adb.PACKAGES.googleApp);
  },

  'POST /api/prefs/snapshot': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    const snap = await adb.snapshotSettings(serial);
    snapshots.set(snap.id, snap);
    // держим не больше 20 снимков
    while (snapshots.size > 20) snapshots.delete(snapshots.keys().next().value);
    return { ok: true, id: snap.id, createdAt: snap.createdAt, count: snap.count, values: snap.values };
  },

  'POST /api/prefs/diff': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    const before = snapshots.get(body.id);
    if (!before) return { ok: false, error: 'снимок не найден — сделай новый' };
    const after = await adb.snapshotSettings(serial);
    const changes = adb.diffSnapshots(before, after);
    return { ok: true, before: before.createdAt, after: after.createdAt, changes };
  },

  'POST /api/raw': async (body) => {
    const serial = await resolveSerial(body);
    if (!serial) return { ok: false, error: 'нет подключённых устройств' };
    return adb.rawCommand(serial, body.cmd);
  },
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const key = `${req.method} ${url.pathname}`;

  // превью-окружение: разрешаем встраивание в iframe и запросы с любого origin
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-headers', 'content-type');
  res.setHeader('access-control-allow-methods', 'GET,POST,OPTIONS');
  if (req.method === 'OPTIONS') {
    res.writeHead(204).end();
    return;
  }

  if (routes[key]) {
    try {
      const body = req.method === 'POST' ? await readBody(req) : {};
      const result = await routes[key](body);
      sendJson(res, 200, result);
    } catch (err) {
      sendJson(res, 500, { ok: false, error: String(err && err.message ? err.message : err) });
    }
    return;
  }

  if (req.method === 'GET') {
    serveStatic(req, res, url.pathname);
    return;
  }

  sendJson(res, 404, { ok: false, error: `неизвестный маршрут: ${key}` });
});

server.listen(PORT, HOST, () => {
  const mode = adb.IS_MOCK ? 'ДЕМО-РЕЖИМ (фейковый adb, телефон не нужен)' : `adb: ${adb.ADB_BIN}`;
  console.log(`Gemini power-button helper: http://${HOST}:${PORT}`);
  console.log(`Режим: ${mode}`);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
