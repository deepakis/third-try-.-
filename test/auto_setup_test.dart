import 'dart:convert';
import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/app_config.dart';
import 'package:open_flutter/obs/auto_setup.dart';
import 'package:open_flutter/obs/layouts.dart';
import 'package:open_flutter/obs/obs_models.dart';

import 'fakes.dart';

void main() {
  // Camera A -> Full_Cam (full frame), Camera B -> Zoom_Cam (130% zoom).
  const slots = AppConfig.cameras;

  test('creates both scenes and reuses the camera OBS already has', () async {
    final obs = FakeObsConnection(
      scenes: [scene('Scene', 0)],
      inputs: const [
        ObsInput(name: 'Video Capture Device', kind: 'dshow_input'),
      ],
    );

    final report = await ObsAutoSetup(connection: obs, slots: slots).run();

    expect(report.ok, isTrue);
    expect(report.cameraSource, 'Video Capture Device');
    expect(obs.calls, [
      'createScene:Full_Cam',
      'createScene:Zoom_Cam',
      'createSceneItem:Full_Cam:Video Capture Device',
      'transform:Full_Cam:OBS_BOUNDS_SCALE_INNER',
      'createSceneItem:Zoom_Cam:Video Capture Device',
      'transform:Zoom_Cam:1.3',
    ]);
    // The whole point: one camera source, referenced twice.
    expect(obs.calls.where((call) => call.startsWith('createInput')), isEmpty);
  });

  test('full frame fits the canvas, zoom is a centred 130%', () async {
    final obs = FakeObsConnection(
      inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
    );

    await ObsAutoSetup(connection: obs, slots: slots).run();

    final full = obs.sceneItems['Full_Cam']!.single.transform!;
    expect(full['boundsType'], 'OBS_BOUNDS_SCALE_INNER');
    expect(full['boundsWidth'], 1366.0);
    expect(full['boundsHeight'], 768.0);
    expect(full['alignment'], kObsAlignCenter);

    final zoom = obs.sceneItems['Zoom_Cam']!.single.transform!;
    expect(zoom['scaleX'], 1.3);
    expect(zoom['scaleY'], 1.3);
    expect(zoom['boundsType'], 'OBS_BOUNDS_NONE');
    expect(zoom['alignment'], kObsAlignCenter);
    expect(zoom['positionX'], 683.0); // canvas centre, so it zooms inwards
    expect(zoom['positionY'], 384.0);
  });

  test('creates a camera source when OBS has none, using an offered kind',
      () async {
    final obs = FakeObsConnection(
      availableKinds: const ['av_capture_input', 'wasapi_output_capture'],
      propertyItems: {
        '$defaultCameraInputName/video_device_id': const [
          ObsPropertyItem(name: 'Default', value: 'default', enabled: true),
          ObsPropertyItem(
            name: 'FaceTime HD Camera',
            value: '{camera-guid}',
            enabled: true,
          ),
        ],
      },
    );

    final report = await ObsAutoSetup(connection: obs, slots: slots).run();

    expect(report.ok, isTrue);
    // macOS flavour, because that is what this OBS reports.
    expect(obs.calls, contains('createInput:$defaultCameraInputName:av_capture_input'));
    // A real device, not the "Default" placeholder.
    expect(obs.inputSettings[defaultCameraInputName]!['video_device_id'],
        '{camera-guid}');
  });

  test('re-running only re-applies the transforms', () async {
    final obs = FakeObsConnection(
      inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
    );
    await ObsAutoSetup(connection: obs, slots: slots).run();

    obs.calls.clear();
    final second = await ObsAutoSetup(connection: obs, slots: slots).run();

    expect(second.ok, isTrue);
    expect(obs.calls, [
      'transform:Full_Cam:OBS_BOUNDS_SCALE_INNER',
      'transform:Zoom_Cam:1.3',
    ]);
  });

  test('stops and reports when OBS refuses a step', () async {
    final obs = FakeObsConnection(createThrows: true);

    final report = await ObsAutoSetup(connection: obs, slots: slots).run();

    expect(report.ok, isFalse);
    expect(report.error, contains('nope'));
    expect(report.steps.last.message, contains('Stopped'));
  });

  test('streams every step as it lands', () async {
    final obs = FakeObsConnection(
      inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
    );
    final seen = <String>[];

    await ObsAutoSetup(
      connection: obs,
      slots: slots,
      onStep: (step) => seen.add(step.message),
    ).run();

    expect(seen, hasLength(greaterThan(4)));
    expect(seen.any((message) => message.contains('Full_Cam')), isTrue);
  });

  test('prefers the platform camera kind OBS actually offers', () {
    expect(preferredVideoKind(['av_capture_input']), 'av_capture_input');
    expect(preferredVideoKind(['v4l2_input', 'dshow_input']), 'dshow_input');
    expect(preferredVideoKind(const []), 'dshow_input');
  });

  test('the PiP layout parks the camera in the corner', () {
    const video = ObsVideoSettings(baseWidth: 1920, baseHeight: 1080);

    final transform = transformForLayout(CameraLayout.bottomPiP, video);

    expect(transform['alignment'], kObsAlignBottomRight);
    expect(transform['boundsWidth'], lessThan(1920));
    expect(transform['positionX'], greaterThan(960)); // right half
    expect(transform['positionY'], greaterThan(540)); // bottom half
  });

  group('every shot a user can pick', () {
    const video = ObsVideoSettings(baseWidth: 1920, baseHeight: 1080);

    test('is a different framing from the others', () {
      final seen = <String>{};
      for (final option in layoutOptions) {
        seen.add(jsonEncode(transformForLayout(option.layout, video)));
      }
      expect(seen, hasLength(layoutOptions.length));
    });

    test('anchors inside the canvas it was given', () {
      for (final option in layoutOptions) {
        final transform = transformForLayout(option.layout, video);
        final x = transform['positionX'] as double;
        final y = transform['positionY'] as double;
        expect(x, inInclusiveRange(0, 1920), reason: option.id);
        expect(y, inInclusiveRange(0, 1080), reason: option.id);
        // A box that claimed more room than the canvas has would be cropped.
        if (transform['boundsType'] != 'OBS_BOUNDS_NONE') {
          expect(
            transform['boundsWidth'] as double,
            lessThanOrEqualTo(1920),
            reason: option.id,
          );
          expect(
            transform['boundsHeight'] as double,
            lessThanOrEqualTo(1080),
            reason: option.id,
          );
        }
      }
    });

    test('is a complete snapshot, so nothing stale survives a re-framing', () {
      // OBS only changes the fields it is sent. Our own live probe caught a
      // scene that was zoomed once and then framed as a box keeping scale 1.3,
      // which quietly cropped the box. Every field has to be there.
      const wanted = [
        'positionX',
        'positionY',
        'alignment',
        'boundsType',
        'boundsAlignment',
        'boundsWidth',
        'boundsHeight',
        'scaleX',
        'scaleY',
        'cropLeft',
        'cropTop',
        'cropRight',
        'cropBottom',
        'rotation',
      ];
      for (final option in layoutOptions) {
        final transform = transformForLayout(option.layout, video);
        expect(
          transform.keys.toSet(),
          containsAll(wanted),
          reason: option.id,
        );
        // A box shot must not carry a leftover scale.
        if (transform['boundsType'] != 'OBS_BOUNDS_NONE') {
          expect(transform['scaleX'], 1.0, reason: option.id);
          expect(transform['scaleY'], 1.0, reason: option.id);
        }
      }
    });

    test('describes the box it occupies on the canvas', () {
      final full = framingForLayout(CameraLayout.fullBleed, video);
      expect(full.box, const Rect.fromLTWH(0, 0, 1920, 1080));

      // The zoom hangs off every edge: 130% of the canvas, still centred.
      final zoom = framingForLayout(CameraLayout.zoomedBleed, video);
      expect(zoom.box.width, closeTo(2496, 0.001));
      expect(zoom.box.center, const Offset(960, 540));
      // The canvas sits inside the zoom: the edges are cropped, not letterboxed.
      expect(zoom.box.contains(const Offset(1, 1)), isTrue);
      expect(zoom.box.contains(const Offset(1919, 1079)), isTrue);

      final side = framingForLayout(CameraLayout.sideBleed, video);
      expect(side.box.right, closeTo(1920 - 1920 * 0.02, 0.001));
      expect(side.box.left, greaterThan(1000)); // right-hand strip
      expect(side.box.top, greaterThan(0));
      expect(side.box.bottom, lessThan(1080));

      final bottom = framingForLayout(CameraLayout.bottomPiP, video);
      expect(bottom.box.right, closeTo(1920 - 1920 * 0.02, 0.001));
      expect(bottom.box.bottom, closeTo(1080 - 1920 * 0.02, 0.001));
      expect(bottom.box.width, closeTo(1920 * 0.28, 0.001));

      final top = framingForLayout(CameraLayout.topPiP, video);
      expect(top.box.right, closeTo(1920 - 1920 * 0.02, 0.001));
      expect(top.box.top, closeTo(1920 * 0.02, 0.001));
      expect(top.box.bottom, lessThan(540));
    });

    test('sits where its name says it does', () {
      final side = transformForLayout(CameraLayout.sideBleed, video);
      expect(side['alignment'], kObsAlignRight);
      expect(side['positionX'] as double, greaterThan(960));

      final top = transformForLayout(CameraLayout.topPiP, video);
      expect(top['alignment'], kObsAlignTopRight);
      expect(top['positionY'] as double, lessThan(540));

      final bottom = transformForLayout(CameraLayout.bottomPiP, video);
      expect(bottom['alignment'], kObsAlignBottomRight);
      expect(bottom['positionY'] as double, greaterThan(540));
    });
  });

  group('ObsRigReset', () {
    test('removes the rig scenes and the camera source it created', () async {
      final obs = FakeObsConnection(
        scenes: [
          scene('Full_Cam', 0),
          scene('Zoom_Cam', 1),
          scene('Camera A', 2),
        ],
        inputs: const [
          ObsInput(name: 'Video Capture Device', kind: 'dshow_input'),
          ObsInput(name: defaultCameraInputName, kind: 'dshow_input'),
        ],
      );

      final report = await ObsRigReset(connection: obs).run();

      expect(report.ok, isTrue, reason: report.error);
      expect(report.messages, contains('Removed scene "Full_Cam"'));
      expect(obs.calls, [
        'removeScene:Full_Cam',
        'removeScene:Zoom_Cam',
        'removeInput:$defaultCameraInputName',
      ]);
      // The user's own scene and camera source survive.
      expect(obs.scenes.map((s) => s.name), ['Camera A']);
      expect(obs.inputList.map((i) => i.name), ['Video Capture Device']);
    });

    test('steps off the program scene before deleting it', () async {
      final obs = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Scene', 1)],
        programScene: 'Full_Cam',
      );

      await ObsRigReset(connection: obs).run();

      // Order matters: OBS refuses to delete the scene going out live.
      expect(obs.calls, ['set:Scene', 'removeScene:Full_Cam']);
    });

    test('leaves a stock OBS completely alone', () async {
      final obs = FakeObsConnection(
        scenes: [scene('Scene', 0)],
        inputs: const [
          ObsInput(name: 'Video Capture Device', kind: 'dshow_input'),
        ],
      );

      final report = await ObsRigReset(connection: obs).run();

      expect(report.ok, isTrue);
      expect(obs.calls, isEmpty);
      expect(report.steps.first.message, contains('No rig scenes'));
      expect(
        report.messages.join(' '),
        contains('your own camera sources are untouched'),
      );
    });

    test('waits out a scene list that still lists what it just removed', () async {
      // Observed on a live OBS: the rebuild after a reset was told a scene
      // still existed, skipped creating it, then failed to find it.
      final obs = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        listLagReads: 2,
      );

      final report = await ObsRigReset(connection: obs).run();

      expect(report.ok, isTrue, reason: report.error);
      expect(obs.scenes, isEmpty);
      // It did not take the first answer for it.
      expect(obs.listReads, greaterThan(1));
      expect(report.messages, contains('OBS caught up with the removal'));
    });

    test('only clears what it was told to', () async {
      final obs = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Side_Cam', 1)],
      );

      await ObsRigReset(
        connection: obs,
        sceneNames: const {'Side_Cam'},
        removeCreatedCamera: false,
      ).run();

      expect(obs.calls, ['removeScene:Side_Cam']);
      expect(obs.scenes.map((s) => s.name), ['Full_Cam']);
    });
  });
}
