import 'dart:ui';

import 'layouts.dart';
import 'obs_client.dart';
import 'obs_models.dart';

// OBS alignment is a bit flag set: CENTER 0 · LEFT 1 · RIGHT 2 · TOP 4 ·
// BOTTOM 8. So the anchor for "centred" is 0, and a corner is a combination.
//
// This matters more than it looks: with `alignment: 5` (LEFT|TOP, i.e. top-left)
// and a position at the canvas centre, the item hangs off the bottom-right of the
// frame — which is exactly the bug an earlier version of this file shipped.

/// `OBS_ALIGN_CENTER` — anchor the item on its own centre.
const int kObsAlignCenter = 0;

/// `OBS_ALIGN_RIGHT` — right edge, vertically centred (a side strip).
const int kObsAlignRight = 2;

/// `OBS_ALIGN_RIGHT | OBS_ALIGN_TOP`.
const int kObsAlignTopRight = 6;

/// `OBS_ALIGN_RIGHT | OBS_ALIGN_BOTTOM`.
const int kObsAlignBottomRight = 10;

/// One line of the setup report, shown in the UI as it happens.
class SetupStep {
  const SetupStep(this.message, {this.changed = true});

  final String message;

  /// False for "already like this" notes, so the UI can dim them.
  final bool changed;
}

class SetupReport {
  const SetupReport({
    required this.steps,
    required this.ok,
    this.cameraSource,
    this.error,
  });

  final List<SetupStep> steps;
  final bool ok;

  /// The video capture source both scenes were pointed at.
  final String? cameraSource;
  final String? error;

  List<String> get messages => [for (final step in steps) step.message];
}

/// Preferred input kinds for a webcam, in order. OBS only offers the ones that
/// match the host OS, so we ask which exist rather than guessing.
const List<String> videoCaptureKinds = [
  'dshow_input', // Windows
  'av_capture_input', // macOS
  'v4l2_input', // Linux
  'pipewire-camera-source', // Linux (PipeWire)
];

/// Name used when OBS has no camera source to reuse.
const String defaultCameraInputName = 'Auto_Webcam';

String preferredVideoKind(List<String> available) {
  for (final kind in videoCaptureKinds) {
    if (available.contains(kind)) return kind;
  }
  return videoCaptureKinds.first;
}

/// How one shot is placed: the anchor OBS positions the item by, and the box the
/// camera is fitted into.
///
/// Kept as data (rather than a payload map) so the geometry can be asserted in
/// tests, and read back out of OBS, without re-deriving it.
class ShotFraming {
  const ShotFraming({
    required this.positionX,
    required this.positionY,
    required this.alignment,
    required this.boundsType,
    required this.boundsWidth,
    required this.boundsHeight,
    this.scale = 1.0,
  });

  /// The anchor point, interpreted through [alignment].
  final double positionX;
  final double positionY;

  /// `OBS_ALIGN_*` for the anchor: centre, or a corner.
  final int alignment;

  /// `OBS_BOUNDS_NONE` (scale only) or `OBS_BOUNDS_SCALE_INNER` (fit the box).
  final String boundsType;
  final double boundsWidth;
  final double boundsHeight;

  /// Only meaningful with `OBS_BOUNDS_NONE`; box shots are fitted, not scaled.
  final double scale;

  /// The box the shot occupies on the canvas, in canvas pixels.
  Rect get box => switch (alignment) {
    kObsAlignRight => Rect.fromLTWH(
      positionX - boundsWidth,
      positionY - boundsHeight / 2,
      boundsWidth,
      boundsHeight,
    ),
    kObsAlignTopRight => Rect.fromLTWH(
      positionX - boundsWidth,
      positionY,
      boundsWidth,
      boundsHeight,
    ),
    kObsAlignBottomRight => Rect.fromLTWH(
      positionX - boundsWidth,
      positionY - boundsHeight,
      boundsWidth,
      boundsHeight,
    ),
    _ => Rect.fromCenter(
      center: Offset(positionX, positionY),
      width: boundsWidth,
      height: boundsHeight,
    ),
  };

