import 'package:flutter/material.dart';

import '../obs/layouts.dart';
import 'layout_diagram.dart';
import 'theme.dart';

/// Lets the operator choose which shots the rig has.
///
/// Tap order is hotkey order: the first shot picked becomes key 1. That is the
/// one thing that is awkward to change later, so each card shows the key it will
/// get.
class RigPickerDialog extends StatefulWidget {
  const RigPickerDialog({super.key, this.initialIds = const ['full', 'zoom']});

  /// Layout ids already in the rig, in hotkey order.
  final List<String> initialIds;

  /// Returns the picked layout ids in hotkey order, or null if cancelled.
  static Future<List<String>?> show(
    BuildContext context, {
    List<String> initialIds = const ['full', 'zoom'],
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => RigPickerDialog(initialIds: initialIds),
    );
  }

  @override
  State<RigPickerDialog> createState() => _RigPickerDialogState();
}

class _RigPickerDialogState extends State<RigPickerDialog> {
  late final List<String> _picked = [
    for (final id in widget.initialIds)
      if (layoutOptionById(id) != null) id,
  ];

  void _toggle(String id) {
    setState(() {
      if (_picked.contains(id)) {
        _picked.remove(id);
      } else if (_picked.length < maxRigSize) {
        _picked.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final full = _picked.length >= maxRigSize;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pick your shots',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.7,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'The app builds one OBS scene per shot. Pick up to $maxRigSize — '
                'the order you tap them is the order of the keys.',
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted.withValues(alpha: 0.95),
                ),
              ),
              const SizedBox(height: 18),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final option in layoutOptions)
                        _ShotCard(
                          key: ValueKey('shot-${option.id}'),
                          option: option,
                          keyNumber: _picked.indexOf(option.id) + 1,
                          selected: _picked.contains(option.id),
                          enabled: !full || _picked.contains(option.id),
                          onTap: () => _toggle(option.id),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  // Expanded, not a Spacer: the summary is the one piece of
                  // variable-width text here, so it is the one that gives way
                  // on a narrow dialog.
                  Expanded(
                    child: Text(
                      _picked.isEmpty
                          ? 'Pick at least one shot'
                          : '${_picked.length} of $maxRigSize selected · keys '
                                '${[for (var i = 0; i < _picked.length; i++) i + 1].join(' / ')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _picked.isEmpty
                        ? null
                        : () => Navigator.of(context).pop(_picked),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.ink,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 15,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Set up OBS',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShotCard extends StatelessWidget {
  const _ShotCard({
    super.key,
    required this.option,
    required this.keyNumber,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final LayoutOption option;

  /// 1-based hotkey this shot would get, or 0 when not picked.
  final int keyNumber;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? AppColors.ink : AppColors.muted;
    return SizedBox(
      width: 190,
      child: Material(
        color: selected ? Colors.white : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? AppColors.ink : AppColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (selected)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.ink,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'KEY $keyNumber',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.7,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 4),
                    const Spacer(),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: selected
                          ? AppColors.success
                          : AppColors.border,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 74,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: LayoutDiagram(
                        layout: option.layout,
                        color: enabled ? AppColors.ink : AppColors.muted,
                        cornerRadius: 10,
                        strokeWidth: 1.6,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  option.label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                    color: enabled ? AppColors.ink : AppColors.muted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  option.description,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  option.sceneName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                    color: ink.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
