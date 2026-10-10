import 'dart:typed_data';

/// How a camera scene is composed on screen. Drives the little layout diagram
/// shown when a scene has no sources yet, and documents intent for the operator.
enum CameraLayout {
  /// Talking head, full frame.
  fullBleed,

  /// The same camera, zoomed in (a digital crop) so the shot is tighter.
  zoomedBleed,

  /// Camera down one side, full height — room for content beside it.
  sideBleed,

  /// Small camera box in the bottom corner, over whatever else the scene shows.
  bottomPiP,

  /// Same box, top corner.
  topPiP,
}

/// One of the big buttons on the switcher screen: a camera the operator can cut to.
class CameraSlot {
  const CameraSlot({
    required this.id,
    required this.label,
    required this.sceneName,
    required this.description,
    required this.layout,
  });

  /// Stable id used for keyboard shortcuts and per-tile UI state ('A', 'B', ...).
  final String id;

  /// Big label on the tile, e.g. "Camera A".
  final String label;

  /// Preferred OBS scene name for this camera.
  final String sceneName;

  /// One-line explanation of what this shot is, e.g. "Full screen · talking head".
  final String description;

  final CameraLayout layout;
}

/// A scene as reported by OBS (`GetSceneList`).
class ObsScene {
  const ObsScene({required this.index, required this.name, required this.uuid});

  final int index;
  final String name;
  final String uuid;

  @override
  String toString() => 'ObsScene($index, $name)';
}

/// The slice of OBS state the switcher cares about.
class SceneSnapshot {
  const SceneSnapshot({required this.scenes, required this.programScene});

  final List<ObsScene> scenes;

  /// Name of the scene currently going out (the "live" one), if any.
  final String? programScene;
}

enum ObsConnectionState { connecting, identified, disconnected }

/// Why a connection attempt did not get to "identified".
///
/// OBS names exactly one of these itself: obs-websocket closes the socket with
/// **4009** when the password is wrong. The rest are inferred from how the
/// socket failed, which is why they are coarse — a browser will not tell a
/// script whether the host did not answer or refused the port. Each one has a
/// different fix, so the pairing screen shows different advice for each.
enum ObsFailure {
  /// Nothing went wrong (or nothing to report yet).
  none,

  /// It is OBS, and it rejected the password. Fix the password, not the address.
  wrongPassword,

  /// The host answered but nothing is listening on that port: OBS is closed, or
  /// its WebSocket server is switched off.
  refused,

  /// We never got that far — wrong address, a different network, a VPN, or a
  /// firewall in the way.
  unreachable,

  /// A page served over `https://` cannot open a `ws://` socket; the browser
  /// blocks it before the request leaves.
  mixedContent,

  /// We were connected and the socket closed for some other reason.
  closed,
}

class ObsStatus {
  const ObsStatus(this.state, {this.detail = '', this.failure = ObsFailure.none});

  final ObsConnectionState state;

  /// Human-readable detail, e.g. "OBS 32.2.2" or an error summary.
  final String detail;

  /// Set when the last attempt failed. [ObsFailure.none] otherwise.
  final ObsFailure failure;

  bool get isConnected => state == ObsConnectionState.identified;

  /// True once an attempt has settled badly, so a screen can stop waiting.
  bool get failed => failure != ObsFailure.none;

  String get label => switch (state) {
    ObsConnectionState.connecting => 'connecting…',
    ObsConnectionState.identified => detail.isEmpty ? 'connected' : detail,
    ObsConnectionState.disconnected => detail.isEmpty ? 'disconnected' : detail,
  };
}

ObsScene? firstWhereOrNull(List<ObsScene> scenes, bool Function(ObsScene) test) {
  for (final scene in scenes) {
    if (test(scene)) return scene;
  }
  return null;
}

/// Binds each tile to the OBS scene that carries its name (`Camera A` → the
/// scene named "Camera A").
///
/// A slot whose scene is missing resolves to null: the UI says so and offers to
/// create it. Deliberately *no* positional fallback — pressing "Camera A" and
/// landing on an unrelated scene would be worse than an honest empty state.
Map<String, ObsScene?> resolveTargets(
  List<CameraSlot> slots,
  List<ObsScene> scenes,
) {
  return {
    for (final slot in slots)
      slot.id: firstWhereOrNull(
        scenes,
        (scene) => scene.name.toLowerCase() == slot.sceneName.toLowerCase(),
      ),
  };
}

/// `OBS_ALIGN_*` are bit flags, and `alignment: 0` is the centre anchor — not
/// 5. Getting this wrong shifts the item by half the canvas, so the constants
/// live here next to the model and are read back from OBS in the tests.
///
/// OBS's canvas size, used to centre and size scene items.
class ObsVideoSettings {
  const ObsVideoSettings({required this.baseWidth, required this.baseHeight});

  final int baseWidth;
  final int baseHeight;

  double get centreX => baseWidth / 2;
  double get centreY => baseHeight / 2;
}

/// A source that exists in OBS.
class ObsInput {
  const ObsInput({required this.name, required this.kind});

  final String name;

  /// e.g. `dshow_input`, `av_capture_input`, `wasapi_input_capture`.
  final String kind;

  bool get isVideoCapture =>
      const {
        'dshow_input',
        'av_capture_input',
        'v4l2_input',
        'pipewire-camera-source',
      }.contains(kind);
}

/// One choice in an OBS source property dropdown (e.g. a camera device).
class ObsPropertyItem {
  const ObsPropertyItem({
    required this.name,
    required this.value,
    required this.enabled,
  });

  final String name;
  final String value;
  final bool enabled;
}

/// Preview frame for a tile, kept together with the scene it came from so a
/// stale image is never shown for a newly created scene.
class ScenePreview {
  const ScenePreview({required this.sceneName, required this.bytes});

  final String sceneName;
  final Uint8List bytes;
}
