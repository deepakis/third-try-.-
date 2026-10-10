# Open Flutter

A two-camera rig for course creators and tech reviewers, with one hook that a
button grid can't match: **the script cuts the video for you.**

You read a teleprompter hands-free. When a line carrying a cue tag crosses the
red reading line, OBS switches scene — no keyboard, no second operator, no
Stream Deck.

```
Welcome back to the channel. Today I'm wiring up a two-camera rig…
[CAM 1]                                     ← cut to the full-screen talking head
Everything you see behind me is one OBS scene…
[LAYOUT: PIP]                               ← cut to screen capture + camera in the corner
And there's the cut. Camera two is my screen capture…
```

## Your shots

The rig is a selection, not a fixed pair. At first run you pick up to three shots
and the app builds one OBS scene per shot:

| Shot | OBS scene | Where the camera goes |
| --- | --- | --- |
| Full | `Full_Cam` | Whole frame, fitted to the canvas |
| Zoom | `Zoom_Cam` | Centred 130% digital zoom (the edges are cropped) |
| Side | `Side_Cam` | Full-height strip down the right, room for content beside it |
| Bottom | `Bottom_Cam` | Box in the bottom-right corner, to sit over a screen share |
| Top | `Top_Cam` | The same box, top-right |

The order you pick is the order of the keys: the first shot is `1` / Camera A.
Slots stay position-named (`Camera A`, `Camera B`, …) because that is what the cue
tags address — `[CAM 2]` means the second button, whatever shot it holds. The
catalog lives in [lib/obs/layouts.dart](lib/obs/layouts.dart);
[lib/app_config.dart](lib/app_config.dart) holds the default selection (Full +
Zoom) that a fresh install starts from.

Every scene references the **same** camera source. That is deliberate: on Windows
a capture device is locked by its first source, so a second `dshow_input` on the
same webcam normally fails to start.

Each tile shows a live preview pulled from OBS (`GetSourceScreenshot`). Scenes
with no sources show a wireframe of the intended layout instead of OBS's black
frame — which doubles as a to-do list for building the scenes.

## Where the endpoint points

`10.82.181.253:4455` is **not** a camera stream: it is OBS Studio's built-in
websocket server, obs-websocket **5.7.4** on OBS **32.2.2**. The password is the
v5 challenge/salt handshake, not a value you send raw. Full write-up, including
the discovery probes: [docs/obs-protocol-notes.md](docs/obs-protocol-notes.md).

Reachability changes: while building this, OBS was running on *this* machine and
answering on `127.0.0.1:4455`, while the LAN address was not routable. Both are
covered by the config below.

## Pointing it at your OBS

The address is not compile-time only. On first run — and any time you tap the
address in the switcher's header — the app asks where OBS is, and remembers the
answer on the machine you paired from (`localStorage` on the web build, a JSON
file under the config directory on desktop).

OBS hands you everything in one line: **Tools → WebSocket Server Settings → Show
Connect Info** shows a QR code beside the string it encodes. Paste that line:

```
obsws://192.168.1.20:4455/hunter2
```

The same box takes the pre-5.0.0 `obswebsocket|192.168.1.20:4455|hunter2` form, a
bare `192.168.1.20:4455`, or a host on its own — and the three fields under it
stay editable, for reading an address off another screen. **Set up later** skips
pairing and drops you on the switcher, where the setup banner waits.

Pairing is step 1 of a three-step first run (`1 · Connect to OBS`, `2 · Pick your
shots`, `3 · Go live`). The strip is on the pairing screen; on the switcher the
same step appears as one line at the top of the setup card — deliberately one
card, not two stacked banners, because two of them took the space the cameras
need. Step 2 builds the shots the app already has (`Set up Full + Zoom`), with
**Change shots** beside it for choosing different ones: someone who has already
picked their shots is not asked to pick them again. Step 3 is the confirmation
that they are live. A launch over a rig that already works says none of it.

The header shows `host:port` while connected — tap it to point the app at a
different OBS — and only says **Connect…** when there is no socket to switch away
from, which it wrongly did over a working connection.

Nothing decodes the QR code yet. The paste box is the whole input path for now,
and it parses exactly the string a camera would decode, so a scanner is an
addition rather than a change of format.

A failed pairing says what to do about it, because "connection failed" is not a
useful sentence:

| What happened | What the app says | What it tells you to check |
| --- | --- | --- |
| obs-websocket closed `4009` | OBS is there — it rejected the password | copy the password out of Show Connect Info; a stray space is enough |
| Connection refused | something is at the host, nothing answers on the port | is OBS running, is the WebSocket server ticked, is the port the same |
| Unreachable / no reply | couldn't reach the host at all | same Wi-Fi? `127.0.0.1` means *this* computer; VPN, firewall, guest network, client isolation |
| `https://` page, `ws://` socket | the browser blocked it | serve the app over `http://`, or use the desktop build |

The first row is the one OBS names itself; the rest are inferred from how the
socket failed, which is why a browser cannot always tell a refused port from an
unreachable host.

`--dart-define=OBS_HOST=… / OBS_PASSWORD=…` still means something: a build given
those values prefills the pairing form, and it is the endpoint the switcher falls
back to when you skip pairing.

## Run it

```bash
# against the OBS box on the LAN (default)
flutter run -d web-server --web-port=8099

# against OBS on this machine
flutter run -d web-server --web-port=8099 --dart-define=OBS_HOST=127.0.0.1

# boot straight into the prompter (for recording the demo, or a kiosk build)
flutter run -d web-server --web-port=8099 --dart-define=START_SCREEN=prompter
```

`OBS_HOST`, `OBS_PORT`, `OBS_PASSWORD` and `START_SCREEN` are all
`--dart-define` overrides of [lib/app_config.dart](lib/app_config.dart).

Desktop builds work too (`flutter run -d windows`); a page served over `https://`
cannot open a `ws://` socket to OBS, so keep the app on `http://` or a file/local
origin.

### Controls

Switcher: tap a tile, or `1` / `2` to cut. `T` opens the prompter, `R` reconnects.
`auto-create scenes` (on by default) creates a missing scene so a tile always has
something to cut to.

Prompter: `space` pause/resume, `n` jump to the next cue, `r` restart, arrow keys
nudge, or drag the script by hand — auto-scroll resumes a second after you let go.
Speed and text size are live-adjustable in the control bar.

## Set up OBS

Point the app at an OBS that has never seen it and the switcher offers a
**Set up Full + Zoom** button — the shots on screen, built in OBS. It is the
primary action because those shots are usually already chosen, and the first-run
path for "my phone is on the Wi-Fi, now what?" is one click from here rather than
a tour of the shot picker. **Change shots** is the alternative. A run reports each
step as it lands.

A run is a **rebuild, from scratch**:

1. the app's own rig scenes (`Full_Cam`, `Zoom_Cam`, `Side_Cam`, `Bottom_Cam`,
   `Top_Cam`) are deleted if they exist, along with the camera source this app
   created (`Auto_Webcam`) — so the framing is what you just picked rather than
   whatever was left over;
2. then the picked shots are built.

Anything that would be deleted is listed in a confirmation first, and a run that
has nothing to delete doesn't ask. **Your own scenes and camera sources are never
removed** — the reset is scoped to the app's own scene names and to the source it
created itself, because on a stock install your scenes reference your camera and
deleting it would empty them. `Reset the rig in OBS` does step 1 on its own.

What a build sends, over the same connection as the tiles:

| Step | Request |
| --- | --- |
| 1 | `CreateScene` for each picked shot |
| 2 | `GetInputList` — reuse an existing camera, else `GetInputKindList` + `CreateInput` |
| 3 | `CreateSceneItem` — reference that one source from every scene |
| 4 | `SetSceneItemTransform` — full frame / strip / corner box / 130% zoom |

Details that matter in practice:

* The camera kind is **not hard-coded**: it asks OBS which kinds exist, so
  `dshow_input` (Windows), `av_capture_input` (macOS) and `v4l2_input` (Linux)
  all work from the same build.
* If it has to create a camera source, it then reads
  `GetInputPropertiesListPropertyItems` and selects a real device instead of the
  `Default` placeholder.
* Framing uses `boundsType: OBS_BOUNDS_SCALE_INNER`, so a camera of any
  resolution fits the canvas without a second thought.
* Every transform is sent as a **complete snapshot** (position, alignment,
  bounds, scale, crop, rotation). OBS only changes the fields it is given, and a
  live probe caught a scene that was zoomed once and then re-framed as a box
  keeping `scaleX: 1.3` — which quietly cropped the box.
* OBS stores transforms as float32, so `scaleX: 1.3` reads back as
  `1.2999999523162842`.
* The reset **waits until OBS stops listing** what it deleted. OBS's scene list
  lags a removal by a moment, and a rebuild straight after a reset would be told
  a scene still exists, skip creating it, and then fail to find it a request
  later. Both of the last two were found against a real OBS, not in a fake.

