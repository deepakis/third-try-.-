import '../obs/obs_models.dart';

/// A cue tag found in the script, e.g. `[CAM 2: ZOOM]` or `[LAYOUT: PIP]`.
class ScriptCue {
  const ScriptCue({
    required this.lineIndex,
    required this.tag,
    required this.label,
    this.sceneName,
  });

  /// Zero-based index of the script line the tag sits on.
  final int lineIndex;

  /// The raw tag without brackets, e.g. `CAM 2: ZOOM`.
  final String tag;

  /// Short human summary for the cue chips, e.g. `Camera B`.
  final String label;

  /// OBS scene to switch to when this cue crosses the reading line, or null if
  /// the tag doesn't map to anything we know how to do.
  final String? sceneName;

  bool get hasAction => sceneName != null;

  @override
  String toString() => 'ScriptCue($tag → ${sceneName ?? 'no action'})';
}

class ScriptLine {
  const ScriptLine({required this.index, required this.text, required this.cues});

  final int index;
  final String text;
  final List<ScriptCue> cues;

  bool get hasCue => cues.isNotEmpty;
}

class ScriptDocument {
  const ScriptDocument({
    required this.title,
    required this.lines,
    required this.cues,
  });

  final String title;
  final List<ScriptLine> lines;

  /// Every cue in the script, in document order.
  final List<ScriptCue> cues;
}

/// Matches `[ ... ]` cue tags, keeping the brackets out of the capture group.
final RegExp cueTagPattern = RegExp(r'\[([^\[\]]+)\]');

final RegExp _camPattern = RegExp(r'^(?:CAM|CAMERA)\s*(\d+)');
final RegExp _layoutPattern = RegExp(r'^LAYOUT\s*:?\s*([A-Z]+)');

/// Turns one tag body into a scene name using the operator's slot list.
///
///   * `CAM 1` / `CAMERA 1` → the first slot, `CAM 2` → the second, …
///   * `LAYOUT: FULL` → the full-frame shot (first slot)
///   * `LAYOUT: PIP` / `SCREEN` / `SHARE` → the screen-with-PiP shot (second slot)
///
/// Anything else returns null so the UI can show the tag as unrecognised rather
/// than silently doing nothing.
String? resolveCueScene(String tag, List<CameraSlot> slots) {
  final normalised = tag.toUpperCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  final camera = _camPattern.firstMatch(normalised);
  if (camera != null) {
    final number = int.tryParse(camera.group(1) ?? '');
    if (number == null || number < 1 || number > slots.length) return null;
    return slots[number - 1].sceneName;
  }

  final layout = _layoutPattern.firstMatch(normalised);
  if (layout != null) {
    switch (layout.group(1)) {
      case 'FULL':
      case 'CAMERA':
      case 'TALK':
      case 'TALKING':
        return slots.isEmpty ? null : slots.first.sceneName;
      case 'PIP':
      case 'SCREEN':
      case 'SHARE':
        return slots.length > 1 ? slots[1].sceneName : null;
    }
  }
  return null;
}

String _cueLabel(String tag, String? sceneName, List<CameraSlot> slots) {
  if (sceneName == null) return 'unrecognised cue';
  for (final slot in slots) {
    if (slot.sceneName == sceneName) return slot.label;
  }
  return sceneName;
}

/// Splits a script into lines and lifts the cue tags out of them.
///
/// The tag text stays in the line (the operator reads past the brackets) —
/// the returned [ScriptLine.cues] just says what should happen at that point.
ScriptDocument parseScript(
  String script,
  List<CameraSlot> slots, {
  String title = 'Untitled script',
}) {
  final rawLines = script.split('\n');
  final lines = <ScriptLine>[];
  final cues = <ScriptCue>[];

  for (var i = 0; i < rawLines.length; i++) {
    final text = rawLines[i];
    final lineCues = <ScriptCue>[];
    for (final match in cueTagPattern.allMatches(text)) {
      final tag = match.group(1)?.trim() ?? '';
      if (tag.isEmpty) continue;
      final sceneName = resolveCueScene(tag, slots);
      final cue = ScriptCue(
        lineIndex: i,
        tag: tag,
        label: _cueLabel(tag, sceneName, slots),
        sceneName: sceneName,
      );
      lineCues.add(cue);
      cues.add(cue);
    }
    lines.add(ScriptLine(index: i, text: text, cues: lineCues));
  }

  return ScriptDocument(title: title, lines: lines, cues: cues);
}
