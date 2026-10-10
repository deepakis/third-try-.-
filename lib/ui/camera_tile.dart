import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../obs/obs_models.dart';
import 'layout_diagram.dart';
import 'theme.dart';

/// One giant button on the switcher: a live preview of the shot, its name, what
/// the shot is, and which OBS scene it drives.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.slot,
    required this.isLive,
    required this.isBusy,
    required this.enabled,
    required this.onTap,
    this.preview,
    this.error,
    this.resolvedScene,
    this.placeholderHint,
    this.shortcut,
  });

  final CameraSlot slot;
  final bool isLive;
  final bool isBusy;
  final bool enabled;
  final VoidCallback onTap;

  /// Latest JPEG frame of the scene, or null when there is nothing to show.
  final Uint8List? preview;
  final String? error;

  /// OBS scene this tile currently drives, if one could be resolved.
  final String? resolvedScene;
  final String? placeholderHint;

  /// Keyboard shortcut shown on the tile, e.g. "1".
  final String? shortcut;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final live = widget.isLive;
    final interactive = widget.enabled;
    final foreground = live ? Colors.white : AppColors.ink;
    final borderColor = live
        ? AppColors.ink
        : widget.error != null
        ? AppColors.danger
        : AppColors.border;
    final background = live
        ? AppColors.ink
        : (_hovered && interactive ? AppColors.surface : Colors.white);

    return MouseRegion(
      cursor: interactive ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: borderColor, width: live ? 3 : 1.5),
          boxShadow: [
            BoxShadow(
              color: live
                  ? AppColors.ink.withValues(alpha: 0.16)
                  : Colors.black.withValues(alpha: 0.04),
              blurRadius: live ? 28 : 18,
              offset: Offset(0, live ? 12 : 6),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: interactive ? widget.onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(20),
              // On a short window the tile drops its secondary line and shrinks
              // the label, so the preview keeps a usable height instead of
              // being squeezed to a sliver.
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Scale the label with the tile and drop the secondary line
                  // only when there is genuinely no room for it.
                  final compact = constraints.maxHeight < 300;
                  final labelSize = (constraints.maxHeight * 0.17).clamp(
                    30.0,
                    54.0,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _PreviewArea(
                          preview: widget.preview,
                          live: live,
                          foreground: foreground,
                          layout: widget.slot.layout,
                          hint: widget.placeholderHint,
                          pill: _pillSpec(live: live, compact: compact),
                        ),
                      ),
                      SizedBox(height: compact ? 12 : 18),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.slot.label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: labelSize,
                            height: 1.0,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.6,
                            color: foreground,
                          ),
                        ),
                      ),
                      if (!compact) ...[
                        const SizedBox(height: 8),
                        Text(
                          widget.slot.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: foreground.withValues(
                              alpha: live ? 0.75 : 0.55,
                            ),
                          ),
                        ),
                      ],
                      SizedBox(height: compact ? 8 : 10),
                      _StatusLine(
                        live: live,
                        text: _statusText(),
                        tone: _statusTone(),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _statusText() {
    if (!widget.enabled) return 'waiting for OBS…';
    final error = widget.error;
    if (error != null) return error;
    if (widget.isBusy) return 'switching…';
    final scene = widget.resolvedScene;
    if (scene == null) return 'no "${widget.slot.sceneName}" scene yet';
    return 'OBS scene · $scene';
  }

  Color _statusTone() {
    if (widget.error != null) return AppColors.danger;
    if (!widget.enabled) return AppColors.muted;
    if (widget.resolvedScene == null) return AppColors.warn;
    return AppColors.success;
  }

  _PillSpec? _pillSpec({required bool live, required bool compact}) {
    if (live) {
      return const _PillSpec(text: 'LIVE', background: Colors.white, foreground: AppColors.ink, dot: AppColors.live);
    }
    if (widget.error != null) {
      return const _PillSpec(text: 'ERROR', background: AppColors.dangerSurface, foreground: AppColors.danger);
    }
    if (widget.isBusy) {
      return const _PillSpec(text: 'SWITCHING', background: AppColors.warnSurface, foreground: AppColors.warn);
    }
    if (!widget.enabled) {
      return const _PillSpec(text: 'OFFLINE', background: AppColors.surface, foreground: AppColors.muted);
    }
    final shortcut = widget.shortcut;
    return _PillSpec(
      text: shortcut == null
          ? 'CUT TO THIS'
          : (compact ? 'PRESS $shortcut' : '$shortcut  ·  CUT TO THIS'),
      background: Colors.white.withValues(alpha: 0.92),
      foreground: AppColors.ink,
      border: AppColors.border,
    );
  }
}

class _PillSpec {
  const _PillSpec({
    required this.text,
    required this.background,
    required this.foreground,
    this.dot,
    this.border,
  });

  final String text;
  final Color background;
  final Color foreground;
  final Color? dot;
  final Color? border;
}

class _PreviewArea extends StatelessWidget {
  const _PreviewArea({
    required this.preview,
    required this.live,
    required this.foreground,
    required this.layout,
    required this.pill,
    this.hint,
  });

  final Uint8List? preview;
  final bool live;
  final Color foreground;
  final CameraLayout layout;
  final String? hint;
  final _PillSpec? pill;

  Widget _placeholder({required Color fg}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fg.withValues(alpha: live ? 0.08 : 0.035),
      ),
      child: _PlaceholderArt(layout: layout, color: fg, hint: hint),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (preview != null)
            Image.memory(
              preview!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              // A frame OBS hands us that the renderer can't decode should not
              // blow a hole in the tile — fall back to the wireframe.
              errorBuilder: (context, error, stack) => _placeholder(fg: foreground),
            )
          else
            _placeholder(fg: foreground),
          if (pill != null)
            Positioned(
              top: 12,
              left: 12,
              child: _Pill(spec: pill!),
            ),
        ],
      ),
    );
  }
}

/// Wireframe + explanation shown while a scene has no picture to show.
///
/// Sizes the 16:9 diagram to whatever room the tile actually gives it, so the
/// caption never gets pushed out of view on a short tile.
class _PlaceholderArt extends StatelessWidget {
  const _PlaceholderArt({
    required this.layout,
    required this.color,
    this.hint,
  });

  final CameraLayout layout;
  final Color color;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        if (availableHeight < 96 || availableWidth < 90) {
          return const SizedBox.shrink();
        }

        // Budget for the hint first (it can wrap to two lines), then give the
        // rest of the room to the wireframe. Never force a minimum size: better
        // a small diagram than a clipped one.
        final hintHeight = hint == null ? 0.0 : 56.0;
        final diagramRoom = math.max(30.0, availableHeight - hintHeight - 10);
        final width = math.min(availableWidth * 0.66, diagramRoom * 16 / 9);
        final height = width * 9 / 16;

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: width,
                height: height,
                child: LayoutDiagram(layout: layout, color: color),
              ),
              if (hint != null) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: availableWidth * 0.94),
                  child: Text(
                    hint!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: color.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.spec});

  final _PillSpec spec;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: spec.background,
        borderRadius: BorderRadius.circular(999),
        border: spec.border == null ? null : Border.all(color: spec.border!),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spec.dot != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: spec.dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
          ],
          Text(
            spec.text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.9,
              color: spec.foreground,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.live, required this.text, required this.tone});

  final bool live;
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: live ? AppColors.success : tone,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: live
                  ? Colors.white.withValues(alpha: 0.72)
                  : tone.withValues(alpha: 0.95),
            ),
          ),
        ),
      ],
    );
  }
}
