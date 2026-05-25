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

let danmakuCount = 0;
// Map<hash, expiryMs> — dedup identical danmaku within a short window.
const recent = new Map();
function dedupSeen(hash, ttlMs = 1500) {
  const now = Date.now();
  // Lazy cleanup
  if (recent.size > 256) {
    for (const [k, v] of recent) { if (v < now) recent.delete(k); }
  }
  const e = recent.get(hash);
  if (e && e > now) return true;
  recent.set(hash, now + ttlMs);
  return false;
}

function onDanmu(data) {
  try {
    const info = (data && data.info) || [];
    const text = String(info[1] || '');
    if (!text) return;
    // info[0] = [mode, fontsize, color, timestamp, ...]
    const style = info[0] || [];
    const colorInt = (typeof style[2] === 'number' && style[2] > 0) ? style[2] : 0xFFFFFF;
    const hex = `#${(colorInt & 0xFFFFFF).toString(16).padStart(6, '0').toUpperCase()}`;
    // info[2] = [uid, uname, ...]
    const uid = (info[2] && info[2][0]) || 0;
    const sendTs = (typeof style[4] === 'number') ? style[4] : 0;

    const hash = `${uid}|${sendTs}|${text}`;
    if (dedupSeen(hash)) return;

    emit({ type: 'danmaku', text, color: hex });
    danmakuCount++;
    if (danmakuCount % 20 === 0) {
      emit({ type: 'system', message: `danmaku count: ${danmakuCount}` });
    }
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
  // The library dispatches DANMU_MSG directly when cmd matches; listen there.
  live.addEventListener('DANMU_MSG', (ev) => onDanmu(ev && ev.data));
})();

process.on('uncaughtException', (e) => {
  emit({ type: 'error', message: `uncaught: ${e && e.message ? e.message : e}` });
});
process.on('unhandledRejection', (e) => {
  emit({ type: 'error', message: `unhandledRejection: ${e && e.message ? e.message : e}` });
});

// heartbeat: every 20s so the overlay can detect if node has died
setInterval(() => {
  emit({ type: 'system', message: 'heartbeat' });
}, 20000).unref();
