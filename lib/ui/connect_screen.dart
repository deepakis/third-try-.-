import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../obs/connection_target.dart';
import '../obs/obs_client.dart';
import '../obs/obs_models.dart';
import 'theme.dart';
import 'wizard.dart';

/// What to tell the operator when an attempt fails, and what to try next.
class FailureAdvice {
  const FailureAdvice({required this.title, required this.steps});

  final String title;
  final List<String> steps;
}

/// Turns a failure into the fix. One entry per way this actually goes wrong, so
/// the screen never says "connection failed" and leaves the operator there.
///
/// The host and port are woven into the copy because the two most common
/// mistakes are both about *which* address: pointing at `127.0.0.1` when OBS is
/// on another machine, and reading an address off a machine on a different
/// network.
FailureAdvice adviceFor(
  ObsFailure failure, {
  required String host,
  required int port,
}) {
  switch (failure) {
    case ObsFailure.wrongPassword:
      return const FailureAdvice(
        title: 'OBS is there — it rejected the password',
        steps: [
          'In OBS: Tools → WebSocket Server Settings → Show Connect Info, and '
              'copy the password from there.',
          'If you never set one, OBS generates it; the same dialog shows it.',
          'A leading or trailing space is enough to be rejected — it is a '
              'password, not a hostname.',
        ],
      );
    case ObsFailure.refused:
      return FailureAdvice(
        title: 'Something is at $host, but nothing answers on port $port',
        steps: [
          'Is OBS Studio actually running?',
          'In OBS: Tools → WebSocket Server Settings → tick "Enable WebSocket '
              'server". It ships disabled on a fresh install.',
          'If you changed the port there, use it here too.',
        ],
      );
    case ObsFailure.mixedContent:
      return const FailureAdvice(
        title: 'The browser blocked this before it was sent',
        steps: [
          'This page was served over https://, and a secure page is not allowed '
              'to open a plain ws:// socket to OBS.',
          'Serve the app over http:// (localhost is fine), or use the desktop '
              'build, which has no such rule.',
        ],
      );
    case ObsFailure.unreachable:
      return FailureAdvice(
        title: "Couldn't reach $host:$port at all",
        steps: [
          'Use the address OBS itself shows in Show Connect Info — and note that '
              '127.0.0.1 means "the computer running this app", so it only works '
              'when OBS is on that same machine.',
          'Both devices on the same Wi-Fi or network? A phone on mobile data, a '
              'guest network, or a VPN usually cannot see the OBS machine at all.',
          'Allow OBS through the firewall on the machine running it (port $port), '
              'and check the network is not marked "public" on Windows.',
          'A router that isolates wireless clients will also block this.',
        ],
      );
    case ObsFailure.closed:
      return const FailureAdvice(
        title: 'OBS closed the connection',
        steps: [
          'OBS dropped the socket after the handshake. Check its WebSocket '
              'server settings, then try again.',
        ],
      );
    case ObsFailure.none:
      return const FailureAdvice(
        title: 'Not connected',
        steps: ['Check that OBS is running and its WebSocket server is enabled.'],
      );
  }
}

