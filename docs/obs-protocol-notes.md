# OBS protocol notes (phase 1)

Record of how the endpoint was identified, written before any Flutter existed.
The protocol half is still exactly what the app speaks; the *page* described here
was the throwaway probe, and two details have since changed: the app binds a tile
to the scene with its own name (no positional fallback), and the scenes it drives
are `Full_Cam` and `Zoom_Cam`. See the [README](../README.md) for the app itself.

Goal back then: a single white screen with two giant buttons, **Camera A** and
**Camera B**. Before writing any Flutter, the endpoint was probed with plain
scripts. That probe changed the design, so read this first.

## What `10.82.181.253:4455` actually is

It is **not** a camera stream. It is OBS Studio's built-in websocket server:

```
$ curl -i http://10.82.181.253:4455/
HTTP/1.1 426 Upgrade Required
Server: WebSocket++/0.8.2

Hello frame: {"op":0,"d":{"authentication":{"challenge":"…","salt":"…"},
              "obsWebSocketVersion":"5.7.4","obsStudioVersion":"32.2.2","rpcVersion":1}}
```

So the thing we talk to is **obs-websocket 5.x (protocol v5)**, and "password" means
the v5 challenge/salt handshake, not a value you just send on connect:

```
auth = base64(sha256(base64(sha256(password + salt)) + challenge))
# then: {"op":1,"d":{"rpcVersion":1,"authentication":auth}}
# server answers {"op":2,…} = Identified  (wrong password => close 4009)
```

Password in use: `C8RsC84pViTVESA5` (the first password tried was rejected with 4009).

### Consequences for the UI

* One websocket connection for the whole app — requests multiplex over it with
  `requestId`s, so the two buttons share a socket instead of owning one each.
* `Camera A` / `Camera B` map naturally onto the **OBS program scene**: clicking a
  button switches the live output, and OBS pushes `CurrentProgramSceneChanged`
  events back so the UI can highlight which camera is live.
* A real camera feed means adding a video-capture source to each scene *in OBS*.
  Our backend exposes OBS state, not pixels.

## Current OBS state (fresh install)

| item | value |
| --- | --- |
| scenes | `Scene`, plus `Camera A` / `Camera B` created by this test page |
| scene items | none — both camera scenes are still empty (they render black) |
| inputs | `Desktop Audio`, `Mic/Aux` — no video capture device yet |
| video | 1092×614 @ 30fps, not streaming, not recording |
| virtual camera | off |

## Files

| path | what it does |
| --- | --- |
| [public/index.html](public/index.html) | The white screen with the two giant buttons. Connects, authenticates, switches the program scene, live-highlights the active camera. |
| [tools/obs_probe.mjs](tools/obs_probe.mjs) | Authenticates and prints `GetSceneList` / `GetVersion`. First thing to run when something breaks. |
| [tools/obs_inspect.mjs](tools/obs_inspect.mjs) | Dumps scenes, scene items, inputs, video settings, stream/record status. |
| [tools/verify_page_auth.mjs](tools/verify_page_auth.mjs) | Tests the SHA-256 + auth code lifted out of the page against `node:crypto` and known vectors. |

## Running it

```bash
node tools/obs_probe.mjs        # is OBS reachable + is the password right?
node tools/verify_page_auth.mjs # auth crypto still correct?
# then open public/index.html
```

The page must be served over `http://` (or opened as a file) — an `https://` page
cannot open a `ws://` socket to OBS (mixed content), and the page logs a warning
if it detects that.

## Decisions baked into the harness

* **Scene mapping is deterministic.** If OBS has scenes named exactly `Camera A` /
  `Camera B`, those are used. Otherwise the page falls back to scene order (first
  scene → A, second → B) and says so in the log. The two buttons can never claim
  the same scene.
* **"auto-create missing scenes"** (checkbox, on by default) uses `CreateScene` so
  the buttons do something visible on a fresh install. Turn it off to make the
  page read-only. The scenes it created are currently saved in OBS — delete them
  in OBS if you don't want them.
* **SHA-256 is implemented inline** rather than via `crypto.subtle`, because
  `crypto.subtle` only exists in a secure context (https / localhost) and this
  page may be served from a plain LAN origin.

## Phase 2: what the transforms actually do (measured)

All of this was measured against the live OBS 32.2.2 / obs-websocket 5.7.4, by
sending a transform and reading it straight back — see `tools/obs_probe.mjs`'s
throwaway sibling and the permanent `tools/obs_frame_probe.mjs`.

