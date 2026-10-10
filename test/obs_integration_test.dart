// Opt-in integration test: exercises the real [ObsClient] against a live OBS.
//
//   OBS_INTEGRATION=1 flutter test test/obs_integration_test.dart
//   OBS_INTEGRATION=1 OBS_HOST=10.82.181.253 flutter test test/obs_integration_test.dart
//
// Skipped unless OBS_INTEGRATION=1, so the normal suite never needs OBS.
// It switches the program scene and puts it back afterwards.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/app_config.dart';
import 'package:open_flutter/obs/auto_setup.dart';
import 'package:open_flutter/obs/layouts.dart';
import 'package:open_flutter/obs/obs_client.dart';
import 'package:open_flutter/obs/obs_models.dart';

void main() {
  final enabled = Platform.environment['OBS_INTEGRATION'] == '1';
  final host = Platform.environment['OBS_HOST'] ?? '127.0.0.1';
  final port = int.parse(Platform.environment['OBS_PORT'] ?? '4455');
  final password = Platform.environment['OBS_PASSWORD'] ?? 'C8RsC84pViTVESA5';

  test(
    'authenticates, reads scenes, takes a scene screenshot, and cuts',
    () async {
      if (!enabled) {
        markTestSkipped('set OBS_INTEGRATION=1 to run against a live OBS');
        return;
      }

      final client = ObsClient(
        uri: Uri.parse('ws://$host:$port/'),
        password: password,
      );
      addTearDown(client.dispose);
      await client.connect();
      await client.statusStream
          .firstWhere((status) => status.isConnected)
          .timeout(const Duration(seconds: 10));

      // A wrong password must not be mistaken for a connection.
      expect(client.status.isConnected, isTrue);
      expect(client.status.detail, contains('OBS'));

      final before = await client.fetchScenes();
      expect(before.scenes, isNotEmpty, reason: 'OBS reported no scenes');
      final names = before.scenes.map((scene) => scene.name).toList();
      expect(names, contains('Camera A'));
      expect(names, contains('Camera B'));

      final original = before.programScene;

      // Scene item listing works for a real scene.
      expect(await client.sceneItemCount('Camera A'), greaterThanOrEqualTo(0));

      // Real screenshot bytes from OBS (JPEG).
      final preview = await client.scenePreview('Camera A');
      expect(preview, isNotNull);
      expect(preview!.length, greaterThan(100));
      expect(preview[0], 0xFF, reason: 'JPEG magic byte');
      expect(preview[1], 0xD8, reason: 'JPEG magic byte');

      // Cut to whichever scene isn't live, so the change is real.
      final target = names.firstWhere((name) => name != original);
      // Subscribe before cutting: events are pushed, not buffered.
      final pushed = client.eventStream
          .firstWhere(
            (event) =>
                event['eventType'] == 'CurrentProgramSceneChanged' &&
                (event['eventData'] as Map?)?['sceneName'] == target,
          )
          .timeout(const Duration(seconds: 10));

      await client.setProgramScene(target);
      final afterCut = await client.fetchScenes();
      expect(afterCut.programScene, target);
      expect((await pushed)['eventData'], isA<Map<String, dynamic>>());

      // Put the operator's setup back the way we found it.
      if (original != null) await client.setProgramScene(original);
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  // Mutates the OBS install (creates the two scenes and places the camera), so
  // it needs its own opt-in flag on top of OBS_INTEGRATION.
  //
  //   OBS_INTEGRATION=1 OBS_SETUP_INTEGRATION=1 OBS_HOST=127.0.0.1 \
  //     flutter test test/obs_integration_test.dart
  test(
    'auto-configure builds both scenes in a real OBS',
    () async {
      if (!enabled || Platform.environment['OBS_SETUP_INTEGRATION'] != '1') {
        markTestSkipped(
          'set OBS_SETUP_INTEGRATION=1 to run the scene-building setup',
        );
        return;
      }

      final client = ObsClient(
        uri: Uri.parse('ws://$host:$port/'),
        password: password,
      );
      addTearDown(client.dispose);
      await client.connect();
      await client.statusStream
          .firstWhere((status) => status.isConnected)
          .timeout(const Duration(seconds: 10));

      final report = await ObsAutoSetup(
        connection: client,
        slots: AppConfig.cameras,
      ).run();

      expect(report.ok, isTrue, reason: report.messages.join(' | '));
      expect(report.cameraSource, isNotNull);

      // The scenes exist…
      final snapshot = await client.fetchScenes();
      final names = snapshot.scenes.map((scene) => scene.name).toList();
      expect(names, containsAll(['Full_Cam', 'Zoom_Cam']));

      // …and OBS reports the framing we asked for.
      final video = await client.videoSettings();
      for (final slot in AppConfig.cameras) {
        final itemId = await client.sceneItemId(
          sceneName: slot.sceneName,
          sourceName: report.cameraSource!,
        );
        expect(itemId, isNotNull);
        final transform = await client.sceneItemTransform(
          sceneName: slot.sceneName,
          sceneItemId: itemId!,
        );
        final expected = transformForLayout(slot.layout, video);
        if (slot.layout == CameraLayout.zoomedBleed) {
          // OBS stores transforms as float32, so 1.3 comes back as 1.29999995…
          expect(transform['scaleX'], closeTo(1.3, 0.001));
          expect(transform['scaleY'], closeTo(1.3, 0.001));
          expect(transform['alignment'], expected['alignment']);
        } else {
          expect(transform['boundsType'], expected['boundsType']);
          expect(transform['boundsWidth'], expected['boundsWidth']);
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // The from-scratch path the UI now offers: clear the rig, then build every shot
  // the picker can offer and read each one back out of OBS. Opt in separately
  // again, because it deletes scenes.
  //
  //   OBS_INTEGRATION=1 OBS_LAYOUT_INTEGRATION=1 OBS_HOST=127.0.0.1 \
  //     flutter test test/obs_integration_test.dart
  test(
    'a from-scratch rebuild frames every shot the way its name says',
    () async {
      if (!enabled || Platform.environment['OBS_LAYOUT_INTEGRATION'] != '1') {
        markTestSkipped(
          'set OBS_LAYOUT_INTEGRATION=1 to rebuild every shot in a real OBS',
        );
        return;
      }

      final client = ObsClient(
        uri: Uri.parse('ws://$host:$port/'),
        password: password,
      );
      addTearDown(client.dispose);
      await client.connect();
      await client.statusStream
          .firstWhere((status) => status.isConnected)
          .timeout(const Duration(seconds: 10));

      final before = await client.fetchScenes();
      final theirScenes = [
        for (final scene in before.scenes)
          if (!rigSceneNames.contains(scene.name)) scene.name,
      ];
      final theirInputs = (await client.inputs()).map((i) => i.name).toList();

      // Rebuild from scratch even when a rig scene is the one going out: OBS
      // refuses to delete the live scene, so the reset has to step off it first.
      final rigScenes = [
        for (final name in rigSceneNames)
          if (before.scenes.any((scene) => scene.name == name)) name,
      ];
      if (rigScenes.isNotEmpty) await client.setProgramScene(rigScenes.first);

      final reset = await ObsRigReset(connection: client).run();
      expect(reset.ok, isTrue, reason: reset.messages.join(' | '));
      for (final name in rigScenes) {
        expect(reset.messages, contains('Removed scene "$name"'));
      }

      final cleared = await client.fetchScenes();
      expect(
        cleared.scenes.map((scene) => scene.name),
        isNot(contains(anyOf(rigScenes))),
        reason: 'the reset left a rig scene behind',
      );
      // The operator's own scenes and camera sources are not ours to delete.
      expect(
        cleared.scenes.map((scene) => scene.name),
        containsAll(theirScenes),
        reason: 'the reset touched a scene that was not ours',
      );
      expect(
        (await client.inputs()).map((input) => input.name),
        containsAll(theirInputs),
      );

      // Every shot, built the way the app builds them.
      final slots = [
        for (var i = 0; i < layoutOptions.length; i++) layoutOptions[i].toSlot(i),
      ];
      final setup = await ObsAutoSetup(connection: client, slots: slots).run();
      expect(setup.ok, isTrue, reason: setup.messages.join(' | '));

      final video = await client.videoSettings();
      for (final slot in slots) {
        final itemId = await client.sceneItemId(
          sceneName: slot.sceneName,
          sourceName: setup.cameraSource!,
        );
        expect(itemId, isNotNull, reason: slot.sceneName);

        final stored = await client.sceneItemTransform(
          sceneName: slot.sceneName,
          sceneItemId: itemId!,
        );
        final wanted = framingForLayout(slot.layout, video);

        // What OBS kept, turned back into a box on the canvas.
        final actual = ShotFraming(
          positionX: (stored['positionX'] as num).toDouble(),
          positionY: (stored['positionY'] as num).toDouble(),
          alignment: (stored['alignment'] as num).toInt(),
          boundsType: stored['boundsType'] as String,
          boundsWidth: (stored['boundsWidth'] as num).toDouble(),
          boundsHeight: (stored['boundsHeight'] as num).toDouble(),
          scale: (stored['scaleX'] as num).toDouble(),
        );

        expect(actual.alignment, wanted.alignment, reason: slot.sceneName);
        expect(actual.boundsType, wanted.boundsType, reason: slot.sceneName);
        expect(
          actual.box.left,
          closeTo(wanted.box.left, 1),
          reason: '${slot.sceneName} left edge',
        );
        expect(
          actual.box.top,
          closeTo(wanted.box.top, 1),
          reason: '${slot.sceneName} top edge',
        );
        expect(
          actual.box.right,
          closeTo(wanted.box.right, 1),
          reason: '${slot.sceneName} right edge',
        );
        expect(
          actual.box.bottom,
          closeTo(wanted.box.bottom, 1),
          reason: '${slot.sceneName} bottom edge',
        );
        // A stale scale on a box shot would crop it in OBS.
        if (wanted.boundsType != 'OBS_BOUNDS_NONE') {
          expect(actual.scale, 1.0, reason: '${slot.sceneName} scale');
        }
        // Shot spots: a box sits inside the canvas, a bleed covers it.
        if (slot.layout == CameraLayout.fullBleed ||
            slot.layout == CameraLayout.zoomedBleed) {
          expect(actual.box.contains(const Offset(1, 1)), isTrue);
          expect(
            actual.box.contains(
              Offset(video.baseWidth - 1, video.baseHeight - 1),
            ),
            isTrue,
          );
        } else {
          expect(actual.box.left, greaterThan(0), reason: slot.sceneName);
          expect(
            actual.box.right,
            lessThanOrEqualTo(video.baseWidth.toDouble()),
            reason: slot.sceneName,
          );
        }
      }

      // Hand the payloads to tools/obs_frame_probe.mjs, which renders them
      // against a bright source and measures where the picture lands. The
      // camera here is dark, and a transform read-back only proves intent.
      final dumpPath = Platform.environment['OBS_LAYOUT_DUMP'];
      if (dumpPath != null && dumpPath.isNotEmpty) {
        File(dumpPath).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert([
            for (final slot in slots)
              {
                'scene': slot.sceneName,
                'layout': slot.layout.name,
                'transform': transformForLayout(slot.layout, video),
                'box': {
                  'left': framingForLayout(slot.layout, video).box.left,
                  'top': framingForLayout(slot.layout, video).box.top,
                  'width': framingForLayout(slot.layout, video).box.width,
                  'height': framingForLayout(slot.layout, video).box.height,
                },
              },
          ]),
        );
      }

      // Leave the install holding the rig the app ships with, so it still
      // works after this test: the picker can change it whenever.
      final tidy = await ObsRigReset(connection: client).run();
      expect(tidy.ok, isTrue, reason: tidy.messages.join(' | '));
      final rebuild = await ObsAutoSetup(
        connection: client,
        slots: AppConfig.cameras,
      ).run();
      expect(rebuild.ok, isTrue, reason: rebuild.messages.join(' | '));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  // The pairing screen's whole job is to tell a wrong address from a wrong
  // password, because the fixes are different. Both are checked against the
  // real OBS. Neither mutates anything: one attempt with a bad password, one
  // against a port nothing listens on.
  test('OBS rejects a wrong password as a wrong password', () async {
    if (!enabled) {
      markTestSkipped('set OBS_INTEGRATION=1 to run against a live OBS');
      return;
    }

    final client = ObsClient(
      uri: Uri.parse('ws://$host:$port/'),
      password: '$password-but-wrong',
      autoReconnect: false,
    );
    addTearDown(client.dispose);

    final status = await client.connectAndWait();
    expect(status.isConnected, isFalse);
    expect(status.failure, ObsFailure.wrongPassword, reason: status.detail);
    expect(status.detail, contains('password'));
  });

  test('a port with nothing on it is not mistaken for a wrong password', () async {
    if (!enabled) {
      markTestSkipped('set OBS_INTEGRATION=1 to run against a live OBS');
      return;
    }

    final client = ObsClient(
      // Port 1 is reserved and never has a listener to connect to.
      uri: Uri.parse('ws://$host:1/'),
      password: password,
      autoReconnect: false,
    );
    addTearDown(client.dispose);

    final status = await client.connectAndWait();
    expect(status.isConnected, isFalse);
    expect(status.failure, isNot(ObsFailure.none));
    expect(status.failure, isNot(ObsFailure.wrongPassword));
    expect(status.failure, ObsFailure.refused, reason: status.detail);
  });
}
