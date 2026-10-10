import 'dart:async';

import 'package:flutter/material.dart';

import '../obs/obs_client.dart';
import '../obs/obs_models.dart';
import 'theme.dart';

/// The third page: where OBS is, whether the app is talking to it, and a short
/// reference for the keys and cue tags, so nobody has to remember them.
class SetupPage extends StatelessWidget {
  const SetupPage({
    super.key,
    required this.connection,
    this.endpoint,
    this.onPair,
  });

  final ObsConnection connection;

  /// The OBS this session is pointed at, as `host:port`.
  final String? endpoint;

  /// Opens the pairing screen. Null when there is nowhere to go.
  final VoidCallback? onPair;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _PageHeader(
                    title: 'Setup',
                    subtitle:
                        'The OBS connection, and the keys and cues to know.',
                  ),
                  const SizedBox(height: 22),
                  _ConnectionCard(
                    connection: connection,
                    endpoint: endpoint,
                    onPair: onPair,
                  ),
                  const SizedBox(height: 16),
                  const _Card(
                    title: 'Keys',
                    child: Column(
                      children: [
                        _KeyRow(
                          keys: ['1', '2'],
                          text: 'Cut to a camera (the order you picked them)',
                        ),
                        _KeyRow(keys: ['T'], text: 'Open the teleprompter'),
                        _KeyRow(keys: ['R'], text: 'Reconnect to OBS'),
                        _KeyRow(
                          keys: ['space'],
                          text: 'Prompter: pause or resume',
                        ),
                        _KeyRow(keys: ['N'], text: 'Prompter: jump to the next cue'),
                        _KeyRow(keys: ['↑', '↓'], text: 'Prompter: nudge the script'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const _Card(
                    title: 'Cue tags',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TagLine(
                          tag: '[CAM 1]',
                          text: 'cut to the first shot',
                          cue: true,
                        ),
                        _TagLine(
                          tag: '[CAM 2]',
                          text: 'cut to the second shot',
                          cue: true,
                        ),
                        _TagLine(
                          tag: '[LAYOUT: FULL]',
                          text: 'full-frame camera',
                          cue: true,
                        ),
                        _TagLine(
                          tag: '[LAYOUT: PIP]',
                          text: 'screen with the camera in the corner',
                          cue: true,
                        ),
                        _TagLine(
                          tag: '[pause]',
                          text: 'any other bracket is a note for you',
                          cue: false,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'A cue fires when its line crosses the red reading line. '
                          'Scroll back above it and it fires again.',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
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

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.8,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 14, color: AppColors.muted),
        ),
      ],
    );
  }
}

/// A rounded panel with a small heading, shared by the cards on this page.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// Where OBS is and whether the app is talking to it right now.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.connection,
    required this.endpoint,
    required this.onPair,
  });

  final ObsConnection connection;
  final String? endpoint;
  final VoidCallback? onPair;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ObsStatus>(
      initialData: connection.status,
      stream: connection.statusStream,
      builder: (context, snapshot) {
        final status = snapshot.data ?? connection.status;
        final connected = status.isConnected;
        final busy = status.state == ObsConnectionState.connecting;
        final dot = connected
            ? AppColors.success
            : (busy ? AppColors.warn : AppColors.danger);
        final headline = connected
            ? 'Connected'
            : (busy ? 'Connecting…' : 'Not connected');

        return _Card(
          title: 'OBS connection',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    headline,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                endpoint == null
                    ? 'No OBS paired yet.'
                    : 'obsws://$endpoint',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: AppColors.muted,
                ),
              ),
              if (!connected && status.detail.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  status.detail,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.danger),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => unawaited(connection.connect()),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.ink,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Reconnect'),
                  ),
                  if (onPair != null)
                    OutlinedButton.icon(
                      onPressed: onPair,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ink,
                        side: const BorderSide(color: AppColors.border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.cable_rounded, size: 18),
                      label: const Text('Change OBS'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.keys, required this.text});

  final List<String> keys;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 120,
            child: Wrap(
              spacing: 4,
              children: [
                for (final key in keys)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      key,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13.5, color: AppColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagLine extends StatelessWidget {
  const _TagLine({required this.tag, required this.text, required this.cue});

  final String tag;
  final String text;
  final bool cue;

  @override
  Widget build(BuildContext context) {
    final color = cue ? AppColors.cue : AppColors.stageNote;
    final ink = cue ? AppColors.cue : const Color(0xFF0369A1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              tag,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: ink,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13.5, color: AppColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}
