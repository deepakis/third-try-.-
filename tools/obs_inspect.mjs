// Dump OBS scenes, scene items and inputs so we know what "Camera A"/"Camera B" can map to.
// Run:  node tools/obs_inspect.mjs

import { createHash } from 'node:crypto';

const HOST = '10.82.181.253';
const PORT = 4455;
const PASS = 'C8RsC84pViTVESA5';
const sha256b64 = (s) => Buffer.from(createHash('sha256').update(s, 'utf8').digest()).toString('base64');
const authString = (p, salt, ch) => sha256b64(sha256b64(p + salt) + ch);

const ws = new WebSocket(`ws://${HOST}:${PORT}/`);
const requests = new Map();
let id = 0;

function request(requestType, requestData) {
  const requestId = `r${++id}`;
  if (requestData) requests.set(requestId, { requestType, requestData });
  console.log(`\n=== ${requestType} ${requestData ? JSON.stringify(requestData) : ''}`);
  ws.send(JSON.stringify({ op: 6, d: { requestType, requestId, ...(requestData ? { requestData } : {}) } }));
}

async function go() {
  request('GetSceneList');
  request('GetSceneItemList', { sceneName: 'Scene' });
  request('GetInputList');
  request('GetVirtualCamStatus');
  request('GetVideoSettings');
  request('GetStreamStatus');
  request('GetRecordStatus');
}

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  if (msg.op === 0) {
    const a = msg.d.authentication;
    ws.send(JSON.stringify({ op: 1, d: { rpcVersion: 1, authentication: a ? authString(PASS, a.salt, a.challenge) : undefined } }));
  } else if (msg.op === 2) {
    console.log('identified');
    go();
    setTimeout(() => process.exit(0), 1500);
  } else if (msg.op === 7) {
    console.log(JSON.stringify(msg.d.responseData, null, 1).slice(0, 2500));
  }
};

ws.onerror = () => console.log('error');
setTimeout(() => process.exit(1), 6000);
