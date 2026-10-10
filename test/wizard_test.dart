import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/obs_models.dart';
import 'package:open_flutter/ui/camera_tile.dart';
import 'package:open_flutter/ui/rig_picker.dart';
import 'package:open_flutter/ui/switcher_screen.dart';
import 'package:open_flutter/ui/theme.dart';
import 'package:open_flutter/ui/wizard.dart';

import 'fakes.dart';

const Size _desktop = Size(1280, 900);

/// The first-run flow after pairing: the switcher is the screen pairing hands
/// over to, so the header says which OBS it landed on and the wizard carries
/// steps 2 and 3.
Future<void> pumpSwitcher(
  WidgetTester tester,
  FakeObsConnection fake, {
  String? endpoint,
  VoidCallback? onPair,
  WizardMode wizard = WizardMode.off,
  bool connect = true,
  Size size = _desktop,
}) async {
  // The view, not `setSurfaceSize`: measured in this Flutter version, asking for
  // 1280x900 left the media query at 800x600, and this layout branches on the
  // height (compact guidance below 720), so the surface has to be real for the
  // desktop and cramped cases to be two different tests.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: SwitcherScreen(
        connection: fake,
        endpoint: endpoint,
        onPair: onPair,
        wizard: wizard,
      ),
    ),
  );
  if (connect) {
    await fake.connect();
    await tester.pumpAndSettle();
  }
}

void main() {
  group('switcher header', () {
    testWidgets('shows which OBS it is on instead of a Connect button', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(
        tester,
        fake,
        endpoint: '127.0.0.1:4455',
        onPair: () {},
      );

      // Being asked to connect while connected was the bug.
      expect(find.text('Connect…'), findsNothing);
      expect(find.text('127.0.0.1:4455'), findsOneWidget);
      expect(find.text('OBS 32.2.2'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('offers Connect while it has no socket', (tester) async {
      final fake = FakeObsConnection();
      await pumpSwitcher(
        tester,
        fake,
        endpoint: '127.0.0.1:4455',
        onPair: () {},
        connect: false,
      );

      expect(find.text('Connect…'), findsOneWidget);
      // The address is not a claim about a connection that isn't up.
      expect(find.text('127.0.0.1:4455'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tapping the address opens pairing', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
      );
      var paired = false;
      await pumpSwitcher(
        tester,
        fake,
        endpoint: '10.0.0.5:4455',
        onPair: () => paired = true,
      );

      await tester.tap(find.text('10.0.0.5:4455'));
      await tester.pumpAndSettle();

      expect(paired, isTrue);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('first-run wizard', () {
    testWidgets('skips the picker and goes live over a rig that exists', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake, wizard: WizardMode.pairing);

      expect(find.byType(RigPickerDialog), findsNothing);
      expect(
        find.text('You are live on "Full_Cam". Press 1 / 2 or tap a tile to '
            'cut.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(WizardBanner), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('step 2 sets up the shots already chosen, without a dialog', (
      tester,
    ) async {
      final fake = FakeObsConnection(scenes: [scene('Scene', 0)]);
      await pumpSwitcher(tester, fake, wizard: WizardMode.pairing);

      // Someone who has shots is not asked to choose them again.
      expect(find.byType(RigPickerDialog), findsNothing);
      expect(find.textContaining('Step 2 of 3'), findsOneWidget);
      expect(find.text('Set up Full + Zoom'), findsOneWidget);
      expect(find.text('Change shots'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('changing the shots is behind the secondary button', (
      tester,
    ) async {
      final fake = FakeObsConnection(scenes: [scene('Scene', 0)]);
      await pumpSwitcher(tester, fake, wizard: WizardMode.pairing);

      await tester.tap(find.text('Change shots'));
      await tester.pumpAndSettle();
      expect(find.byType(RigPickerDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      // Still step 2: the shots were never changed.
      expect(find.textContaining('Step 2 of 3'), findsOneWidget);
      expect(find.textContaining('You are live'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('building the rig finishes the wizard at step 3', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Scene', 0)],
        inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
      );
      await pumpSwitcher(tester, fake, wizard: WizardMode.pairing);

      await tester.tap(find.text('Set up Full + Zoom'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(find.text('OBS is configured'), findsOneWidget);
      expect(find.textContaining('Step 3 of 3'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a later launch offers step 2 without opening the picker', (
      tester,
    ) async {
      // The screen this thread was looking at: an endpoint restored from
      // storage, and a rig that was never built.
      final fake = FakeObsConnection(scenes: [scene('Scene', 0)]);
      await pumpSwitcher(tester, fake, wizard: WizardMode.ifMissing);

      expect(find.textContaining('Step 2 of 3'), findsOneWidget);
      // Offered, not forced.
      expect(find.byType(RigPickerDialog), findsNothing);
      expect(find.text('Set up Full + Zoom'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the guidance never squeezes the cameras out of the window', (
      tester,
    ) async {
      // Caught in the live app, twice over: a wizard strip stacked on the setup
      // banner pushed the footer past the bottom edge ("BOTTOM OVERFLOWED BY 15
      // PIXELS"), and the tiles were left with *zero* height — the cameras were
      // not showing at all. 428x641 is the embedded preview that showed it.
      final fake = FakeObsConnection(scenes: [scene('Scene', 0)]);
      await pumpSwitcher(
        tester,
        fake,
        wizard: WizardMode.ifMissing,
        size: const Size(428, 641),
      );

      expect(tester.takeException(), isNull);
      // The point of the page: the shots are on screen and usable.
      final tile = tester.getSize(find.byType(CameraTile).first);
      expect(
        tile.height,
        greaterThan(120),
        reason: 'the cameras were squeezed out by the guidance',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a later launch over a finished rig says nothing', (
      tester,
    ) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake, wizard: WizardMode.ifMissing);

      expect(find.byType(WizardBanner), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a normal launch runs no wizard at all', (tester) async {
      final fake = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Full_Cam',
      );
      await pumpSwitcher(tester, fake);

      expect(find.byType(WizardBanner), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
