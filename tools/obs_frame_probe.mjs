// Renders the app's own shot payloads against a bright source and measures where
// the picture actually lands.
//
//   OBS_LAYOUT_DUMP=/tmp/frames.json OBS_INTEGRATION=1 OBS_LAYOUT_INTEGRATION=1 \
//     flutter test test/obs_integration_test.dart --plain-name "from-scratch rebuild"
//   OBS_HOST=127.0.0.1 OBS_PAYLOAD=/tmp/frames.json node tools/obs_frame_probe.mjs
//
// Why: a scene item transform read back out of OBS describes intent. This probe
// puts a solid white source through the very same payload, screenshots the
// result, and checks the lit pixels are inside the box the shot claims. It needs
// no camera light, so it works on a machine whose webcam is asleep.
//
// Each case is built in its own temporary scene, which is removed afterwards.

import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';

const HOST = process.env.OBS_HOST ?? '127.0.0.1';
const PORT = Number(process.env.OBS_PORT ?? 4455);
const PASS = process.env.OBS_PASSWORD ?? 'C8RsC84pViTVESA5';
const PAYLOAD = process.env.OBS_PAYLOAD ?? '/tmp/rig_frames.json';

const sha = (s) =>
  Buffer.from(createHash('sha256').update(s, 'utf8').digest()).toString('base64');
const authString = (p, salt, ch) => sha(sha(p + salt) + ch);

const cases = JSON.parse(readFileSync(PAYLOAD, 'utf8'));

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

/// Bounding box of lit pixels, in the same canvas pixels the payload used.
function litBox(png, canvasWidth, canvasHeight) {
  const { width, height, channels, pixels } = png;
  const sx = canvasWidth / width;
  const sy = canvasHeight / height;
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const at = (y * width + x) * channels;
      const luma =
        0.2126 * pixels[at] + 0.7152 * pixels[at + 1] + 0.0722 * pixels[at + 2];
      if (luma <= 24) continue;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return null;
  return {
    left: minX * sx,
    top: minY * sy,
    right: (maxX + 1) * sx,
    bottom: (maxY + 1) * sy,
  };
}

const ws = new WebSocket(`ws://${HOST}:${PORT}/`);
let seq = 0;
const pending = new Map();
const request = (requestType, requestData) => {
  const requestId = `f${++seq}`;
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
};

ws.onmessage = async (event) => {
  const message = JSON.parse(event.data);
  if (message.op === 0) {
    const auth = message.d.authentication;
    ws.send(
      JSON.stringify({
        op: 1,
        d: {
          rpcVersion: 1,
          authentication: auth ? authString(PASS, auth.salt, auth.challenge) : undefined,
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
  if (message.op !== 2) return;

  const video = await request('GetVideoSettings');
  const { baseWidth: W, baseHeight: H } = video;
  const before = await request('GetSceneList');
  const original = before.currentProgramSceneName;

  let failures = 0;
  for (const [index, entry] of cases.entries()) {
    const scene = `Probe_Frame_${index}`;
    const source = `Probe_Bright_${index}`;
    const list = await request('GetSceneList');
    if (list.scenes.some((s) => s.sceneName === scene)) {
      await request('RemoveScene', { sceneName: scene });
    }
    await request('CreateScene', { sceneName: scene });
    // A source the size of the canvas, so "where does the picture land" is a
    // question the pixels can actually answer.
    await request('CreateInput', {
      sceneName: scene,
      inputName: source,
      inputKind: 'color_source_v3',
      inputSettings: { color: 0xffffffff, width: W, height: H },
    });
    await request('SetSceneItemTransform', {
      sceneName: scene,
      sceneItemId: (
        await request('GetSceneItemId', { sceneName: scene, sourceName: source })
      ).sceneItemId,
      sceneItemTransform: entry.transform,
    });

    // Only the live scene renders, so put this one on air for the shot.
    await request('SetCurrentProgramScene', { sceneName: scene });
    await new Promise((r) => setTimeout(r, 700));
    const shot = await request('GetSourceScreenshot', {
      sourceName: scene,
      imageFormat: 'png',
      imageWidth: W,
      imageHeight: H,
    });
    const measured = litBox(
      decodePng(Buffer.from(shot.imageData.replace(/^data:[^,]+,/, ''), 'base64')),
      W,
      H,
    );
    await request('RemoveScene', { sceneName: scene });

    const name = entry.layout;
    if (!measured) {
      failures++;
      console.log(`${name}: FAIL — the frame rendered nothing`);
      continue;
    }
    // Sampling is 1:1 here, but OBS rounds transforms and the lit edge can fall
    // half a pixel inside, so allow a couple of pixels.
    const tolerance = 3;
    const rounded = (box) =>
      `x ${Math.round(box.left)}–${Math.round(box.right)}, y ${Math.round(box.top)}–${Math.round(box.bottom)}`;

    const box = {
      left: entry.box.left,
      top: entry.box.top,
      right: entry.box.left + entry.box.width,
      bottom: entry.box.top + entry.box.height,
    };

    // A bleed covers the canvas (the zoom hangs off it). A box sits in its
    // corner: inside the box the shot claims, touching the edge it is anchored
    // to, and on the right side of the canvas to be useful beside content.
    const isBleed = box.left <= tolerance && box.top <= tolerance;
    const covers = (b) =>
      b.left <= tolerance &&
      b.top <= tolerance &&
      b.right >= W - tolerance &&
      b.bottom >= H - tolerance;
    const insideBox = (b) =>
      b.left >= box.left - tolerance &&
      b.top >= box.top - tolerance &&
      b.right <= box.right + tolerance &&
      b.bottom <= box.bottom + tolerance;
    const centreX = (measured.left + measured.right) / 2;
    const centreY = (measured.top + measured.bottom) / 2;
    const corner = entry.layout === 'topPiP'
      ? centreY < H / 2
      : entry.layout === 'bottomPiP'
        ? centreY > H / 2
        : true;
    const ok = isBleed
      ? covers(measured)
      : insideBox(measured) &&
        centreX > W / 2 &&
        corner &&
        Math.abs(measured.right - box.right) <= tolerance;
    if (!ok) failures++;
    console.log(
      `${name}: ${ok ? 'PASS' : 'FAIL'} — box ${rounded(box)}, picture ${rounded(measured)}` +
        (isBleed ? ' (bleed: must cover the canvas)' : ' (box: right of centre, in the box)'),
    );
  }

  if (original) await request('SetCurrentProgramScene', { sceneName: original });
  console.log(`\nprogram scene back to ${original}`);
  console.log(failures === 0 ? 'all shots rendered inside their box' : `${failures} shot(s) off`);
  process.exit(failures === 0 ? 0 : 1);
};

ws.onerror = () => {
  console.error(`cannot reach OBS at ws://${HOST}:${PORT}/`);
  process.exit(1);
};
setTimeout(() => {
  console.error('timed out');
  process.exit(1);
}, 60000);
