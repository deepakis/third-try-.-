import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../obs/auto_setup.dart';
import 'theme.dart';

/// First-run nudge: OBS is connected but the rig isn't built yet.
///
/// Streams the setup steps as they land, so a slow camera enumeration doesn't
/// look like a hang, and reports exactly what it changed.
///
/// Setup here means *rebuild*: a run clears the app's own rig scenes first, so
/// the framing is what you just picked rather than whatever was left over. The
/// screen confirms that before anything is deleted.
///
/// Layout notes, because this banner got this wrong once: a from-scratch run
/// reports a dozen steps, and an unbounded report squeezed the tiles off the
/// screen in a small window (the embedded preview caught it). The height is now
/// capped to leave room for the header, the footer and the tiles, and the whole
/// body scrolls inside that cap — so no report length can overflow it.
class SetupBanner extends StatelessWidget {
  const SetupBanner({
    super.key,
    required this.rigScenes,
    required this.shotLabels,
    required this.running,
    required this.steps,
    required this.report,
    required this.onChooseShots,
    required this.onQuickSetup,
    required this.onReset,
    required this.onDismiss,
    this.stepLabel,
  });

  /// The app's rig scenes that are in OBS right now (so they can be cleared).
  final List<String> rigScenes;

  /// Names of the currently selected shots, e.g. `["Full", "Zoom"]`.
  final List<String> shotLabels;

  final bool running;
  final List<SetupStep> steps;
  final SetupReport? report;

  final VoidCallback onChooseShots;
  final VoidCallback onQuickSetup;
  final VoidCallback onReset;
  final VoidCallback onDismiss;

  /// Where this banner sits in the first-run wizard, e.g. `Step 2 of 3 · Pick
  /// your shots`. Null when no wizard is running.
  ///
  /// The wizard lives *inside* this banner rather than in a second one above it:
  /// two stacked cards pushed the cameras off the page, which is the opposite of
  /// what a switcher is for.
  final String? stepLabel;

  @override
  Widget build(BuildContext context) {
    final failed = report != null && !report!.ok;
    final done = report != null && report!.ok;
    final accent = failed
        ? AppColors.danger
        : (done ? AppColors.success : AppColors.ink);
    final surface = failed
        ? AppColors.dangerSurface
        : (done ? const Color(0xFFF0FDF4) : AppColors.surface);

    final height = MediaQuery.sizeOf(context).height;
    // A short window is one where the guidance has to share the page with the
    // cameras. It gets a fixed, small slice — one headline and the buttons, both
    // of which scroll inside it if they have to — instead of a share of the
    // height, because the header and the footer grow at exactly the widths where
    // this happens. "The cameras are not even showing" was this banner taking
    // the room.
    final compact = height < 720;
    final cap = compact
        ? 112.0
        : math.max(140.0, math.min(300.0, height - 420));
    // Everything tightens in compact mode, so the primary button — the whole
    // point of the card — is fully visible inside that cap instead of being cut
    // in half by it (which is what it looked like on a first pass).
    final verticalPad = compact ? 10.0 : 16.0;
    // On a short window the explanation goes first: the headline and the
    // buttons say what is happening, and the confirmation spells out exactly
    // what a run deletes.
    final showProse = !compact;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      constraints: BoxConstraints(maxHeight: cap),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: verticalPad, left: 18, right: 14),
            child: running
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  )
                : Icon(
                    failed
                        ? Icons.error_outline_rounded
                        : (done
                              ? Icons.check_circle_rounded
                              : Icons.bolt_rounded),
                    size: 22,
                    color: accent,
                  ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(top: verticalPad, bottom: verticalPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (stepLabel != null && !compact) ...[
                    Text(
                      stepLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.1,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    // On a short window the step and the headline share one
                    // line, so the wizard stays visible without costing a line.
                    stepLabel == null || !compact
                        ? _headline(failed: failed, done: done)
                        : '$stepLabel · ${_headline(failed: failed, done: done)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 14 : 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  if (showProse) ...[
                    const SizedBox(height: 4),
                    Text(
                      _body(failed: failed, done: done),
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        fontWeight: FontWeight.w500,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                  SizedBox(height: compact ? 10 : 14),
                  // Wrap, so a narrow window folds the buttons instead of
                  // overflowing them.
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: running ? null : onQuickSetup,
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 15 : 18,
                            vertical: compact ? 10 : 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.auto_fix_high_rounded, size: 18),
                        label: Text(
                          // The shots the operator already has are the main
                          // action; picking new ones is the alternative. It was
                          // the other way round, which asked someone who had
                          // already chosen their shots to choose them again.
                          done ? 'Run again' : _setupLabel,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: running ? null : onChooseShots,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.ink,
                          backgroundColor: Colors.white,
                          side: const BorderSide(color: AppColors.border),
                          padding: EdgeInsets.symmetric(
                            horizontal: compact ? 14 : 16,
                            vertical: compact ? 10 : 14,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'Change shots',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (rigScenes.isNotEmpty)
                        TextButton(
                          onPressed: running ? null : onReset,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.danger,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                          child: const Text(
                            'Reset the rig in OBS',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  // The live step-by-step only where there is room for it; it
                  // is reassurance, not the point of the page.
                  if (steps.isNotEmpty && !compact) ...[
                    const SizedBox(height: 14),
                    for (final step in steps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 5, right: 8),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: step.changed
                                      ? accent
                                      : AppColors.border,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                step.message,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.35,
                                  fontWeight: FontWeight.w600,
                                  color: step.changed
                                      ? AppColors.ink
                                      : AppColors.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: IconButton(
              onPressed: onDismiss,
              tooltip: 'Hide',
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  /// What the primary button does: builds the shots the operator already has.
  String get _setupLabel => shotLabels.isEmpty
      ? 'Set up the rig'
      : 'Set up ${shotLabels.join(" + ")}';

  String _headline({required bool failed, required bool done}) {
    if (failed) return 'Setup stopped early';
    if (done) return 'OBS is configured';
    if (running) return 'Setting up OBS…';
    return 'Your shots are not set up in OBS yet';
  }

  String _body({required bool failed, required bool done}) {
    if (failed) {
      return 'Nothing else was changed. Fix the problem above and run it again.';
    }
    if (done) {
      return 'One OBS scene per shot, pointed at your camera. Tap a tile or '
          'press 1 / 2 to cut.';
    }
    if (running) return 'Talking to OBS on the same connection as the tiles.';
    final clears = rigScenes.isEmpty
        ? 'A run only adds.'
        : 'A run clears the rig scenes it made (${_list(rigScenes)}) first, so '
              'the framing is what you picked.';
    return 'One OBS scene per shot, pointed at your webcam. $clears Never your '
        'own scenes or camera sources.';
  }

  String _list(List<String> names) => names.map((name) => '"$name"').join(', ');
}
