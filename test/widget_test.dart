import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/obs_client.dart';
import 'package:open_flutter/obs/obs_models.dart';
import 'package:open_flutter/teleprompter/teleprompter_screen.dart';
import 'package:open_flutter/ui/camera_tile.dart';
import 'package:open_flutter/ui/switcher_screen.dart';
import 'package:open_flutter/ui/theme.dart';

import 'fakes.dart';

/// The switcher is a desktop control surface, so tests run it at desktop size
/// (the cramped-window behaviour is covered by its own test).
const Size _desktop = Size(1280, 900);

/// Pumps the switcher and starts the connection the way the app does — injected
/// connections are owned by the caller, so the screen deliberately doesn't
/// connect them itself.
Future<void> pumpSwitcher(
  WidgetTester tester,
  FakeObsConnection fake, {
  Size size = _desktop,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: SwitcherScreen(connection: fake),
    ),
  );
  await fake.connect();
  await tester.pumpAndSettle();
}

void main() {
  group('authString', () {
    test('matches the obs-websocket v5 challenge/salt algorithm', () {
      // Known answer, produced independently with node:crypto.
      expect(
        authString(
          'C8RsC84pViTVESA5',
          salt: 'FHDleVLT0MfAB/AZr9n3Lvs+q8ZPuxwckbI7vC179R4=',
          challenge: 'Rz9Wjd7LjeD02lUxgzgAC6sxsO1HWT9zVtnsYwmDmb0=',
        ),
        'Y2+wfuZHDyLa1BLYR2z6NUqfAIuFuEkmQFqaZlgwA8g=',
      );
    });
  });

  group('resolveTargets', () {
    const slots = [
      CameraSlot(
        id: 'A',
        label: 'Camera A',
        sceneName: 'Camera A',
        description: 'a',
        layout: CameraLayout.fullBleed,
      ),
      CameraSlot(
        id: 'B',
        label: 'Camera B',
        sceneName: 'Camera B',
        description: 'b',
        layout: CameraLayout.bottomPiP,
      ),
    ];

    test('binds each tile to the scene with its name, case-insensitively', () {
      final targets = resolveTargets(slots, [
        scene('camera b', 0),
        scene('CAMERA A', 1),
      ]);
      expect(targets['A']?.name, 'CAMERA A');
      expect(targets['B']?.name, 'camera b');
    });

    test('never drifts onto an unrelated scene', () {
      // The old positional fallback would have pointed A at this scene.
      final targets = resolveTargets(slots, [scene('Scene', 0)]);
      expect(targets['A'], isNull);
      expect(targets['B'], isNull);
    });
  });

  group('SwitcherScreen', () {
    testWidgets('shows both shots and marks the program scene live', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      expect(find.byType(CameraTile), findsNWidgets(2));
      expect(find.text('Webcam · full frame'), findsOneWidget);
      expect(find.text('Webcam · 130% digital zoom'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('ON AIR · Full_Cam'), findsOneWidget);

      final tiles = tester.widgetList<CameraTile>(find.byType(CameraTile));
      expect(tiles.firstWhere((t) => t.slot.id == 'A').isLive, isTrue);
      expect(tiles.firstWhere((t) => t.slot.id == 'B').isLive, isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping Camera B cuts OBS to Camera B', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      await tester.tap(find.byType(CameraTile).last);
      await tester.pumpAndSettle();

      expect(fake.calls, contains('set:Zoom_Cam'));
      expect(find.text('ON AIR · Zoom_Cam'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keyboard shortcut 2 cuts to the second shot', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.pumpAndSettle();

      expect(fake.calls, contains('set:Zoom_Cam'));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('creates a missing scene, then cuts to it', (tester) async {
      final fake = FakeObsConnection(scenes: [scene('Scene', 0)]);
      await pumpSwitcher(tester, fake);

      expect(find.textContaining('No "Full_Cam" scene'), findsOneWidget);

      await tester.tap(find.byType(CameraTile).first);
      await tester.pumpAndSettle();

      expect(fake.calls, ['createScene:Full_Cam', 'set:Full_Cam']);
      expect(find.text('ON AIR · Full_Cam'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('stays read-only when auto-create is switched off', (
      tester,
    ) async {
      final fake = FakeObsConnection(scenes: [scene('Scene', 0)]);
      await pumpSwitcher(tester, fake);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CameraTile).first);
      await tester.pumpAndSettle();

      expect(fake.calls, isEmpty);
      expect(find.textContaining('no "Full_Cam" scene in OBS'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reports a failed scene creation instead of crashing', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Scene', 0)],
        createThrows: true,
      );
      await pumpSwitcher(tester, fake);

      await tester.tap(find.byType(CameraTile).first);
      await tester.pumpAndSettle();

      expect(fake.calls, ['createScene:Full_Cam']);
      expect(find.textContaining('nope'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('previews never render for an empty scene', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        sourceCounts: {'Full_Cam': 2, 'Zoom_Cam': 0},
      );
      await pumpSwitcher(tester, fake);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();

      expect(
        find.text('Scene is empty — add a capture source in OBS'),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('opens the teleprompter on the same OBS connection', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      await tester.tap(find.text('Teleprompter'));
      // No pumpAndSettle after this: the prompter's scroll ticker never settles.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(TeleprompterScreen), findsOneWidget);
      final prompter = tester.widget<TeleprompterScreen>(
        find.byType(TeleprompterScreen),
      );
      expect(identical(prompter.connection, fake), isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('builds the rig from the banner when none exists', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Scene', 0)],
        inputs: const [
          ObsInput(name: 'Video Capture Device', kind: 'dshow_input'),
        ],
      );
      await pumpSwitcher(tester, fake);

      // The shots the operator already has are the main action now, not a
      // request to choose them again.
      expect(find.text('Set up Full + Zoom'), findsOneWidget);
      expect(find.text('Change shots'), findsOneWidget);

      await tester.tap(find.text('Set up Full + Zoom'));
      // Not pumpAndSettle: the banner shows a spinner while it runs.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      // Nothing existed, so nothing was deleted on the way.
      expect(fake.calls.where((call) => call.startsWith('removeScene')), isEmpty);
      expect(fake.calls, contains('createScene:Full_Cam'));
      expect(fake.calls, contains('createScene:Zoom_Cam'));
      expect(fake.calls, contains('createSceneItem:Zoom_Cam:Video Capture Device'));
      expect(find.text('OBS is configured'), findsOneWidget);
      expect(find.text('Run again'), findsOneWidget);
      // The tiles can now resolve what they drive.
      expect(find.textContaining('OBS scene · Full_Cam'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the picker decides which scenes get built and in what order',
        (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Scene', 0)],
        inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
      );
      await pumpSwitcher(tester, fake);

      await tester.tap(find.text('Change shots'));
      await tester.pumpAndSettle();

      // Untick the two defaults, then pick a rig of our own: top box first, so
      // it becomes key 1.
      for (final id in const ['full', 'zoom', 'top', 'bottom']) {
        await tester.tap(find.byKey(ValueKey('shot-$id')));
        await tester.pumpAndSettle();
      }
      expect(find.text('2 of 3 selected · keys 1 / 2'), findsOneWidget);

      await tester.tap(find.text('Set up OBS'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(fake.calls, contains('createScene:Top_Cam'));
      expect(fake.calls, contains('createScene:Bottom_Cam'));
      // The rig we picked, in the order we picked it.
      final tiles = tester.widgetList<CameraTile>(find.byType(CameraTile)).toList();
      expect(tiles, hasLength(2));
      expect(tiles[0].slot.sceneName, 'Top_Cam');
      expect(tiles[1].slot.sceneName, 'Bottom_Cam');
      expect(find.textContaining('OBS scene · Top_Cam'), findsOneWidget);
      // Keycap hint in the footer, plus the tile's own name.
      expect(find.text('Camera A'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a rebuild shows what it will delete, and Cancel deletes nothing',
        (tester) async {
      // A half-built rig: the banner is up, and one rig scene is in OBS.
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Scene', 1)],
        inputs: const [ObsInput(name: 'Video Capture Device', kind: 'dshow_input')],
      );
      await pumpSwitcher(tester, fake);

      await tester.tap(find.text('Reset the rig in OBS'));
      await tester.pumpAndSettle();

      expect(find.text('Rebuild the rig from scratch?'), findsOneWidget);
      expect(find.textContaining('Deleted from OBS first: Full_Cam'), findsOneWidget);
      expect(find.textContaining('your own scenes are left alone'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fake.calls, isEmpty);
      expect(find.textContaining('OBS scene · Full_Cam'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('confirming a reset clears the app rig scenes in OBS',
        (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Side_Cam', 1), scene('Scene', 2)],
        programScene: 'Full_Cam',
        inputs: const [ObsInput(name: 'Video Capture Device', kind: 'dshow_input')],
      );
      await pumpSwitcher(tester, fake);

      await tester.tap(find.text('Reset the rig in OBS'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Deleted from OBS first: Full_Cam, Side_Cam'),
        findsOneWidget,
      );

      await tester.tap(find.text('Remove'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      // Stepped off the scene going out before deleting it.
      expect(fake.calls, ['set:Scene', 'removeScene:Full_Cam', 'removeScene:Side_Cam']);
      // The user's own scene and camera source survive.
      expect(fake.scenes.map((s) => s.name), ['Scene']);
      expect(fake.inputList.map((i) => i.name), ['Video Capture Device']);
      expect(find.text('OBS is configured'), findsNothing);
      expect(find.text('Set up Full + Zoom'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('takes its shots from the rig already in OBS', (tester) async {
      // Built by an earlier session: the config's Full_Cam/Zoom_Cam are gone.
      final fake = FakeObsConnection(
        scenes: [scene('Side_Cam', 0), scene('Bottom_Cam', 1)],
        programScene: 'Side_Cam',
      );
      await pumpSwitcher(tester, fake);

      final tiles = tester.widgetList<CameraTile>(find.byType(CameraTile)).toList();
      expect(tiles[0].slot.sceneName, 'Side_Cam');
      expect(tiles[1].slot.sceneName, 'Bottom_Cam');
      expect(find.text('Webcam · strip down the side'), findsOneWidget);
      // Adopted, so there is nothing to set up.
      expect(find.text('Set up Full + Zoom'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a long setup report never crowds the tiles out', (
      tester,
    ) async {
      // Caught in the live app: a from-scratch run reports a dozen steps, and in
      // a small window the banner grew until the tiles were squeezed to nothing.
      // 480x667 is the size of the embedded preview that caught it.
      final fake = FakeObsConnection(
        scenes: [scene('Scene', 0)],
        inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
      );
      await pumpSwitcher(tester, fake, size: const Size(480, 667));

      // The banner scrolls internally on a window this small; the button is
      // there to be reached, not clipped away.
      await tester.ensureVisible(find.text('Set up Full + Zoom'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set up Full + Zoom'));
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }

      expect(find.text('OBS is configured'), findsOneWidget);
      expect(find.byType(CameraTile), findsNWidgets(2));
      for (final element in find.byType(CameraTile).evaluate()) {
        expect(
          element.size!.height,
          greaterThan(120),
          reason: 'a tile was squeezed out by the setup report',
        );
      }

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('does not nag once both scenes exist', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      expect(find.text('Auto-Configure OBS'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('keyboard shortcut T opens the teleprompter', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(TeleprompterScreen), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('drops the secondary line on a short window', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      // Wide but short: the tiles stay side by side and run out of height.
      await pumpSwitcher(tester, fake, size: const Size(1280, 480));

      // The shot name and its state stay; only the blurb goes.
      expect(find.text('Camera A'), findsWidgets);
      expect(find.text('Webcam · full frame'), findsNothing);
      expect(find.textContaining('OBS scene · Full_Cam'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
