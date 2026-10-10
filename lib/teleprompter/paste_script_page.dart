import 'package:flutter/material.dart';

import '../obs/obs_models.dart';
import '../ui/theme.dart';
import 'sample_script.dart';
import 'script_model.dart';

/// Paste a script, cues and all, and load it into the teleprompter.
///
/// A cue is a bracketed tag on the line where the cut should happen:
/// `[CAM 1]`, `[CAM 2]`, `[LAYOUT: FULL]`, `[LAYOUT: PIP]`. Any other bracket
/// (`[pause]`, `[B-roll]`) is an instruction for the presenter: it stays in the
/// script, in blue, and never touches OBS.
///
/// The summary under the text is the check before going live: it lists every
/// cue the script will fire, so a `[CAM 9]` with no camera behind it is seen
/// here rather than discovered on air.
class PasteScriptPage extends StatefulWidget {
  const PasteScriptPage({
    super.key,
    required this.slots,
    this.initialText = '',
  });

  /// The shots on screen, which decide what each camera cue switches to.
  final List<CameraSlot> slots;

  /// Pre-filled with the script already loaded, so an edit starts from it.
  final String initialText;

  /// Resolves to the pasted text when loaded, or null when backed out of.
  static Future<String?> open(
    BuildContext context, {
    required List<CameraSlot> slots,
    String initialText = '',
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) =>
            PasteScriptPage(slots: slots, initialText: initialText),
      ),
    );
  }

  @override
  State<PasteScriptPage> createState() => _PasteScriptPageState();
}

class _PasteScriptPageState extends State<PasteScriptPage> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _controller.text;
    final hasText = text.trim().isNotEmpty;
    final doc = parseScript(text, widget.slots);
    final cues = [for (final cue in doc.cues) if (cue.hasAction) cue];
    final directions = [for (final cue in doc.cues) if (!cue.hasAction) cue];

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Paste a script',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.4),
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => _controller.text = demoScript),
            child: const Text(
              'Use demo',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (hasText)
            IconButton(
              onPressed: () => setState(_controller.clear),
              tooltip: 'Clear',
              icon: const Icon(Icons.backspace_outlined, size: 20),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _TagGuide(),
              const SizedBox(height: 14),
              Expanded(
                child: TextField(
                  controller: _controller,
                  onChanged: (_) => setState(() {}),
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontSize: 16, height: 1.5),
                  decoration: _fieldDecoration(
                    hint:
                        'Paste your script here.\n\nWelcome back to the channel.\n'
                        '[CAM 1]\nToday I am wiring up two cameras…\n'
                        '[LAYOUT: PIP]\nHere is the screen.',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _Summary(
                hasText: hasText,
                cues: cues,
                directions: directions,
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: hasText
                    ? () => Navigator.of(context).pop(text)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.ink,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.border,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Load into the teleprompter',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration({required String hint}) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: AppColors.muted,
        fontSize: 15,
        height: 1.5,
      ),
      contentPadding: const EdgeInsets.all(16),
      filled: true,
      fillColor: AppColors.surface,
      border: border(AppColors.border),
      enabledBorder: border(AppColors.border),
      focusedBorder: border(AppColors.ink),
    );
  }
}

/// What the tags mean, in the same words the prompter uses.
class _TagGuide extends StatelessWidget {
  const _TagGuide();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Put a cue on its own line, where the cut should happen.',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
          ),
          SizedBox(height: 10),
          _GuideRow(tag: '[CAM 1]', meaning: 'cut to the first shot'),
          _GuideRow(tag: '[CAM 2]', meaning: 'cut to the second shot'),
          _GuideRow(tag: '[LAYOUT: FULL]', meaning: 'full-frame camera'),
          _GuideRow(tag: '[LAYOUT: PIP]', meaning: 'screen with the camera in the corner'),
          SizedBox(height: 6),
          Text(
            'Any other [bracket] is a note for you, such as [pause]. It shows in '
            'blue and never changes the scene.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({required this.tag, required this.meaning});

  final String tag;
  final String meaning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              tag,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: AppColors.cue,
              ),
            ),
          ),
          Expanded(
            child: Text(
              meaning,
              style: const TextStyle(fontSize: 12.5, color: AppColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Counts and lists what the script will do, before it is loaded.
class _Summary extends StatelessWidget {
  const _Summary({
    required this.hasText,
    required this.cues,
    required this.directions,
  });

  final bool hasText;
  final List<ScriptCue> cues;
  final List<ScriptCue> directions;

  @override
  Widget build(BuildContext context) {
    if (!hasText) {
      return const Text(
        'Nothing pasted yet.',
        style: TextStyle(fontSize: 13, color: AppColors.muted),
      );
    }

    final cutCount = cues.length == 1 ? '1 cut' : '${cues.length} cuts';
    final noteCount = directions.length == 1
        ? '1 note'
        : '${directions.length} notes';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _CountPill(
              label: cutCount,
              color: AppColors.cue,
              icon: Icons.cut_rounded,
            ),
            const SizedBox(width: 8),
            _CountPill(
              label: noteCount,
              color: AppColors.stageNote,
              icon: Icons.sticky_note_2_outlined,
            ),
          ],
        ),
        if (cues.isNotEmpty || directions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final cue in cues)
                _TagChip(
                  text: '[${cue.tag}] → ${cue.label}',
                  color: AppColors.cue,
                ),
              for (final cue in directions)
                _TagChip(text: '[${cue.tag}]', color: AppColors.stageNote),
            ],
          ),
        ],
        if (cues.isEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            'No cut in this script yet. It will still read, but nothing will '
            'switch in OBS.',
            style: TextStyle(fontSize: 12.5, color: AppColors.warn),
          ),
        ],
      ],
    );
  }
}

class _CountPill extends StatelessWidget {
  const _CountPill({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