  Map<String, dynamic> toTransform() => {
    'positionX': positionX,
    'positionY': positionY,
    'alignment': alignment,
    'boundsType': boundsType,
    'boundsAlignment': kObsAlignCenter,
    'boundsWidth': boundsWidth,
    'boundsHeight': boundsHeight,
    // Set explicitly, even for box shots: leaving scale out of the payload
    // leaves the *previous* scale on the item, so a re-framing of a scene that
    // was once zoomed would silently crop.
    'scaleX': boundsType == 'OBS_BOUNDS_NONE' ? scale : 1.0,
    'scaleY': boundsType == 'OBS_BOUNDS_NONE' ? scale : 1.0,
    'cropLeft': 0.0,
    'cropTop': 0.0,
    'cropRight': 0.0,
    'cropBottom': 0.0,
    'rotation': 0.0,
  };
}

/// Where a shot's camera sits on the canvas.
///
/// Two families, deliberately:
///
/// * a **bleed** fills the canvas. The whole frame is fitted to the canvas
///   (`SCALE_INNER`), so any camera resolution looks right; the zoom variant is
///   the same camera at 130% about the centre, which crops the edges.
/// * a **box** takes a share of the canvas — a strip down one side, or a corner
///   box to put over a screen share. The box is anchored to a canvas corner and
///   the camera is fitted inside it, so the shot lands in that corner whatever
///   the camera's aspect ratio.
ShotFraming framingForLayout(
  CameraLayout layout,
  ObsVideoSettings video, {
  double zoom = 1.3,
}) {
  final margin = video.baseWidth * 0.02;
  return switch (layout) {
    CameraLayout.fullBleed => ShotFraming(
      positionX: video.centreX,
      positionY: video.centreY,
      alignment: kObsAlignCenter,
      boundsType: 'OBS_BOUNDS_SCALE_INNER',
      boundsWidth: video.baseWidth.toDouble(),
      boundsHeight: video.baseHeight.toDouble(),
    ),
    CameraLayout.zoomedBleed => ShotFraming(
      positionX: video.centreX,
      positionY: video.centreY,
      alignment: kObsAlignCenter,
      boundsType: 'OBS_BOUNDS_NONE',
      boundsWidth: video.baseWidth * zoom,
      boundsHeight: video.baseHeight * zoom,
      scale: zoom,
    ),
    CameraLayout.sideBleed => ShotFraming(
      positionX: video.baseWidth - margin,
      positionY: video.centreY,
      alignment: kObsAlignRight,
      boundsType: 'OBS_BOUNDS_SCALE_INNER',
      boundsWidth: video.baseWidth * 0.34,
      boundsHeight: video.baseHeight - margin * 2,
    ),
    CameraLayout.bottomPiP => ShotFraming(
      positionX: video.baseWidth - margin,
      positionY: video.baseHeight - margin,
      alignment: kObsAlignBottomRight,
      boundsType: 'OBS_BOUNDS_SCALE_INNER',
      boundsWidth: video.baseWidth * 0.28,
      boundsHeight: video.baseHeight * 0.32,
    ),
    CameraLayout.topPiP => ShotFraming(
      positionX: video.baseWidth - margin,
      positionY: margin,
      alignment: kObsAlignTopRight,
      boundsType: 'OBS_BOUNDS_SCALE_INNER',
      boundsWidth: video.baseWidth * 0.28,
      boundsHeight: video.baseHeight * 0.32,
    ),
  };
}

/// The payload OBS wants for a shot.
Map<String, dynamic> transformForLayout(
  CameraLayout layout,
  ObsVideoSettings video, {
  double zoom = 1.3,
}) => framingForLayout(layout, video, zoom: zoom).toTransform();

/// Builds a rig inside a stock OBS install.
///
/// Runs at most four kinds of change, in this order, and is safe to re-run:
///   1. create the scenes that don't exist yet
///   2. find the webcam source OBS already has, or create one
///   3. make sure that source is a scene item in each scene
///   4. set each scene item's transform (full frame / corner PiP / 130% zoom)
///
/// Every scene references the *same* source on purpose: on Windows a camera
/// device is locked by its first capture source, so a second `dshow_input`
/// pointed at the same webcam usually fails to start.
///
/// A scene that already exists is left alone — run [ObsRigReset] first when the
/// shot should be rebuilt from nothing (which is what the UI does).
class ObsAutoSetup {
  ObsAutoSetup({
    required this.connection,
    required this.slots,
    this.zoom = 1.3,
    this.onStep,
  });