/// The first screen of the app: point it at an OBS.
///
/// OBS prints everything needed as one line (Tools → WebSocket Server Settings →
/// Show Connect Info, beside a QR code), so that line is the primary input. The
/// three fields stay editable underneath, for when someone is reading the
/// address off a different machine.
///
/// Pairing is step 1 of a three-step first run: connecting hands over to the
/// switcher, which picks the shots and then confirms the operator is live. It
/// can also be skipped — the switcher offers Connect while it has no socket —
/// which is the "set it up later" half of the flow.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    this.initialTarget,
    this.probe,
    this.onConnected,
    this.onLater,
  });

  /// Prefilled from what was paired last time, or from the build's
  /// `--dart-define` values.
  final ConnectionTarget? initialTarget;

  /// Runs the attempt. Injected in tests, which must not open a socket.
  final Future<ObsStatus> Function(ConnectionTarget target)? probe;

  /// The endpoint that authenticated, for the caller to remember and use.
  final void Function(ConnectionTarget target)? onConnected;

  /// "Set up later": carry on without pairing.
  final VoidCallback? onLater;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _password;

  /// The password field is tucked away: most setups only need the address.
  /// Opened by the toggle, or straight away when a saved endpoint has one.
  late bool _showPassword;
  bool _revealPassword = false;
  bool _connecting = false;
  ObsStatus? _result;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTarget;
    _showPassword = (initial?.password ?? '').isNotEmpty;
    _host = TextEditingController(text: initial?.host ?? '');
    _port = TextEditingController(
      text: '${initial?.port ?? ConnectionTarget.defaultPort}',
    );
    _password = TextEditingController(text: initial?.password ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _password.dispose();
    super.dispose();
  }

  /// The endpoint the fields currently describe, or null when they do not
  /// describe one yet.
  ConnectionTarget? get _typed {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return ConnectionTarget(host: host, port: port, password: _password.text);
  }

  /// The link the app builds from the address. The operator never types or
  /// pastes it; it is shown only so the address is visibly understood.
  String? get _link {
    final target = _typed;
    if (target == null) return null;
    return 'obsws://${target.host}:${target.port}';
  }

  /// True when the page itself is the reason a connection cannot work: a secure
  /// page is not allowed to open a plain socket to OBS.
  bool get _onSecurePage => kIsWeb && Uri.base.scheme == 'https';

  Future<void> _connect() async {
    final target = _typed;
    if (target == null || _connecting) return;
    setState(() {
      _connecting = true;
      _result = null;
    });
    final status = await _runProbe(target);
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _result = status;
    });
    if (status.isConnected) widget.onConnected?.call(target);
  }

  Future<ObsStatus> _runProbe(ConnectionTarget target) {
    final probe = widget.probe;
    if (probe != null) return probe(target);
    return _probeOnce(target);
  }

  /// A throwaway client, so a rejected address leaves nothing retrying in the
  /// background. The app builds its own client once an endpoint is accepted.
  static Future<ObsStatus> _probeOnce(ConnectionTarget target) async {
    final client = ObsClient(
      uri: target.uri,
      password: target.password,
      autoReconnect: false,
    );
    try {
      return await client.connectAndWait();
    } finally {
      await client.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _result;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const WizardSteps(current: 1),
                  const SizedBox(height: 22),
                  const Text(
                    'Connect to OBS',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Type the IP address and port OBS is using. The app builds '
                    'the link itself.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.45,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (_onSecurePage) const _SecurePageWarning(),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: _Field(
                          label: 'IP address',
                          controller: _host,
                          hint: '192.168.1.20',
                          keyboardType: TextInputType.url,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => unawaited(_connect()),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: _Field(
                          label: 'Port',
                          controller: _port,
                          hint: ConnectionTarget.defaultPort.toString(),
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => unawaited(_connect()),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _LinkLine(link: _link),
                  const SizedBox(height: 4),
                  if (!_showPassword)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _showPassword = true),
                        icon: const Icon(Icons.key_rounded, size: 16),
                        label: const Text(
                          'OBS has a password',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 12),
                    _Field(
                      label: 'Password',
                      controller: _password,
                      hint: 'the one from Show Connect Info',
                      obscure: !_revealPassword,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => unawaited(_connect()),
                      trailing: IconButton(
                        onPressed: () =>
                            setState(() => _revealPassword = !_revealPassword),
                        tooltip: _revealPassword
                            ? 'Hide the password'
                            : 'Show the password',
                        icon: Icon(
                          _revealPassword
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _connecting || _typed == null
                        ? null
                        : () => unawaited(_connect()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.ink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _connecting
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text(
                                'Connecting…',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ],
                          )
                        : const Text(
                            'Connect',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  if (widget.onLater != null) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _connecting ? null : widget.onLater,
                      child: const Text(
                        'Set up later',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                    const Text(
                      'The switcher shows which OBS you are connected to — tap '
                      'that address to pair a different one.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                  if (status != null && status.isConnected)
                    _ConnectedCard(status: status),
                  if (status != null && status.failed)
                    _AdviceCard(
                      advice: adviceFor(
                        status.failure,
                        host: _typed?.host ?? _host.text.trim(),
                        port: _typed?.port ?? ConnectionTarget.defaultPort,
                      ),
                      detail: status.detail,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SecurePageWarning extends StatelessWidget {
  const _SecurePageWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.warnSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_rounded, size: 18, color: AppColors.warn),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'This page is served over https://, so the browser will refuse to '
              'open a ws:// socket to OBS. Run the app on http:// instead.',
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: AppColors.warn,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.trailing,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(label),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: AppColors.muted, fontSize: 13.5),
            filled: true,
            fillColor: AppColors.surface,
            suffixIcon: trailing,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.border),
            ),
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
      color: AppColors.muted,
    ),
  );
}

/// The link the fields add up to, shown under them so the address is visibly
/// understood (and a mistyped port is visibly wrong) before connecting.
class _LinkLine extends StatelessWidget {
  const _LinkLine({required this.link});

  final String? link;

  @override
  Widget build(BuildContext context) {
    return Text(
      link == null
          ? 'Enter an IP address and a port to continue.'
          : 'Link: $link',
      style: const TextStyle(fontSize: 12, color: AppColors.muted),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.status});

  final ObsStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: AppColors.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Connected to ${status.detail}',
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdviceCard extends StatelessWidget {
  const _AdviceCard({required this.advice, required this.detail});

  final FailureAdvice advice;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.dangerSurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            advice.title,
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              color: AppColors.danger,
            ),
          ),
          const SizedBox(height: 10),
          for (final step in advice.steps) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.arrow_right_rounded,
                    size: 16,
                    color: AppColors.danger,
                  ),
                ),
                Expanded(
                  child: Text(
                    step,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.42,
                      color: AppColors.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          if (detail.isNotEmpty)
            Text(
              detail,
              style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.muted,
                fontFamily: 'monospace',
              ),
            ),
        ],
      ),
    );
  }
}
