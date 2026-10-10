import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/connection_target.dart';
import 'package:open_flutter/obs/obs_models.dart';
import 'package:open_flutter/ui/connect_screen.dart';
import 'package:open_flutter/ui/theme.dart';

const _connected = ObsStatus(
  ObsConnectionState.identified,
  detail: 'OBS 32.2.2',
);

Future<void> pumpConnect(
  WidgetTester tester, {
  ConnectionTarget? initial,
  Future<ObsStatus> Function(ConnectionTarget target)? probe,
  void Function(ConnectionTarget target)? onConnected,
  VoidCallback? onLater,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: ConnectScreen(
        initialTarget: initial,
        probe: probe,
        onConnected: onConnected,
        onLater: onLater,
      ),
    ),
  );
}

/// A probe that records what it was asked to reach and answers with [status].
Future<ObsStatus> Function(ConnectionTarget) answering(
  ObsStatus status,
  List<ConnectionTarget> seen,
) => (target) async {
  seen.add(target);
  return status;
};

void main() {
  testWidgets('pasting the line OBS shows fills the fields', (tester) async {
    await pumpConnect(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'obsws://192.168.1.20:4466/hunter2',
    );
    await tester.pumpAndSettle();

    // Host, port and password fields, in order.
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((field) => field.controller?.text)
        .toList();
    expect(fields, ['obsws://192.168.1.20:4466/hunter2', '192.168.1.20', '4466', 'hunter2']);
    expect(
      find.textContaining('Connecting to ws://192.168.1.20:4466/'),
      findsOneWidget,
    );
  });

  testWidgets('prose pasted into the box is rejected with a hint', (
    tester,
  ) async {
    await pumpConnect(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'my obs is on the other laptop',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No OBS address in that'), findsOneWidget);
    // The connect button stays disabled: there is no address to dial.
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('a wrong password is named as one, with the fix', (tester) async {
    final seen = <ConnectionTarget>[];
    ConnectionTarget? paired;
    await pumpConnect(
      tester,
      probe: answering(
        const ObsStatus(
          ObsConnectionState.disconnected,
          detail: 'password rejected by OBS',
          failure: ObsFailure.wrongPassword,
        ),
        seen,
      ),
      onConnected: (target) => paired = target,
    );

    await tester.enterText(find.byType(TextField).first, '192.168.1.20:4455');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(3), 'wrong-password');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(seen.single.password, 'wrong-password');
    expect(paired, isNull, reason: 'a rejected password is not a pairing');
    expect(find.textContaining('rejected the password'), findsOneWidget);
    expect(find.textContaining('Show Connect Info'), findsWidgets);
    // The raw reason stays visible for a bug report.
    expect(find.text('password rejected by OBS'), findsOneWidget);
  });

  testWidgets('a refused port says nothing is listening there', (tester) async {
    await pumpConnect(
      tester,
      probe: answering(
        const ObsStatus(
          ObsConnectionState.disconnected,
          detail: 'unreachable — Connection refused',
          failure: ObsFailure.refused,
        ),
        <ConnectionTarget>[],
      ),
    );

    await tester.enterText(find.byType(TextField).first, '192.168.1.20:4455');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(
      find.text('Something is at 192.168.1.20, but nothing answers on port 4455'),
      findsOneWidget,
    );
    expect(find.textContaining('Enable WebSocket server'), findsOneWidget);
  });

  testWidgets('an unreachable host is told the Wi-Fi rules', (tester) async {
    await pumpConnect(
      tester,
      probe: answering(
        const ObsStatus(
          ObsConnectionState.disconnected,
          detail: 'no reply from 10.82.181.253:4455',
          failure: ObsFailure.unreachable,
        ),
        <ConnectionTarget>[],
      ),
    );

    await tester.enterText(find.byType(TextField).first, '10.82.181.253:4455');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't reach 10.82.181.253:4455"), findsOneWidget);
    expect(find.textContaining('same Wi-Fi'), findsOneWidget);
    expect(find.textContaining('127.0.0.1 means'), findsOneWidget);
    expect(find.textContaining('firewall'), findsOneWidget);
  });

  testWidgets('a successful connect hands the endpoint to the caller', (
    tester,
  ) async {
    ConnectionTarget? paired;
    await pumpConnect(
      tester,
      probe: answering(_connected, <ConnectionTarget>[]),
      onConnected: (target) => paired = target,
    );

    await tester.enterText(
      find.byType(TextField).first,
      'obsws://10.0.0.5:4959/hunter2',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(
      paired,
      const ConnectionTarget(host: '10.0.0.5', port: 4959, password: 'hunter2'),
    );
    expect(find.text('Connected to OBS 32.2.2'), findsOneWidget);
  });

  testWidgets('set up later hands control back without connecting', (
    tester,
  ) async {
    final seen = <ConnectionTarget>[];
    var later = false;
    await pumpConnect(
      tester,
      probe: answering(_connected, seen),
      onLater: () => later = true,
    );

    await tester.tap(find.text('Set up later'));
    await tester.pumpAndSettle();

    expect(later, isTrue);
    expect(seen, isEmpty, reason: 'skipping pairing must not dial anything');
  });

  testWidgets('a prefilled endpoint is a single tap away', (tester) async {
    final seen = <ConnectionTarget>[];
    await pumpConnect(
      tester,
      initial: const ConnectionTarget(
        host: '127.0.0.1',
        port: 4455,
        password: 'hunter2',
      ),
      probe: answering(_connected, seen),
    );

    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(seen.single, const ConnectionTarget(host: '127.0.0.1', password: 'hunter2'));
  });

  testWidgets('the password is masked until it is revealed', (tester) async {
    await pumpConnect(
      tester,
      initial: const ConnectionTarget(host: '127.0.0.1', password: 'hunter2'),
    );

    final field = tester.widget<TextField>(find.byType(TextField).at(3));
    expect(field.obscureText, isTrue);

    await tester.tap(find.byIcon(Icons.visibility_rounded));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField).at(3)).obscureText, isFalse);
  });

  testWidgets('the advice names the fix for a blocked ws:// on https', (
    tester,
  ) async {
    // The advice text itself, since the warning banner only appears on a real
    // https page (there is no way to fake Uri.base in a widget test).
    final advice = adviceFor(
      ObsFailure.mixedContent,
      host: '127.0.0.1',
      port: 4455,
    );
    expect(advice.title, contains('blocked'));
    expect(advice.steps.join(' '), contains('http://'));
  });
}
