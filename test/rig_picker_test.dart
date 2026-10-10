import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/ui/rig_picker.dart';
import 'package:open_flutter/ui/theme.dart';

/// The picker is a desktop dialog: give it the width a laptop actually has.
Future<void> pumpPicker(
  WidgetTester tester, {
  Size size = const Size(1280, 900),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => RigPickerDialog.show(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lays out every shot without overflowing', (tester) async {
    await pumpPicker(tester);

    expect(find.text('Pick your shots'), findsOneWidget);
    for (final id in const ['full', 'zoom', 'side', 'bottom', 'top']) {
      expect(find.byKey(ValueKey('shot-$id')), findsOneWidget);
    }
    // The default rig: two picks, each labelled with the key it will get.
    expect(find.text('KEY 1'), findsOneWidget);
    expect(find.text('KEY 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('never lets a fourth shot be picked', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.byKey(const ValueKey('shot-side')));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 selected · keys 1 / 2 / 3'), findsOneWidget);

    // The two shots that would be a fourth key are inert.
    await tester.tap(find.byKey(const ValueKey('shot-bottom')));
    await tester.pumpAndSettle();
    expect(find.text('3 of 3 selected · keys 1 / 2 / 3'), findsOneWidget);

    // ...but a picked one can still be dropped.
    await tester.tap(find.byKey(const ValueKey('shot-full')));
    await tester.pumpAndSettle();
    expect(find.text('2 of 3 selected · keys 1 / 2'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('returns the picks in the order they were tapped', (
    tester,
  ) async {
    List<String>? picked;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await RigPickerDialog.show(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Drop both defaults, then pick a rig of our own.
    for (final id in const ['full', 'zoom', 'bottom', 'top', 'side']) {
      await tester.tap(find.byKey(ValueKey('shot-$id')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Set up OBS'));
    await tester.pumpAndSettle();

    // Tap order, not catalog order: "bottom" was the first shot kept.
    expect(picked, ['bottom', 'top', 'side']);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling returns nothing', (tester) async {
    List<String>? picked;
    var returned = false;
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await RigPickerDialog.show(context);
                  returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(returned, isTrue);
    expect(picked, isNull);

    await tester.pumpWidget(const SizedBox());
  });
}
