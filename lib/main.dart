import 'dart:async';

import 'package:flutter/material.dart';

import 'app_config.dart';
import 'obs/connection_target.dart';
import 'obs/endpoint_store.dart';
import 'obs/obs_client.dart';
import 'ui/connect_screen.dart';
import 'ui/home_shell.dart';
import 'ui/switcher_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const OpenFlutterApp());
}

/// Holds the one OBS connection for the whole session: the switcher and the
/// teleprompter are two views onto the same socket.
///
/// Pairing a different OBS replaces that connection wholesale — `ObsClient`
/// fixes its endpoint when it is constructed — and the screens are keyed by the
/// connection, so they re-subscribe to the new client instead of holding a
/// socket to the old endpoint.
class OpenFlutterApp extends StatefulWidget {
  const OpenFlutterApp({super.key, this.store});

  /// Where the paired endpoint is remembered. Injected in tests so they never
  /// touch the real config file or browser storage.
  final EndpointStore? store;

  @override
  State<OpenFlutterApp> createState() => _OpenFlutterAppState();
}

class _OpenFlutterAppState extends State<OpenFlutterApp> {
  late final EndpointStore _store = widget.store ?? createEndpointStore();

  /// The endpoint paired on this machine, or null when nothing is paired yet.
  ConnectionTarget? _paired;

  /// What the current client is dialling. Shown in the switcher's header, so
  /// "which OBS am I on?" has an answer on screen.
  ConnectionTarget? _active;

  ObsClient? _obs;

  /// Bumped for every connection, so the screens rebuild against the new client.
  int _connectionSeq = 0;

  /// False until the store has answered: the pairing screen should not flash in
  /// front of someone who paired weeks ago.
  bool _restored = false;

  /// Whether the pairing screen is up. This is also how "set up later" is
  /// remembered — the app runs on the build's own endpoint until someone pairs.
  bool _pairing = false;

  /// True when the switcher on screen is the one pairing just handed over to.
  bool _wizardPending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_restore());
  }

  Future<void> _restore() async {
    ConnectionTarget? stored;
    try {
      stored = await _store.load();
    } catch (error) {
      debugPrint('[pairing] could not read the saved endpoint: $error');
    }
    if (!mounted) return;
    setState(() {
      _restored = true;
      _paired = stored;
      _pairing = stored == null;
    });
    // With nothing paired we still hold a client, pointed at the endpoint this
    // build was given (--dart-define) or at its built-in default. That is what
    // "set up later" falls back to.
    _connectTo(stored ?? AppConfig.defaultTarget);
  }

  void _connectTo(ConnectionTarget target) {
    final previous = _obs;
    _connectionSeq++;
    _active = target;
    _obs = ObsClient(
      uri: target.uri,
      password: target.password,
      onLog: (message) => debugPrint('[obs] $message'),
    );
    unawaited(_obs!.connect());
    if (previous != null) unawaited(previous.dispose());
  }

  Future<void> _onPaired(ConnectionTarget target) async {
    try {
      await _store.save(target);
    } catch (error) {
      // Pairing still works for this session; it just will not be remembered.
      debugPrint('[pairing] could not save the endpoint: $error');
    }
    if (!mounted) return;
    setState(() {
      _paired = target;
      _pairing = false;
      _wizardPending = true;
    });
    _connectTo(target);
  }

  @override
  void dispose() {
    final obs = _obs;
    if (obs != null) unawaited(obs.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Open Flutter',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: _home(),
    );
  }

  Widget _home() {
    if (!_restored) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_pairing) {
      return ConnectScreen(
        // Prefill from a build that was aimed at an OBS on the command line, so
        // that workflow still starts one tap away.
        initialTarget:
            _paired ??
            (AppConfig.fromEnvironment ? AppConfig.defaultTarget : null),
        onConnected: (target) => unawaited(_onPaired(target)),
        onLater: () => setState(() => _pairing = false),
      );
    }

    final obs = _obs;
    if (obs == null) {
      return const Scaffold(
        backgroundColor: AppColors.background,
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final key = ValueKey(_connectionSeq);
    return HomeShell(
      key: key,
      connection: obs,
      endpoint: _active?.label,
      // Pairing earns the whole walkthrough. Coming back to an endpoint
      // paired earlier only earns step 2, and only if the rig is missing
      // — the switcher decides that once OBS has answered. "Set up
      // later" earns nothing: that was someone asking not to be walked
      // through it.
      wizard: switch ((_wizardPending, _paired != null)) {
        (true, _) => WizardMode.pairing,
        (false, true) => WizardMode.ifMissing,
        (false, false) => WizardMode.off,
      },
      onPair: () => setState(() => _pairing = true),
      // START_SCREEN=prompter still opens straight onto the prompter.
      initialIndex: AppConfig.startOnPrompter
          ? HomeShell.prompterPage
          : HomeShell.camerasPage,
    );
  }
}
