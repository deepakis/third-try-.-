import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/app_config.dart';
import 'package:open_flutter/teleprompter/script_model.dart';
import 'package:open_flutter/teleprompter/teleprompter_screen.dart';
import 'package:open_flutter/ui/theme.dart';

import 'fakes.dart';

/// Filler lines so a cue starts well below the reading line.
const String _filler = '''
Opening line one that the presenter reads first.
Second line, still talking to camera about the setup.
Third line, no cuts needed here yet.
Fourth line, still on the wide shot.
''';

void main() {
  const slots = AppConfig.cameras;

  group('resolveCueScene', () {
    test('maps camera numbers onto slots', () {
      expect(resolveCueScene('CAM 1', slots), 'Full_Cam');
      expect(resolveCueScene('cam 2', slots), 'Zoom_Cam');
      expect(resolveCueScene('CAMERA 1', slots), 'Full_Cam');
    });

    test('maps layouts onto the matching shot', () {
      expect(resolveCueScene('LAYOUT: FULL', slots), 'Full_Cam');
      expect(resolveCueScene('LAYOUT: PIP', slots), 'Zoom_Cam');
      expect(resolveCueScene('layout:pip', slots), 'Zoom_Cam');
    });

    test('ignores the detail after a colon and unknown tags', () {
      expect(resolveCueScene('CAM 2: ZOOM', slots), 'Zoom_Cam');
      expect(resolveCueScene('CAM 9', slots), isNull);
      expect(resolveCueScene('WHATEVER', slots), isNull);
    });
  });

  group('parseScript', () {
    test('lifts cues out of the lines they sit on', () {
      final doc = parseScript(
        'hello there\n[LAYOUT: PIP] and cut\ntail line',
        slots,
        title: 'Demo',
      );

      expect(doc.title, 'Demo');
      expect(doc.lines.length, 3);
      expect(doc.cues.length, 1);
      expect(doc.cues.single.lineIndex, 1);
      expect(doc.cues.single.sceneName, 'Zoom_Cam');
      expect(doc.cues.single.label, 'Camera B');
      // The tag stays in the text so the presenter reads past it.
      expect(doc.lines[1].text, contains('[LAYOUT: PIP]'));
      expect(doc.lines[1].hasCue, isTrue);
      expect(doc.lines[0].hasCue, isFalse);
    });

    test('keeps an unrecognised tag, with no action attached', () {
      final doc = parseScript('line\n[SOUND: APPLAUSE]', slots);
      expect(doc.cues.single.hasAction, isFalse);
      expect(doc.cues.single.label, 'unrecognised cue');
    });
  });

  Widget prompter(String script, FakeObsConnection obs, {double speed = 0}) {
    return MaterialApp(
      theme: buildAppTheme(),
      home: TeleprompterScreen(
        connection: obs,
        slots: slots,
        script: script,
        initialSpeed: speed,
      ),
    );
  }

  group('TeleprompterScreen', () {
    testWidgets('shows the reading line, cue chips and controls', (
      tester,
    ) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(prompter('$_filler[CAM 2]\nafter', obs));
      await tester.pump();
      await obs.connect();
      await tester.pump();

      expect(find.text('NOW'), findsOneWidget);
      expect(find.text('NEXT'), findsOneWidget);
      expect(find.text('Restart'), findsOneWidget);
      expect(find.text('Next cue'), findsOneWidget);
      expect(find.textContaining('OBS · '), findsOneWidget);
      // The next cue is the [CAM 2] line.
      expect(find.textContaining('CAM 2'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('header shows the live program scene on open', (tester) async {
      final obs = FakeObsConnection(
        scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
        programScene: 'Zoom_Cam',
      );
      await tester.pumpWidget(prompter('$_filler[CAM 2]', obs));
      await obs.connect();
      await tester.pump();

      expect(find.text('OBS · Zoom_Cam'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('fires the OBS cut when a cue crosses the reading line', (
      tester,
    ) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(prompter('$_filler[CAM 2]\nafter the cut', obs));
      await tester.pump();

      expect(obs.calls, isEmpty, reason: 'cue starts below the line');

      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -560));
      await tester.pump();

      expect(obs.calls, ['set:Zoom_Cam']);
      expect(find.textContaining('CAM 2  →  Zoom_Cam'), findsWidgets);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('re-fires after scrolling back above the cue', (tester) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(prompter('$_filler[CAM 2]\nafter the cut', obs));
      await tester.pump();

      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -560));
      await tester.pump();
      expect(obs.calls.length, 1);

      // Back up above the reading line…
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 700));
      await tester.pump();
      // …then down again: the cut must happen a second time.
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -560));
      await tester.pump();

      expect(obs.calls, ['set:Zoom_Cam', 'set:Zoom_Cam']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('auto-scroll alone is enough to fire a cue', (tester) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(
        prompter('$_filler[CAM 2]\nafter the cut', obs, speed: 600),
      );

      // Let the ticker run: the cue sits ~500px below the reading line, and
      // 3 seconds at 600 px/s is well past it.
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      expect(obs.calls, ['set:Zoom_Cam']);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a long frame gap does not teleport the script', (
      tester,
    ) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(
        prompter('$_filler[CAM 2]\nafter the cut', obs, speed: 600),
      );
      await tester.pump(const Duration(milliseconds: 16));

      // One frame arriving 20 seconds late (throttled/backgrounded window).
      await tester.pump(const Duration(seconds: 20));

      final offset = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      // Capped at 0.1s of travel (60px), not 12000px, so the cue is untouched.
      expect(offset, lessThan(100));
      expect(obs.calls, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an unrecognised tag never touches OBS', (tester) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(
        prompter('$_filler[SOUND: APPLAUSE]\nafter', obs),
      );
      await tester.pump();

      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -560));
      await tester.pump();

      expect(obs.calls, isEmpty);
      expect(find.textContaining('nothing to switch to'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('reports a failed cut without crashing', (tester) async {
      final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
      await tester.pumpWidget(prompter('$_filler[CAM 1]\nafter', obs));
      await tester.pump();

      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -560));
      await tester.pump();

      // Camera A already equals a real scene here, so this should succeed.
      expect(obs.calls, ['set:Full_Cam']);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
