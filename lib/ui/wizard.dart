import 'package:flutter/material.dart';

import 'theme.dart';

/// The three things a first run does, shown as a strip so the operator can see
/// which one they are in.
///
/// Deliberately shared by the pairing screen (step 1) and the switcher (steps 2
/// and 3): the wizard is one flow across two screens, and the strip is the only
/// thing that says so. It used to be a private decoration on the pairing screen
/// alone, which promised two steps that nothing carried out.
class WizardSteps extends StatelessWidget {
  const WizardSteps({super.key, required this.current});

  /// The 1-based step the operator is on. Everything before it reads as done.
  final int current;

  static const List<String> labels = [
    'Connect to OBS',
    'Pick your shots',
    'Go live',
  ];

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < labels.length; i++)
          _Step(
            number: i + 1,
            label: labels[i],
            done: i + 1 < current,
            active: i + 1 == current,
          ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.label,
    required this.done,
    required this.active,
  });

  final int number;
  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final filled = done || active;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: filled ? AppColors.ink : AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: filled ? AppColors.ink : AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (done) ...[
            const Icon(Icons.check_rounded, size: 13, color: Colors.white),
            const SizedBox(width: 5),
          ],
          Text(
            '$number · $label',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: filled ? Colors.white : AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of guidance for the step of the wizard the switcher is on.
///
/// Slim on purpose: the setup banner underneath carries the actions (and the
/// progress of a slow rebuild), so this only has to say which step is running
/// and what the operator should do next. Step 3 is the last thing the wizard
/// says, so it is the one that carries a button.
///
/// This one folds the steps into a single line rather than reusing
/// [WizardSteps]. Measured, not guessed: at 428px — the embedded preview's width
/// — the three chips wrapped onto three rows and made this banner **243px**
/// tall, which pushed the footer off the bottom of the window. Same steps, same
/// words, one line, so the switcher's height budget can be honoured.
class WizardBanner extends StatelessWidget {
  const WizardBanner({
    super.key,
    required this.step,
    required this.message,
    this.onDone,
  });

  /// 2 or 3 — the step this banner is showing.
  final int step;

  /// The one line of "what now".
  final String message;

  /// Ends the wizard. Only step 3 offers it.
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: const BoxDecoration(
                  color: AppColors.ink,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _stepLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  // Two lines at most: a banner whose height depends on the
                  // message is how the two-banner layout overflowed the window.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
              ),
              if (onDone != null) ...[
                const SizedBox(width: 10),
                TextButton(
                  onPressed: onDone,
                  child: const Text(
                    'Done',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// `Step 2 of 3 · Pick your shots` — the strip, folded into one line.
  String get _stepLine =>
      'Step $step of ${WizardSteps.labels.length} · ${WizardSteps.labels[step - 1]}';
}
