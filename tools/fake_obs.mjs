// A dependency-free stand-in for obs-websocket v5, for testing the app when the
// real OBS box (10.82.181.253:4455) isn't reachable.
//
//   node tools/fake_obs.mjs                 # listens on 127.0.0.1:4455
//   PORT=4456 node tools/fake_obs.mjs       # or somewhere else
//
// Then run the app against it:
//   flutter run -d web-server --dart-define=OBS_HOST=127.0.0.1
//
// It implements just the requests the app makes, and logs every cut so a test
// can assert on it.

import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';

const PORT = Number(process.env.PORT ?? 4455);
const HOST = process.env.HOST ?? '127.0.0.1';
const PASSWORD = process.env.PASSWORD ?? 'C8RsC84pViTVESA5';
const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// 1x1 baseline JPEG — enough for the preview path to decode something.
const TINY_JPEG =
  '/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a' +
  'HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA' +
  'AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==';

// SCENES="Scene" simulates a fresh OBS install (nothing set up yet), which is
// what the first-run Auto-Configure banner is for.
const scenes = (process.env.SCENES ?? 'Camera A, Camera B, Scene')
  .split(',')
  .map((name) => name.trim())
  .filter((name) => name.length > 0)
  .map((name, index) => ({
    index,
    name,
    uuid: `scene-${index}`,
    items: index === 0 ? 1 : 0,
  }));
let program = scenes[0]?.name ?? '';

const b64 = (buf) => Buffer.from(buf).toString('base64');
const sha256b64 = (s) => b64(createHash('sha256').update(s, 'utf8').digest());

const stamp = () => new Date().toISOString().slice(11, 23);
const log = (...args) => console.log(`${stamp()}  ${args.join(' ')}`);

/* ----------------------------- websocket plumbing ----------------------------- */

function acceptKey(key) {
  return createHash('sha1').update(key + GUID).digest('base64');
}

/** Server -> client text frame (never masked). */
function encodeFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x81, length]);
  } else if (length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  return Buffer.concat([header, payload]);
}

function encodeClose(code) {
  const payload = Buffer.alloc(2);
  payload.writeUInt16BE(code, 0);
  return Buffer.concat([Buffer.from([0x88, 2]), payload]);
}

/** Pulls complete frames out of a growing buffer. */
function parseFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (buffer.length - offset >= 2) {
    const first = buffer[offset];
    const opcode = first & 0x0f;
    const masked = (buffer[offset + 1] & 0x80) !== 0;
    let length = buffer[offset + 1] & 0x7f;
    let cursor = offset + 2;
    if (length === 126) {
      if (buffer.length - cursor < 2) break;
      length = buffer.readUInt16BE(cursor);
      cursor += 2;
    } else if (length === 127) {
      if (buffer.length - cursor < 8) break;
      length = Number(buffer.readBigUInt64BE(cursor));
      cursor += 8;
    }
    let mask;
    if (masked) {
      if (buffer.length - cursor < 4) break;
      mask = buffer.subarray(cursor, cursor + 4);
      cursor += 4;
    }
    if (buffer.length - cursor < length) break;
    const payload = Buffer.from(buffer.subarray(cursor, cursor + length));
    if (mask) {
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    }
    frames.push({ opcode, payload });
    offset = cursor + length;
  }
  return { frames, rest: buffer.subarray(offset) };
}

/* --------------------------------- the server --------------------------------- */

const sockets = new Set();

function broadcast(eventType, eventData) {
  const frame = encodeFrame(
    JSON.stringify({ op: 5, d: { eventType, eventIntent: 1, eventData } }),
  );
  for (const socket of sockets) socket.write(frame);
}