The alternative — OBS's own `Scene Collection → Export/Import` JSON — is a good
route for shipping a finished preset, but it is an all-or-nothing replacement of
the user's setup, which is why the app configures over the websocket instead.

## Cue tags

| Tag | Effect |
| --- | --- |
| `[CAM 1]`, `[CAM 2]` | cut to the 1st / 2nd slot |
| `[CAM 2: ZOOM]` | same as `[CAM 2]` — the detail after the colon is ignored |
| `[LAYOUT: FULL]` | full-frame shot (first slot) |
| `[LAYOUT: PIP]` / `SCREEN` / `SHARE` | screen-with-PiP shot (second slot) |
| anything else | shown in the script, logged as "nothing to switch to", never touches OBS |

Tags stay visible in the script in bold red brackets, because the presenter reads
past them. A cue fires when its line's centre crosses the reading line, and
re-arms if you scroll back above it, so re-reading a section re-fires the cut.

## Code map

| Path | What lives there |
| --- | --- |
| [lib/main.dart](lib/main.dart) | App shell; owns the single OBS connection both screens share, and swaps it when you re-pair |
| [lib/ui/connect_screen.dart](lib/ui/connect_screen.dart) | Pairing: paste the line OBS shows, or type it; advice per failure |
| [lib/obs/connection_target.dart](lib/obs/connection_target.dart) | An OBS endpoint, and the parser for the string OBS prints (and its QR encodes) |
| [lib/obs/endpoint_store.dart](lib/obs/endpoint_store.dart) | Remembering the paired endpoint: `localStorage` on web, a JSON file on desktop |
| [lib/obs/obs_client.dart](lib/obs/obs_client.dart) | obs-websocket v5 client on `web_socket_channel` (auth, requests, events, reconnect, close-code reporting) |
| [lib/obs/auto_setup.dart](lib/obs/auto_setup.dart) | Setup plan: shots → scenes → camera source → transforms, plus the reset |
| [lib/obs/layouts.dart](lib/obs/layouts.dart) | The shot catalog, and reading a rig back out of OBS |
| [lib/ui/rig_picker.dart](lib/ui/rig_picker.dart) | The shot picker dialog |
| [lib/ui/setup_banner.dart](lib/ui/setup_banner.dart) | The setup banner: pick shots, quick setup, reset |
| [lib/ui/layout_diagram.dart](lib/ui/layout_diagram.dart) | Wireframe of a shot, shared by the tiles and the picker |
| [lib/obs/obs_models.dart](lib/obs/obs_models.dart) | Slots, scenes, connection status, tile→scene binding rule |
| [lib/ui/switcher_screen.dart](lib/ui/switcher_screen.dart) | The two-tile switcher |
| [lib/ui/camera_tile.dart](lib/ui/camera_tile.dart) | Tile: preview, live state, layout wireframe |
| [lib/teleprompter/teleprompter_screen.dart](lib/teleprompter/teleprompter_screen.dart) | Reading line, auto-scroll, cue trigger |
| [lib/teleprompter/script_model.dart](lib/teleprompter/script_model.dart) | Script + cue-tag parsing |
| [lib/teleprompter/sample_script.dart](lib/teleprompter/sample_script.dart) | The demo script |

One connection, many requests: obs-websocket multiplexes on `requestId`, so the
switcher and the prompter are two views onto the same socket and both stay in
sync with OBS events.

## Verifying it

The opt-in tests are switched on with environment variables. PowerShell does
not accept the `VAR=1 command` prefix that shells use, so on Windows set them
first:

```powershell
$env:OBS_INTEGRATION='1'; $env:OBS_HOST='127.0.0.1'; flutter test test/obs_integration_test.dart
```

The forms below are POSIX shells.

```bash
flutter analyze                              # clean
flutter test                                 # the whole suite, no OBS needed
OBS_INTEGRATION=1 OBS_HOST=127.0.0.1 \
  flutter test test/obs_integration_test.dart   # against a live OBS

# also builds the scenes (mutates OBS)
OBS_INTEGRATION=1 OBS_SETUP_INTEGRATION=1 OBS_HOST=127.0.0.1 \
  flutter test test/obs_integration_test.dart

# clears the rig, builds every shot the picker offers, reads each one back
OBS_INTEGRATION=1 OBS_LAYOUT_INTEGRATION=1 OBS_HOST=127.0.0.1 \
  flutter test test/obs_integration_test.dart --plain-name "from-scratch rebuild"
```