  final ObsConnection connection;
  final List<CameraSlot> slots;
  final double zoom;

  /// Called as each step lands, so a UI can stream the report.
  final void Function(SetupStep step)? onStep;

  final List<SetupStep> _steps = [];

  void _add(String message, {bool changed = true}) {
    final step = SetupStep(message, changed: changed);
    _steps.add(step);
    onStep?.call(step);
  }

  Future<SetupReport> run() async {
    String? cameraSource;
    try {
      // 1. scenes
      final before = await connection.fetchScenes();
      final existingScenes = before.scenes.map((scene) => scene.name).toSet();
      for (final slot in slots) {
        if (existingScenes.contains(slot.sceneName)) {
          _add('Scene "${slot.sceneName}" already exists', changed: false);
          continue;
        }
        await connection.createScene(slot.sceneName);
        _add('Created scene "${slot.sceneName}"');
      }

      // 2. the camera source — reuse before creating
      final videoInputs = (await connection.inputs())
          .where((input) => input.isVideoCapture)
          .toList();
      if (videoInputs.isNotEmpty) {
        cameraSource = videoInputs.first.name;
        _add(
          'Using the camera OBS already has: "$cameraSource"',
          changed: false,
        );
      } else {
        final kind = preferredVideoKind(await connection.inputKinds());
        await connection.createInput(
          inputName: defaultCameraInputName,
          inputKind: kind,
          sceneName: slots.isEmpty ? null : slots.first.sceneName,
        );
        cameraSource = defaultCameraInputName;
        _add('Created camera source "$defaultCameraInputName" ($kind)');
        await _pickCameraDevice(cameraSource);
      }

      // 3 + 4. link it into each scene and place it
      final video = await connection.videoSettings();
      for (final slot in slots) {
        final sceneName = slot.sceneName;
        var itemId = await connection.sceneItemId(
          sceneName: sceneName,
          sourceName: cameraSource,
        );
        if (itemId == null) {
          itemId = await connection.createSceneItem(
            sceneName: sceneName,
            sourceName: cameraSource,
          );
          _add('Added "$cameraSource" to "$sceneName"');
        } else {
          _add('"$cameraSource" is already in "$sceneName"', changed: false);
        }

        await connection.setSceneItemTransform(
          sceneName: sceneName,
          sceneItemId: itemId,
          transform: transformForLayout(slot.layout, video, zoom: zoom),
        );
        _add('Positioned it as ${_layoutLabel(slot.layout)}');
      }

      return SetupReport(steps: _steps, ok: true, cameraSource: cameraSource);
    } catch (error) {
      _add('Stopped: $error', changed: false);
      return SetupReport(
        steps: _steps,
        ok: false,
        cameraSource: cameraSource,
        error: '$error',
      );
    }
  }

  /// Picks a real device for a freshly created camera source, so the user
  /// doesn't have to. Windows calls the property `video_device_id`; macOS and
  /// Linux use `device`.
  Future<void> _pickCameraDevice(String inputName) async {
    for (final property in const ['video_device_id', 'device']) {
      final candidates = (await connection.inputPropertyItems(
        inputName,
        property,
      )).where((item) => item.enabled && item.value.isNotEmpty).toList();
      if (candidates.isEmpty) continue;
      final chosen = candidates.firstWhere(
        (item) => item.name.toLowerCase() != 'default',
        orElse: () => candidates.first,
      );
      await connection.setInputSettings(inputName, {property: chosen.value});
      _add('Selected camera device "${chosen.name}"');
      return;
    }
    _add('No camera device listed — pick one in OBS if the preview is black');
  }

  static String _layoutLabel(CameraLayout layout) => switch (layout) {
    CameraLayout.fullBleed => 'a full-frame shot',
    CameraLayout.zoomedBleed => 'a centred 130% zoom',
    CameraLayout.sideBleed => 'a side strip',
    CameraLayout.bottomPiP => 'a bottom-corner box',
    CameraLayout.topPiP => 'a top-corner box',
  };
}

