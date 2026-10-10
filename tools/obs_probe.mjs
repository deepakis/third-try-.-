// Probe #2: the endpoint is obs-websocket v5 (OBS Studio 32.2.2).
// Auth is challenge/salt based, not a plain password send.
//
// Run:  node tools/obs_probe.mjs

import { createHash } from 'node:crypto';

// Override the target when OBS is reachable somewhere else, e.g.
//   OBS_HOST=127.0.0.1 node tools/obs_probe.mjs
const HOST = process.env.OBS_HOST ?? '10.82.181.253';
const PORT = Number(process.env.OBS_PORT ?? 4455);
const PASS = process.env.OBS_PASSWORD ?? 'C8RsC84pViTVESA5';

const b64 = (buf) => Buffer.from(buf).toString('base64');
const sha256b64 = (s) => b64(createHash('sha256').update(s, 'utf8').digest());

// obs-websocket v5 auth string
function authString(password, salt, challenge) {
  return sha256b64(sha256b64(password + salt) + challenge);
}

const ws = new WebSocket(`ws://${HOST}:${PORT}/`);
let pingTimer = null;

ws.onopen = () => console.log('socket open');

ws.onmessage = (e) => {
  const msg = JSON.parse(e.data);
  switch (msg.op) {
    case 0: { // Hello
      const { authentication, rpcVersion, obsWebSocketVersion, obsStudioVersion } = msg.d;
      console.log(`Hello: obs-websocket ${obsWebSocketVersion}, OBS ${obsStudioVersion}, rpcVersion ${rpcVersion}`);
      const d = { rpcVersion: 1 };
      if (authentication) {
        d.authentication = authString(PASS, authentication.salt, authentication.challenge);
        console.log('sending password challenge response');
      } else {
        console.log('no auth required by server');
      }
      ws.send(JSON.stringify({ op: 1, d }));
      break;
    }
    case 2: // Identified
      console.log('IDENTIFIED — password accepted');
      request('GetSceneList');
      request('GetVersion');
      pingTimer = setInterval(() => ws.send(JSON.stringify({ op: 9, d: {} })), 2000);
      setTimeout(() => {
        clearInterval(pingTimer);
        console.log('--- done ---');
        ws.close();
        process.exit(0);
      }, 3000);
      break;
    case 5: // Event
      console.log(`Event: ${msg.d.eventType}`, JSON.stringify(msg.d.eventData).slice(0, 200));
      break;
    case 7: { // RequestResponse
      const { requestType, requestStatus, responseData } = msg.d;
      console.log(`Response ${requestType}: ok=${requestStatus.result}`);
      console.log('  ' + JSON.stringify(responseData).slice(0, 900));
      break;
    }
    case 9: // RequestBatchResponse
      console.log('BatchResponse', JSON.stringify(msg.d).slice(0, 400));
      break;
    default:
      console.log('op=' + msg.op, JSON.stringify(msg.d).slice(0, 200));
  }
};

let reqId = 0;
function request(requestType, requestData) {
  const requestId = `req-${++reqId}`;
  console.log(`-> ${requestType}`);
  ws.send(JSON.stringify({ op: 6, d: { requestType, requestId, ...(requestData ? { requestData } : {}) } }));
}

ws.onclose = (e) => console.log(`closed code=${e.code} reason=${JSON.stringify(e.reason)}`);
ws.onerror = () => console.log('error');

setTimeout(() => {
  console.log('--- timeout, no identification ---');
  process.exit(1);
}, 8000);