The default suite covers cue parsing, the scroll trigger (fires on crossing,
re-fires after scrolling back, ignores unknown tags, never teleports on a
throttled frame), auto-scroll, scene creation, the setup request sequence and
framing, the reset (what it deletes, what it refuses to touch, stepping off the
live scene, waiting out a lagging scene list), the shot catalog and rig adoption,
the picker's limits, the cramped/short-window layouts, and pairing — every form
of the OBS line ([connection_target_test.dart](test/connection_target_test.dart)),
what the file store does with a missing or hand-edited file
([endpoint_store_test.dart](test/endpoint_store_test.dart)), what the pairing
screen says and does about each way a connection fails
([connect_screen_test.dart](test/connect_screen_test.dart)), and the phrasings a
refused port arrives in ([obs_client_test.dart](test/obs_client_test.dart)).

The opt-in tests drive the real client against a live OBS: auth, scene list,
real JPEG screenshot bytes, a cut, the pushed `CurrentProgramSceneChanged`
event, the scene-building setup, and the from-scratch rebuild of all five shots
— each asserted by reading its transform back out of OBS and comparing the box
it describes. Two more check the pairing screen's judgement without changing
anything in OBS: a deliberately wrong password has to come back as
*"wrong password"* rather than a dead host, and a port with nothing on it must
not be mistaken for one.

### Rendering, not just intent

A transform read back out of OBS describes *intent*. `tools/obs_frame_probe.mjs`
checks the pixels: it re-applies the app's own payloads to a bright source, one
temporary scene at a time, screenshots the result and measures where the lit area
lands. It needs no camera light, so it works on a machine whose webcam is asleep:

```bash
OBS_LAYOUT_DUMP=/tmp/rig_frames.json \
OBS_INTEGRATION=1 OBS_LAYOUT_INTEGRATION=1 OBS_HOST=127.0.0.1 \
  flutter test test/obs_integration_test.dart --plain-name "from-scratch rebuild"
OBS_HOST=127.0.0.1 OBS_PAYLOAD=/tmp/rig_frames.json node tools/obs_frame_probe.mjs
```

The transform test passes the *payload*; the probe passes the *picture*.

### Tools

| Command | Purpose |
| --- | --- |
| `node tools/obs_probe.mjs` | Connect, authenticate, dump scenes/version |
| `node tools/obs_inspect.mjs` | Dump scenes, items, inputs, video settings |
| `node tools/obs_set_scene.mjs "Zoom_Cam"` | Set the program scene (handy for resetting a demo) |
| `node tools/obs_scene_dump.mjs` | Every scene, its items, how each is framed, and where the picture lands |
| `OBS_PAYLOAD=… node tools/obs_frame_probe.mjs` | Render the app's shot payloads against a bright source and measure the result |
| `node tools/obs_watch.mjs 60` | Watch and print every scene change — how the hands-free cut was verified |
| `node tools/fake_obs.mjs` | Offline obs-websocket v5 stand-in. `SCENES="Scene"` simulates a fresh install |
| `node tools/verify_page_auth.mjs` | Check the SHA-256/auth code against `node:crypto` |

All take `OBS_HOST` / `OBS_PORT` / `OBS_PASSWORD` from the environment.

## Not done yet

* **No QR scanner.** OBS's Show Connect Info screen shows a QR code whose payload
  is the same `obsws://host:port/password` line the paste box already parses, so
  the format is not the work — reading a camera is. A browser only grants camera
  access on a secure context, which a phone opening the app over a LAN `http://`
  address is not.
* **One endpoint per machine.** Pairing replaces the endpoint rather than keeping
  a list, so a second OBS means re-pairing (the switcher's Connect button).
* **The setup only places the camera.** The `Side`, `Bottom` and `Top` shots are
  positioned for a screen share, but nothing adds the display or window capture
  to go with them (a `monitor_capture` / `window_capture` source is a small
  addition to the same plan in [lib/obs/auto_setup.dart](lib/obs/auto_setup.dart)).
* **A chosen rig lasts the session, then is read back from OBS.** The selection
  is not persisted anywhere: the switcher adopts whatever rig it finds in OBS on
  connect, which covers a restart, but two rigs in one OBS would need a rule.
* **Scripts are hard-coded** ([sample_script.dart](lib/teleprompter/sample_script.dart)).
  Loading a `.txt`/`.md` script and editing it in-app is the obvious next step.
* **Mirroring** (flipping the text for a beamsplitter rig) and a countdown lead-in
  are not implemented.
* [public/index.html](public/index.html) is the phase-1 browser probe that proved
  the protocol before any Flutter existed. Superseded by the app; kept as a
  minimal reference.
#   t h i r d - t r y - . -  
 