| Finding | Detail |
| --- | --- |
| `alignment: 0` is kept | The centre anchor survives a round trip as `0`, so a centred item stays centred. An earlier revision of this app sent `alignment: 5` (LEFT\|TOP) with a centre position, which hangs the item off the bottom-right; the constants live in `auto_setup.dart` for that reason. |
| `GetSceneItemTransform` is partial | `width`/`height` are `sourceWidth × scaleX`, **not** the bounds-derived size. A bounds shot's on-screen box has to be computed from `boundsWidth`/`boundsHeight` plus the anchor, not from `width`. |
| OBS only changes the fields it is sent | Leaving `scaleX` out of a payload leaves the *previous* scale on the item: a scene that was zoomed once and then re-framed as a box kept `scale: 1.3` and cropped. Send a complete snapshot. |
| `RemoveScene` on the live scene | Refused. Cut to another scene first, or the request fails (`requestStatus.result: false`). |
| The scene list lags a removal | Straight after deleting, `GetSceneList` can still name the scene. A rebuild that trusts it skips `CreateScene` and then fails on `GetSceneItemId` with "No source was found by the name of `X` within the canvas `Main`". Poll until the list agrees. |
| A scene only renders while it is live | `GetSourceScreenshot` of a scene that isn't on air comes back black, and so does any scene whose camera device is asleep. That is why the render check swaps in a colour source and cuts to it. |
| float32 transform storage | `scaleX: 1.3` reads back as `1.2999999523162842` — compare with a tolerance. |

## Pairing: what OBS hands you, and what it says when it goes wrong

**Tools → WebSocket Server Settings → Show Connect Info** displays a QR code
beside the string it encodes. The payload changed in obs-websocket 5.0.0
(Sept 2022):

| Version | QR / connect-info payload |
| --- | --- |
| 5.0.0 and later (this install: 5.7.4) | `obsws://[host]:[port]/[password]` |
| before 5.0.0 | `obswebsocket|[host]:[port]|[password]` |

`obswss://` exists in the protocol for TLS; OBS Studio's own server offers no TLS,
so a pasted `obswss://` line is dialled as `ws://` — and the app is explicit about
that rather than implying it negotiated TLS.

The line is split by hand rather than with `Uri.parse`, because the password sits
in the path and may itself contain `/`, `#` or `?` — which a URI parser would read
as a path separator or a fragment.

### What a failed connection actually tells you

obs-websocket names exactly one failure itself: it closes the socket with **4009**
(`Authentication failed`) when the password is wrong. The rest has to be inferred,
and what is inferable differs by platform:

| Signal | Meaning | Available |
| --- | --- | --- |
| close code `4009` | the password is wrong | `WebSocketChannel.closeCode`, on both platforms |
| `Connection refused` (10061 / 111 / 61) | the host answered, nothing is on the port | desktop only — matched on the message text, since `dart:io` is absent from the web build |
| any other connect failure | never got to the host at all | both; a browser does not separate a DNS failure from a refused port |
| `SecurityError: … insecure WebSocket …` | an `https://` page may not open a `ws://` socket | web only, and it is refused before a request leaves the browser |

The client reads `closeCode` in `onDone` and tags the status with it. That is what
lets pairing say *"the password is wrong"* instead of *"connection failed"* — the
two have nothing in common as fixes.

### A failed connect reports itself twice

Measured on Windows, connecting to `127.0.0.1:1` (nothing listening). Payload of
the finding: `WebSocketChannel` surfaces a failed connection on **two** paths, and
the useless one arrives first.

* the stream's `onDone` fires straight away — `package:web_socket_channel`'s
  internal `StreamChannelController` is synchronous, so the adapter closing its
  local sink reaches the listener before the `ready` future's error is resumed;
* `channel.ready` then completes with the error, which is the call that carries
  the *reason* (`Connection refused`, errno `10061`, or "was not upgraded to
  websocket").

So `onDone` sees a close with **no** close code and no session, and a naive
handler reports "disconnected" — overwriting the real diagnosis a moment later.
The client tracks whether the current attempt already failed before the socket
came up and stays quiet in that case, so a dead port reports *refused* rather
than a bare disconnect. A live test asserts exactly that, and the first version
of this code got it wrong in precisely that way.

## Next step: the Flutter version

`web_socket_channel` is the right package; the protocol work is done, so the port is
mechanical:

1. `flutter pub add web_socket_channel`
2. `WebSocketChannel.connect(Uri.parse('ws://10.82.181.253:4455/'))`, send `{"op":1,…}`
   with the same auth string, then `SetCurrentProgramScene` on tap.
3. Two `Expanded` buttons in a `Row` on a white `Scaffold` — the CSS above is the
   reference for states (idle / busy / live / error).
4. Android needs `INTERNET` permission and cleartext `ws://` allowed; iOS needs an
   ATS exception for the LAN host. Desktop/web builds need nothing extra.

Also worth deciding: whether the buttons should switch a scene (current behaviour)
or start/stop OBS's virtual camera per source.
