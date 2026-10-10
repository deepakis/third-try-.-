import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/app_config.dart';
import 'package:open_flutter/teleprompter/paste_script_page.dart';
import 'package:open_flutter/teleprompter/script_model.dart';
import 'package:open_flutter/teleprompter/teleprompter_screen.dart';
import 'package:open_flutter/ui/theme.dart';

import 'fakes.dart';

const _filler = '''
Opening line one that the presenter reads first.
Second line, still talking to camera about the setup.
Third line, no cuts needed here yet.
Fourth line, still on the wide shot.
''';

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 400));

void main() {
  const slots = AppConfig.cameras;

  group('cue tags from a pasted script', () {
    test('a layout cue works with or without the colon', () {
      expect(resolveCueScene('LAYOUT: PIP', slots), 'Zoom_Cam');
      expect(resolveCueScene('LAYOUT PIP', slots), 'Zoom_Cam');
      expect(resolveCueScene('layout:full', slots), 'Full_Cam');
    });

    test('other bracketed instructions stay in the script with no action', () {
      final doc = parseScript('Say it slowly [pause] then go\n[B-roll]', slots);
      expect(doc.cues.length, 2);
      expect(doc.cues.every((cue) => !cue.hasAction), isTrue);
      expect(doc.lines.first.text, contains('[pause]'));
    });
  });

  testWidgets('the paste page counts cuts and notes as the script is typed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const PasteScriptPage(slots: slots),
      ),
    );

    expect(find.text('Nothing pasted yet.'), findsOneWidget);
    final load = find.widgetWithText(FilledButton, 'Load into the teleprompter');
    expect(tester.widget<FilledButton>(load).onPressed, isNull);

    await tester.enterText(
      find.byType(TextField),
      'Hello there\n[CAM 1]\nNext [pause] line\n[CAM 9]',
    );
    await tester.pump();

    // [CAM 1] drives OBS; [pause] and [CAM 9] (no such camera) are notes.
    expect(find.text('1 cut'), findsOneWidget);
    expect(find.text('2 notes'), findsOneWidget);
    expect(find.text('[CAM 1] → Camera A'), findsOneWidget);
    expect(find.text('No cut in this script yet. It will still read, but nothing will switch in OBS.'), findsNothing);
    expect(tester.widget<FilledButton>(load).onPressed, isNotNull);
  });

  testWidgets('a pasted script with no cuts says nothing will switch', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: const PasteScriptPage(slots: slots),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Just words, no cues.');
    await tester.pump();

    expect(find.textContaining('nothing will'), findsOneWidget);
  });

  testWidgets('loading a pasted script replaces the one on screen', (
    tester,
  ) async {
    final obs = FakeObsConnection(scenes: [scene('Full_Cam', 0)]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: TeleprompterScreen(
          connection: obs,
          slots: slots,
          script: '${_filler}Old script.\n',
          initialSpeed: 0,
        ),
      ),
    );
    await tester.pump();
    await obs.connect();
    await tester.pump();

    // Call the header button's handler directly: the gesture itself is not what
    // this test is about, and the page must open from it.
    final paste = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.content_paste_rounded),
        matching: find.byType(IconButton),
      ),
    );
    paste.onPressed!();
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PasteScriptPage), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      '${_filler}New script with a cut.\n[CAM 2]\nafter',
    );
    await tester.pump();
    await tester.tap(find.text('Load into the teleprompter'));
    await _settle(tester);

    expect(find.text('Pasted script'), findsOneWidget);
    expect(find.text('loaded · 1 cue'), findsOneWidget);
    // Script lines are rich text, so match them exactly and say so.
    expect(
      find.text('New script with a cut.', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Old script.', findRichText: true), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
