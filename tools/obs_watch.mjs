// Watch OBS and print every program-scene change until interrupted.
//
//   OBS_HOST=127.0.0.1 node tools/obs_watch.mjs
//   OBS_HOST=127.0.0.1 node tools/obs_watch.mjs 45     # stop after 45s
//
// This is how the teleprompter's hands-free cuts are verified: start this, then
// let the prompter scroll and do nothing else.

import { createHash } from 'node:crypto';

const HOST = process.env.OBS_HOST ?? '10.82.181.253';
const PORT = Number(process.env.OBS_PORT ?? 4455);
const PASS = process.env.OBS_PASSWORD ?? 'C8RsC84pViTVESA5';
const seconds = Number(process.argv[2] ?? 0);

const sha256b64 = (s) =>
  Buffer.from(createHash('sha256').update(s, 'utf8').digest()).toString('base64');
const authString = (p, salt, challenge) =>
  sha256b64(sha256b64(p + salt) + challenge);

const started = Date.now();
const stamp = () => `+${((Date.now() - started) / 1000).toFixed(1)}s`;

let last = null;
const ws = new WebSocket(`ws://${HOST}:${PORT}/`);

ws.onmessage = (event) => {
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
  } else if (message.op === 2) {
    console.log(`${stamp()}  watching ${HOST}:${PORT}`);
    // Events, not polling: CurrentProgramSceneChanged is pushed by OBS.
    ws.send(JSON.stringify({ op: 6, d: { requestType: 'GetSceneList', requestId: 'init' } }));
  } else if (message.op === 5) {
    if (message.d.eventType !== 'CurrentProgramSceneChanged') return;
    const name = message.d.eventData?.sceneName;
    if (name === last) return;
    last = name;
    console.log(`${stamp()}  CUT -> ${name}`);
  } else if (message.op === 7 && message.d.requestType === 'GetSceneList') {
    const name = message.d.responseData?.currentProgramSceneName;
    last = name;
    console.log(`${stamp()}  start: ${name}`);
  }
};

ws.onclose = (event) => {
  console.log(`${stamp()}  disconnected (${event.code})`);
  process.exit(0);
};
ws.onerror = () => {
  console.error(`cannot reach OBS at ws://${HOST}:${PORT}/`);
  process.exit(1);
};

if (seconds > 0) {
  setTimeout(() => {
    console.log(`${stamp()}  done (final: ${last})`);
    process.exit(0);
  }, seconds * 1000);
}