function handleRequest(session, data) {
  const { requestType, requestId, requestData } = data;
  const reply = (responseData, ok = true, comment) =>
    session.send({
      op: 7,
      d: {
        requestType,
        requestId,
        requestStatus: ok
          ? { result: true, code: 100 }
          : { result: false, code: 204, comment: comment ?? 'failed' },
        ...(responseData ? { responseData } : {}),
      },
    });

  switch (requestType) {
    case 'GetSceneList':
      return reply({
        currentProgramSceneName: program,
        currentPreviewSceneName: null,
        scenes: scenes.map((s) => ({
          sceneIndex: s.index,
          sceneName: s.name,
          sceneUuid: s.uuid,
        })),
      });

    case 'GetSceneItemList': {
      const name = requestData?.sceneName;
      const scene = scenes.find((s) => s.name === name);
      if (!scene) return reply(null, false, `no scene named ${name}`);
      return reply({
        sceneItems: Array.from({ length: scene.items }, (_, i) => ({
          sceneItemId: i + 1,
          sourceName: `Source ${i + 1}`,
        })),
      });
    }

    case 'GetSourceScreenshot':
      return reply({ imageData: `data:image/jpeg;base64,${TINY_JPEG}` });

    case 'CreateScene': {
      const name = requestData?.sceneName;
      if (scenes.some((s) => s.name === name)) {
        return reply(null, false, `scene ${name} already exists`);
      }
      scenes.push({ index: scenes.length, name, uuid: `scene-${name}`, items: 0 });
      log(`scene created: ${name}`);
      broadcast('SceneCreated', { sceneName: name, sceneUuid: `scene-${name}` });
      broadcast('SceneListChanged', { scenes });
      return reply({});
    }

    case 'SetCurrentProgramScene': {
      const name = requestData?.sceneName;
      const scene = scenes.find((s) => s.name === name);
      if (!scene) return reply(null, false, `no scene named ${name}`);
      const previous = program;
      program = name;
      log(`CUT  ${previous} -> ${name}`);
      broadcast('CurrentProgramSceneChanged', {
        sceneName: name,
        sceneUuid: scene.uuid,
      });
      return reply({});
    }

    default:
      return reply(null, false, `unsupported request type: ${requestType}`);
  }
}

function handleConnection(socket, remote) {
  const session = {
    identified: false,
    salt: b64(randomBytes(32)),
    challenge: b64(randomBytes(32)),
    send: (message) => socket.write(encodeFrame(JSON.stringify(message))),
  };
  sockets.add(socket);
  log(`client connected from ${remote}`);

  session.send({
    op: 0,
    d: {
      obsWebSocketVersion: '5.7.4-fake',
      obsStudioVersion: '32.2.2-fake',
      rpcVersion: 1,
      authentication: { challenge: session.challenge, salt: session.salt },
    },
  });

  let buffered = Buffer.alloc(0);

  socket.on('data', (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    const { frames, rest } = parseFrames(buffered);
    buffered = rest;

    for (const frame of frames) {
      if (frame.opcode === 0x8) {
        socket.end();
        return;
      }
      if (frame.opcode === 0x9) {
        socket.write(Buffer.concat([Buffer.from([0x8a, frame.payload.length]), frame.payload]));
        continue;
      }
      if (frame.opcode !== 0x1) continue;

      let message;
      try {
        message = JSON.parse(frame.payload.toString('utf8'));
      } catch {
        log('ignored malformed frame');
        continue;
      }

      if (message.op === 1) {
        const expected = sha256b64(
          sha256b64(PASSWORD + session.salt) + session.challenge,
        );
        if (message.d?.authentication !== expected) {
          log('auth REJECTED');
          socket.write(encodeClose(4009));
          socket.end();
          return;
        }
        session.identified = true;
        log('auth accepted (password matches)');
        session.send({ op: 2, d: { negotiatedRpcVersion: 1 } });
        continue;
      }

      if (message.op === 6) {
        if (!session.identified) {
          socket.write(encodeClose(4009));
          socket.end();
          return;
        }
        handleRequest(session, message.d ?? {});
        continue;
      }

      log(`unhandled op ${message.op}`);
    }
  });

  const cleanup = () => {
    sockets.delete(socket);
    log('client disconnected');
  };
  socket.on('close', cleanup);
  socket.on('error', cleanup);
}

const server = createServer((_, res) => {
  // Plain HTTP gets the same "upgrade required" the real server sends.
  res.writeHead(426, { Server: 'WebSocket++/0.8.2-fake' });
  res.end();
});

server.on('upgrade', (req, socket) => {
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.destroy();
    return;
  }
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${acceptKey(key)}\r\n\r\n`,
  );
  socket.setNoDelay(true);
  handleConnection(socket, req.socket.remoteAddress);
});

server.listen(PORT, HOST, () => {
  log(`fake obs-websocket on ws://${HOST}:${PORT}/ (password: ${PASSWORD})`);
  log(`scenes: ${scenes.map((s) => s.name).join(', ')} · program: ${program}`);
});
