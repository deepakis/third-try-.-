// Set the OBS program scene from the command line — handy for resetting a demo.
//
//   OBS_HOST=127.0.0.1 node tools/obs_set_scene.mjs "Camera A"
//
// Prints the program scene before and after.

import { createHash } from 'node:crypto';

const HOST = process.env.OBS_HOST ?? '10.82.181.253';
const PORT = Number(process.env.OBS_PORT ?? 4455);
const PASS = process.env.OBS_PASSWORD ?? 'C8RsC84pViTVESA5';
const target = process.argv[2];

if (!target) {
  console.error('usage: node tools/obs_set_scene.mjs "<scene name>"');
  process.exit(2);
}

const sha256b64 = (s) =>
  Buffer.from(createHash('sha256').update(s, 'utf8').digest()).toString('base64');
const authString = (p, salt, challenge) =>
  sha256b64(sha256b64(p + salt) + challenge);

const ws = new WebSocket(`ws://${HOST}:${PORT}/`);
let requestId = 0;
const requests = new Map();

const request = (requestType, requestData) => {
  const id = `r${++requestId}`;
  requests.set(id, requestType);
  ws.send(
    JSON.stringify({
      op: 6,
      d: { requestType, requestId: id, ...(requestData ? { requestData } : {}) },
    }),
  );
};

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
    request('GetSceneList');
  } else if (message.op === 7) {
    const { requestType, requestStatus, responseData } = message.d;
    if (requestType === 'GetSceneList') {
      console.log(`before: ${responseData.currentProgramSceneName}`);
      request('SetCurrentProgramScene', { sceneName: target });
    } else if (requestType === 'SetCurrentProgramScene') {
      console.log(
        requestStatus.result
          ? `after:  ${target}`
          : `failed: ${requestStatus.comment}`,
      );
      process.exit(requestStatus.result ? 0 : 1);
    }
  }
};

ws.onerror = () => {
  console.error(`cannot reach OBS at ws://${HOST}:${PORT}/`);
  process.exit(1);
};

setTimeout(() => {
  console.error('timed out');
  process.exit(1);
}, 8000);
