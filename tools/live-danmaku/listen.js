'use strict';
// Usage: node listen.js <roomId> <outFile> [cookiesFile]

const fs = require('fs');

const roomId = parseInt(process.argv[2], 10);
const outFile = process.argv[3];
const cookiesFile = process.argv[4] || '';

function emit(obj) {
  try {
    fs.appendFileSync(outFile, `${JSON.stringify(obj)}\n`, { encoding: 'utf8' });
  } catch (_) { /* swallow */ }
}

function readNetscapeCookies(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return {};
  const map = {};
  for (const line of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    if (!line || line.startsWith('#')) continue;
    const parts = line.split('\t');
    if (parts.length < 7) continue;
    map[parts[5]] = parts[6];
  }
  return map;
}

if (!roomId || roomId <= 0) {
  if (outFile) emit({ type: 'error', message: 'roomId required' });
  process.exit(1);
}
if (!outFile) {
  process.stderr.write('outFile required\n');
  process.exit(1);
}

emit({ type: 'system', message: 'starting', roomId });

function onDanmu(data) {
  try {
    const info = (data && data.info) || [];
    const text = String(info[1] || '');
    if (!text) return;
    const meta = info[0] || [];
    const colorInt = (typeof meta[3] === 'number' && meta[3] > 0) ? meta[3] : 0xFFFFFF;
    const hex = `#${colorInt.toString(16).padStart(6, '0').toUpperCase()}`;
    emit({ type: 'danmaku', text, color: hex });
  } catch (e) {
    emit({ type: 'error', message: `parse DANMU_MSG: ${e.message}` });
  }
}

(async () => {
  let mod;
  try {
    mod = await import('bilibili-live-danmaku');
  } catch (e) {
    emit({ type: 'error', message: `import bilibili-live-danmaku failed: ${e && e.message ? e.message : e}` });
    process.exit(2);
  }

  const { LiveWS, BilibiliApiClient, parseLiveConfig } = mod;
  if (!LiveWS) {
    emit({ type: 'error', message: `LiveWS not found: ${Object.keys(mod).join(',')}` });
    process.exit(3);
  }

  const cookieMap = readNetscapeCookies(cookiesFile);
  const cookieStr = Object.entries(cookieMap).map(([k, v]) => `${k}=${v}`).join('; ');
  const uid = parseInt(cookieMap.DedeUserID || cookieMap.DedeUserID__ckMd5 || '0', 10) || 0;
  const buvid = cookieMap.buvid3 || cookieMap.BUVID || '';

  const wsOpts = {};
  if (uid > 0) wsOpts.uid = uid;
  if (buvid) wsOpts.buvid = buvid;

  if (cookieStr && BilibiliApiClient && parseLiveConfig) {
    try {
      const client = new BilibiliApiClient({ cookie: cookieStr });
      await client.initCookie();
      const info = await client.xliveGetDanmuInfo({ id: roomId });
      const cfg = parseLiveConfig(info.data);
      if (cfg.key) wsOpts.key = cfg.key;
      if (cfg.address) wsOpts.address = cfg.address;
      emit({ type: 'system', message: 'danmu info ok', roomId });
    } catch (e) {
      emit({ type: 'error', message: `danmu auth: ${e && e.message ? e.message : e}` });
    }
  }

  let live;
  try {
    live = new LiveWS(roomId, wsOpts);
  } catch (e) {
    emit({ type: 'error', message: `new LiveWS failed: ${e.message}` });
    process.exit(4);
  }

  emit({ type: 'system', message: 'ws constructed (LiveWS)', roomId });

  live.addEventListener('open', () => emit({ type: 'system', message: 'ws open', roomId }));
  live.addEventListener('CONNECT_SUCCESS', () => emit({ type: 'system', message: 'connected', roomId }));
  live.addEventListener('close', () => emit({ type: 'system', message: 'ws close', roomId }));
  live.addEventListener('error', (e) => {
    const msg = (e && e.message) ? e.message : String(e);
    emit({ type: 'error', message: `ws error: ${msg}` });
  });
  live.addEventListener('DANMU_MSG', (ev) => onDanmu(ev.data || ev));
  live.addEventListener('MESSAGE', (ev) => {
    const data = ev.data;
    if (data && data.cmd === 'DANMU_MSG') onDanmu(data);
  });
})();

process.on('uncaughtException', (e) => {
  emit({ type: 'error', message: `uncaught: ${e && e.message ? e.message : e}` });
});
process.on('unhandledRejection', (e) => {
  emit({ type: 'error', message: `unhandledRejection: ${e && e.message ? e.message : e}` });
});

// heartbeat: every 30s so the overlay can detect if node has died
setInterval(() => {
  emit({ type: 'system', message: 'heartbeat' });
}, 30000).unref();
