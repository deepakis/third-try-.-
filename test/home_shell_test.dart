import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/ui/home_shell.dart';
import 'package:open_flutter/ui/theme.dart';

import 'fakes.dart';

/// Pumps the shell at [size] and connects the fake, the way the app does.
Future<FakeObsConnection> pumpShell(WidgetTester tester, Size size) async {
  final fake = FakeObsConnection(
    scenes: [scene('Full_Cam', 0), scene('Zoom_Cam', 1)],
    programScene: 'Full_Cam',
  );
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: HomeShell(connection: fake, endpoint: '127.0.0.1:4455'),
    ),
  );
  await fake.connect();
  // Not pumpAndSettle: the prompter's ticker keeps frames coming.
  await tester.pump(const Duration(milliseconds: 300));
  return fake;
}

void main() {
  testWidgets('a phone gets a bottom bar, and the three pages switch', (
    tester,
  ) async {
    await pumpShell(tester, const Size(420, 860));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Cameras'), findsOneWidget);
    expect(find.text('Prompter'), findsOneWidget);
    expect(find.text('Setup'), findsOneWidget);

    await tester.tap(find.text('Setup'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('OBS CONNECTION'), findsOneWidget);
    expect(find.text('obsws://127.0.0.1:4455'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);

    await tester.tap(find.text('Prompter'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Paste a script'), findsOneWidget);
    // Embedded in the shell there is nothing to go back to.
    expect(find.byTooltip('Back to the switcher'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wide window gets a side rail instead of the bar', (
    tester,
  ) async {
    await pumpShell(tester, const Size(1200, 800));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the teleprompter button on the Cameras page opens the Prompter tab', (
    tester,
  ) async {
    await pumpShell(tester, const Size(1200, 800));

    await tester.tap(find.text('Teleprompter'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byTooltip('Paste a script'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
