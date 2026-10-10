// Read-only dump of every OBS scene: its items, how each one is framed, and where
// the picture actually lands in the rendered frame.
//
//   OBS_HOST=127.0.0.1 node tools/obs_scene_dump.mjs
//
// Used to confirm what a setup run actually left behind in OBS. The pixel probe
// exists because a scene item transform describes intent — it does not prove the
// camera ends up in the corner the shot claims.

import { createHash } from 'node:crypto';
import { inflateSync } from 'node:zlib';

const HOST = process.env.OBS_HOST ?? '10.82.181.253';
const PORT = Number(process.env.OBS_PORT ?? 4455);
const PASS = process.env.OBS_PASSWORD ?? 'C8RsC84pViTVESA5';

const sha256b64 = (s) =>
  Buffer.from(createHash('sha256').update(s, 'utf8').digest()).toString('base64');
const authString = (p, salt, challenge) =>
  sha256b64(sha256b64(p + salt) + challenge);

const ws = new WebSocket(`ws://${HOST}:${PORT}/`);
let seq = 0;
const pending = new Map();

function request(requestType, requestData) {
  const requestId = `r${++seq}`;
  const done = new Promise((resolve, reject) =>
    pending.set(requestId, { resolve, reject }),
  );
  ws.send(
    JSON.stringify({
      op: 6,
      d: { requestType, requestId, ...(requestData ? { requestData } : {}) },
    }),
  );
  return done;
}

function describe(transform) {
  const parts = [];
  if (transform.boundsType && transform.boundsType !== 'OBS_BOUNDS_NONE') {
    parts.push(
      `${transform.boundsType} ${Math.round(transform.boundsWidth)}x${Math.round(transform.boundsHeight)}`,
    );
  }
  parts.push(`scale ${Number(transform.scaleX).toFixed(3)}`);
  parts.push(`pos ${Math.round(transform.positionX)},${Math.round(transform.positionY)}`);
  parts.push(`align ${transform.alignment}`);
  return parts.join(' · ');
}

/// Decodes an 8-bit RGB/RGBA PNG. Enough for an OBS screenshot.
function decodePng(buffer) {
  let offset = 8;
  let width = 0;
  let height = 0;
  let colorType = 0;
  const idat = [];
  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      colorType = data.readUInt8(9);
      if (data.readUInt8(8) !== 8) throw new Error('expected an 8-bit PNG');
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
    offset += length + 12;
  }
  const channels = colorType === 6 ? 4 : 3;
  const raw = inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const out = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const prev = y === 0 ? Buffer.alloc(stride) : out.subarray((y - 1) * stride, y * stride);
    const at = y * stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= channels ? out[at + x - channels] : 0;
      const b = prev[x];
      const c = x >= channels ? prev[x - channels] : 0;
      let value = line[x];
      if (filter === 1) value += a;
      else if (filter === 2) value += b;
      else if (filter === 3) value += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a);
        const pb = Math.abs(p - b);
        const pc = Math.abs(p - c);
        value += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[at + x] = value & 0xff;
    }
  }
  return { width, height, channels, pixels: out };
}

/// The box the lit part of the frame occupies, as a share of the canvas: a
/// webcam picture against OBS's black background.
function litBox(png) {
  const { width, height, channels, pixels } = png;
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  let lit = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const at = (y * width + x) * channels;
      const luma =
        0.2126 * pixels[at] + 0.7152 * pixels[at + 1] + 0.0722 * pixels[at + 2];
      if (luma <= 24) continue;
      lit++;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return 'nothing lit (camera asleep?)';
  const pct = (n, of) => `${Math.round((n / of) * 100)}%`;
  return (
    `lit ${pct(minX, width)}–${pct(maxX + 1, width)} x, ${pct(minY, height)}–${pct(maxY + 1, height)} y` +
    ` · ${pct(lit, width * height)} of frame`
  );
}

ws.onmessage = async (event) => {
  const message = JSON.parse(event.data);

  if (message.op === 0) {
    const auth = message.d.authentication;
    ws.send(
      JSON.stringify({
        op: 1,
        d: {
          rpcVersion: 1,
          authentication: auth
            ? authString(PASS, auth.salt, auth.challenge)
            : undefined,
        },
      }),
    );
    return;
  }
  if (message.op === 7) {
    const entry = pending.get(message.d.requestId);
    if (entry) {
      pending.delete(message.d.requestId);
      if (message.d.requestStatus?.result) entry.resolve(message.d.responseData ?? {});
      else entry.reject(new Error(JSON.stringify(message.d.requestStatus)));
    }
    return;
  }
  if (message.op === 2) {
    const video = await request('GetVideoSettings');
    console.log(
      `canvas ${video.baseWidth}x${video.baseHeight} @ ${video.fpsNumerator}fps`,
    );
    const list = await request('GetSceneList');
    console.log(`program scene: ${list.currentProgramSceneName}`);
    for (const scene of list.scenes) {
      const items = await request('GetSceneItemList', {
        sceneName: scene.sceneName,
      });
      const live = scene.sceneName === list.currentProgramSceneName ? ' (live)' : '';
      console.log(`\n${scene.sceneName}${live} — ${items.sceneItems.length} item(s)`);
      for (const item of items.sceneItems) {
        const t = await request('GetSceneItemTransform', {
          sceneName: scene.sceneName,
          sceneItemId: item.sceneItemId,
        });
        console.log(
          `  · ${item.sourceName}  [${describe(t.sceneItemTransform ?? {})}]`,
        );
      }
      if (items.sceneItems.length > 0) {
        // Rendered proof, at 1:8 scale.
        try {
          const shot = await request('GetSourceScreenshot', {
            sourceName: scene.sceneName,
            imageFormat: 'png',
            imageWidth: Math.round(video.baseWidth / 8),
            imageHeight: Math.round(video.baseHeight / 8),
          });
          const base64 = shot.imageData.replace(/^data:[^,]+,/, '');
          console.log(`    ${litBox(decodePng(Buffer.from(base64, 'base64')))}`);
        } catch (error) {
          console.log(`    (no screenshot: ${error.message})`);
        }
      }
    }
    process.exit(0);
  }
};

ws.onerror = () => {
  console.error(`cannot reach OBS at ws://${HOST}:${PORT}/`);
  process.exit(1);
};
setTimeout(() => {
  console.error('timed out');
  process.exit(1);
}, 30000);