/// Clears the rig this app built, so a fresh one can replace it.
///
/// Deletes the app's own scenes — the [rigSceneNames] catalog names — and, when
/// asked, the camera source the setup created itself (`Auto_Webcam`).
///
/// It never deletes a camera source OBS already had. On a stock install the
/// user's own scenes reference that source, and removing it would empty them;
/// that is why the reset is scoped by name rather than "any video input".
class ObsRigReset {
  ObsRigReset({
    required this.connection,
    Set<String>? sceneNames,
    this.removeCreatedCamera = true,
    this.onStep,
  }) : sceneNames = sceneNames ?? rigSceneNames;

  final ObsConnection connection;

  /// Scene names to remove. Defaults to every scene this app can create.
  final Set<String> sceneNames;

  /// Also remove the camera source the setup created, if it is there.
  final bool removeCreatedCamera;
  final void Function(SetupStep step)? onStep;

  final List<SetupStep> _steps = [];

  void _add(String message, {bool changed = true}) {
    final step = SetupStep(message, changed: changed);
    _steps.add(step);
    onStep?.call(step);
  }

  Future<SetupReport> run() async {
    try {
      final snapshot = await connection.fetchScenes();
      final existing = {for (final scene in snapshot.scenes) scene.name};
      final found = [
        for (final name in sceneNames)
          if (existing.contains(name)) name,
      ];

      if (found.isEmpty) {
        _add('No rig scenes in OBS to remove', changed: false);
      } else {
        await _cutAwayFirst(found, snapshot);
        for (final name in found) {
          await connection.removeScene(name);
          _add('Removed scene "$name"');
        }
        await _settle('scene', found, () async {
          final now = await connection.fetchScenes();
          return {for (final scene in now.scenes) scene.name};
        });
      }

      if (!removeCreatedCamera) {
        return SetupReport(steps: _steps, ok: true);
      }

      final ours = (await connection.inputs())
          .where((input) => input.name == defaultCameraInputName)
          .toList();
      if (ours.isEmpty) {
        _add(
          'No "$defaultCameraInputName" source to remove — your own camera '
          'sources are untouched',
          changed: false,
        );
      } else {
        await connection.removeInput(defaultCameraInputName);
        _add('Removed camera source "$defaultCameraInputName"');
        await _settle('source', const [defaultCameraInputName], () async {
          final now = await connection.inputs();
          return {for (final input in now) input.name};
        });
      }

      return SetupReport(steps: _steps, ok: true);
    } catch (error) {
      _add('Stopped: $error', changed: false);
      return SetupReport(steps: _steps, ok: false, error: '$error');
    }
  }

  /// Waits until OBS stops listing what we just deleted.
  ///
  /// OBS's scene list lags a removal by a moment, which a from-scratch run walks
  /// straight into: the rebuild is told the old scene still exists (so it skips
  /// creating it) and then a request later fails because it doesn't. Caught
  /// against a live OBS, hence the wait — and a caller can now trust that the
  /// names this reported as removed are actually gone when it returns.
  Future<void> _settle(
    String what,
    List<String> names,
    Future<Set<String>> Function() current,
  ) async {
    final wanted = {for (final name in names) name.toLowerCase()};
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var waited = false;
    while (DateTime.now().isBefore(deadline)) {
      final present = {
        for (final name in await current()) name.toLowerCase(),
      };
      if (!present.any(wanted.contains)) {
        if (waited) _add('OBS caught up with the removal', changed: false);
        return;
      }
      waited = true;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    _add('OBS is still listing a removed $what — it may catch up on its own');
  }

  /// OBS refuses to delete the scene going out live, so step off it first.
  Future<void> _cutAwayFirst(
    List<String> removing,
    SceneSnapshot snapshot,
  ) async {
    final program = snapshot.programScene;
    if (program == null || !removing.contains(program)) return;
    for (final scene in snapshot.scenes) {
      if (removing.contains(scene.name)) continue;
      await connection.setProgramScene(scene.name);
      _add('Cut to "${scene.name}" first, so OBS is never on a scene being removed');
      return;
    }
  }
}
