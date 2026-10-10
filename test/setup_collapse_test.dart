import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/obs_models.dart';
import 'package:open_flutter/ui/switcher_screen.dart';
import 'package:open_flutter/ui/theme.dart';

import 'fakes.dart';

void main() {
  testWidgets('minimizing the setup folds it, and it can be opened again', (
    tester,
  ) async {
    // A fresh rig: the shots are not in OBS yet, so the setup card is up.
    final fake = FakeObsConnection(
      scenes: [scene('Scene', 0)],
      inputs: const [ObsInput(name: 'Cam', kind: 'dshow_input')],
    );
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: SwitcherScreen(connection: fake),
      ),
    );
    await fake.connect();
    await tester.pumpAndSettle();

    expect(find.text('Set up Full + Zoom'), findsOneWidget);

    await tester.tap(find.byTooltip('Minimize setup'));
    await tester.pumpAndSettle();

    // Folded, not gone: the headline and a way back stay on screen.
    expect(find.text('Set up Full + Zoom'), findsNothing);
    expect(find.text('Your shots are not set up in OBS yet'), findsOneWidget);
    expect(find.text('Show setup'), findsOneWidget);

    await tester.tap(find.text('Show setup'));
    await tester.pumpAndSettle();

    expect(find.text('Set up Full + Zoom'), findsOneWidget);
    expect(find.text('Show setup'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
