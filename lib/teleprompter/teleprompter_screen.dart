import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../obs/obs_client.dart';
import '../obs/obs_models.dart';
import '../ui/theme.dart';
import 'sample_script.dart';
import 'script_model.dart';

/// The hook: read the script hands-free while the script itself cuts the video.
///
/// The script scrolls under a fixed red reading line. When a line carrying a
/// cue tag (`[CAM 2: ZOOM]`, `[LAYOUT: PIP]`) crosses that line, the matching
/// OBS scene change fires.
class TeleprompterScreen extends StatefulWidget {
  const TeleprompterScreen({
    super.key,
    required this.connection,
    this.slots = AppConfig.cameras,
    this.script = demoScript,
    this.title = 'Two-camera rig · demo',
    this.initialSpeed = 46,
    this.initialFontSize = 30,
  });

  final ObsConnection connection;
  final List<CameraSlot> slots;
  final String script;
  final String title;

  /// Scroll speed in logical pixels per second.
  final double initialSpeed;
  final double initialFontSize;

  @override
  State<TeleprompterScreen> createState() => _TeleprompterScreenState();
}

class _TeleprompterScreenState extends State<TeleprompterScreen>
    with SingleTickerProviderStateMixin {
  static const EdgeInsets _scriptPadding = EdgeInsets.fromLTRB(32, 140, 32, 200);

  late final ScriptDocument _doc;
  late final Ticker _ticker;
  final ScrollController _scroll = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();
  final Map<int, GlobalKey> _lineKeys = {};
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  StreamSubscription<ObsStatus>? _statusSubscription;
  Timer? _resumeTimer;

  /// Line indices whose cue has already crossed the reading line. Cleared again
  /// when a line scrolls back above it, so a re-read re-fires the cut.
  final Set<int> _firedLines = {};

  Duration _lastElapsed = Duration.zero;
  late double _speed = widget.initialSpeed;
  late double _fontSize = widget.initialFontSize;
  bool _playing = true;
  bool _dragging = false;
  ScriptCue? _activeCue;
  ScriptCue? _nextCue;
  String _log = 'scrolling — cues fire at the red line';
  String? _programScene;

  @override
  void initState() {
    super.initState();
    _doc = parseScript(widget.script, widget.slots, title: widget.title);
    for (final line in _doc.lines) {
      _lineKeys[line.index] = GlobalKey();
    }
    _statusSubscription = widget.connection.statusStream.listen((status) {
      if (!mounted) return;
      setState(() => _log = status.label);
      if (status.isConnected) unawaited(_syncProgramScene());
    });
    _eventSubscription = widget.connection.eventStream.listen((event) {
      if (event['eventType'] != 'CurrentProgramSceneChanged') return;
      final data = event['eventData'] as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() => _programScene = data['sceneName'] as String?);
    });
    _scroll.addListener(_evaluateCues);
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _evaluateCues();
      // Opened while already connected: the status listener won't fire again,
      // so pick up the live program scene here.
      if (widget.connection.status.isConnected) unawaited(_syncProgramScene());
    });
  }

  /// OBS only pushes scene changes as events, so the header needs one read to
  /// show what is on air right now instead of a blank.
  Future<void> _syncProgramScene() async {
    try {
      final snapshot = await widget.connection.fetchScenes();
      if (!mounted || snapshot.programScene == null) return;
      setState(() => _programScene = snapshot.programScene);
    } catch (error) {
      if (mounted) setState(() => _log = 'scene list failed: $error');
    }
  }

  /// The scroll position, but only once it has been measured — `maxScrollExtent`
  /// is null until the first layout, and reading it then throws.
  ScrollPosition? get _position {
    if (!_scroll.hasClients) return null;
    final position = _scroll.position;
    return position.hasContentDimensions ? position : null;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _resumeTimer?.cancel();
    _statusSubscription?.cancel();
    _eventSubscription?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ scrolling

  void _onTick(Duration elapsed) {
    // Cap the step. A backgrounded or throttled window can hand us a single
    // tick with a multi-second gap; without this the script would teleport
    // forward — and the presenter would lose their place.
    final delta = math.min(
      (elapsed - _lastElapsed).inMicroseconds / 1e6,
      0.1,
    );
    _lastElapsed = elapsed;
    if (!_playing || _dragging) return;
    final position = _position;
    if (position == null) return;

    final maxExtent = position.maxScrollExtent;
    if (maxExtent <= 0) return;

    final next = math.min(position.pixels + _speed * delta, maxExtent);
    if (next > position.pixels) _scroll.jumpTo(next);

    if (next >= maxExtent - 0.5 && _playing) {
      setState(() {
        _playing = false;
        _log = 'end of script';
      });
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _resumeTimer?.cancel();
      if (!_dragging) setState(() => _dragging = true);
    } else if (notification is ScrollEndNotification) {
      _resumeTimer?.cancel();
      _resumeTimer = Timer(const Duration(milliseconds: 1200), () {
        if (mounted) setState(() => _dragging = false);
      });
    }
    return false;
  }

  // ------------------------------------------------------------------ cue logic

  /// The heart of it: measure each cue line against the reading line and fire
  /// the ones that just crossed it.
  void _evaluateCues() {
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewport == null || !viewport.attached) return;
    final readingY = viewport.size.height / 2;

    final measured = <({ScriptCue cue, double dy})>[];
    for (final cue in _doc.cues) {
      final box =
          _lineKeys[cue.lineIndex]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached) continue;
      measured.add((
        cue: cue,
        dy: box
            .localToGlobal(
              Offset(0, box.size.height / 2),
              ancestor: viewport,
            )
            .dy,
      ));
    }
    if (measured.isEmpty) return;

    final crossed = <ScriptCue>[];
    for (final entry in measured) {
      final isBelow = entry.dy > readingY;
      if (!isBelow && !_firedLines.contains(entry.cue.lineIndex)) {
        _firedLines.add(entry.cue.lineIndex);
        crossed.add(entry.cue);
      } else if (isBelow && entry.dy > readingY + 24) {
        // Scrolled back above the line — re-arm so scrolling down fires again.
        _firedLines.remove(entry.cue.lineIndex);
      }
    }

    ScriptCue? active;
    ScriptCue? next;
    for (final entry in measured) {
      if (entry.dy <= readingY) {
        active = entry.cue;
      } else {
        next ??= entry.cue;
      }
    }

    if (crossed.isNotEmpty) {
      crossed.sort((a, b) => a.lineIndex.compareTo(b.lineIndex));
      for (final cue in crossed) {
        unawaited(_fireCue(cue));
      }
    }

    if (active != _activeCue || next != _nextCue) {
      setState(() {
        _activeCue = active;
        _nextCue = next;
      });
    }
  }

  Future<void> _fireCue(ScriptCue cue) async {
    final scene = cue.sceneName;
    if (scene == null) {
      if (mounted) {
        setState(() => _log = 'cue "${cue.tag}" — nothing to switch to');
      }
      return;
    }
    try {
      await widget.connection.setProgramScene(scene);
      if (!mounted) return;
      setState(() {
        _log = '${cue.tag}  →  $scene';
        _programScene = scene;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _log = 'cue failed: $error');
    }
  }

  void _jumpToNextCue() {
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final position = _position;
    if (viewport == null || position == null) return;
    final readingY = viewport.size.height / 2;

    for (final cue in _doc.cues) {
      final box =
          _lineKeys[cue.lineIndex]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached) continue;
      final dy = box
          .localToGlobal(Offset(0, box.size.height / 2), ancestor: viewport)
          .dy;
      if (dy <= readingY + 4) continue;
      // Land just past the line so the cut fires on arrival.
      final target = (_scroll.offset + (dy - readingY) + 14).clamp(
        0.0,
        position.maxScrollExtent,
      );
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOutCubic,
      );
      return;
    }
    setState(() => _log = 'no further cues');
  }

  void _restart() {
    _firedLines.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _activeCue = null;
      _nextCue = null;
      _playing = true;
      _log = 'restarted';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _evaluateCues());
  }

  void _nudge(double delta) {
    final position = _position;
    if (position == null) return;
    _scroll.jumpTo(
      (_scroll.offset + delta).clamp(0.0, position.maxScrollExtent),
    );
  }

  // ---------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.prompterBackground,
      body: SafeArea(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.space): () =>
                setState(() => _playing = !_playing),
            const SingleActivator(LogicalKeyboardKey.keyR): _restart,
            const SingleActivator(LogicalKeyboardKey.keyN): _jumpToNextCue,
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _nudge(40),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () => _nudge(-40),
          },
          child: Focus(
            autofocus: true,
            child: Column(
              children: [
                _PrompterHeader(
                  title: _doc.title,
                  programScene: _programScene,
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: _scriptView()),
                      const Positioned.fill(
                        child: IgnorePointer(child: Center(child: _ReadingLine())),
                      ),
                      Positioned(
                        left: 24,
                        right: 24,
                        top: 12,
                        // Wrap: on a narrow screen the two chips stack instead of
                        // overrunning the edge.
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            _CueChip(
                              label: 'NOW',
                              cue: _activeCue,
                              accent: AppColors.cue,
                            ),
                            _CueChip(
                              label: 'NEXT',
                              cue: _nextCue,
                              accent: AppColors.prompterDim,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                _ControlBar(
                  playing: _playing,
                  speed: _speed,
                  fontSize: _fontSize,
                  log: _log,
                  scrollController: _scroll,
                  onToggle: () => setState(() => _playing = !_playing),
                  onSpeedChanged: (value) => setState(() => _speed = value),
                  onFontSizeChanged: (value) =>
                      setState(() => _fontSize = value),
                  onRestart: _restart,
                  onNextCue: _jumpToNextCue,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _scriptView() {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.transparent,
          Colors.white,
          Colors.white,
          Colors.transparent,
        ],
        stops: [0.0, 0.14, 0.86, 1.0],
      ).createShader(rect),
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: SingleChildScrollView(
          key: _viewportKey,
          controller: _scroll,
          physics: const ClampingScrollPhysics(),
          padding: _scriptPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in _doc.lines)
                _ScriptLineView(
                  key: _lineKeys[line.index],
                  line: line,
                  fontSize: _fontSize,
                  live: line.cues.any(
                    (cue) => cue.sceneName != null && cue.sceneName == _programScene,
                  ),
                  isActiveLine: _activeCue?.lineIndex == line.index,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrompterHeader extends StatelessWidget {
  const _PrompterHeader({
    required this.title,
    required this.programScene,
    required this.onBack,
  });

  final String title;
  final String? programScene;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 20, 6),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            tooltip: 'Back to the switcher',
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.prompterText,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'space to pause · n for next cue · r to restart',
                  style: TextStyle(
                    color: AppColors.prompterDim,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.prompterSurface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.prompterBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.cue,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'OBS · ${programScene ?? '—'}',
                  style: const TextStyle(
                    color: AppColors.prompterText,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The line the presenter reads along.
class _ReadingLine extends StatelessWidget {
  const _ReadingLine();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 14),
        Container(
          width: 9,
          height: 9,
          decoration: const BoxDecoration(
            color: AppColors.cue,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: AppColors.cue, blurRadius: 10, spreadRadius: 1),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              color: AppColors.cue.withValues(alpha: 0.85),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66FF3B30),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 14),
      ],
    );
  }
}

class _CueChip extends StatelessWidget {
  const _CueChip({required this.label, required this.cue, required this.accent});

  final String label;
  final ScriptCue? cue;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final active = cue != null;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: active
            ? accent.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.6) : AppColors.prompterBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: accent,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              cue == null ? '—' : '${cue!.tag}  ·  ${cue!.label}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? AppColors.prompterText : AppColors.prompterDim,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScriptLineView extends StatelessWidget {
  const _ScriptLineView({
    super.key,
    required this.line,
    required this.fontSize,
    required this.live,
    required this.isActiveLine,
  });

  final ScriptLine line;
  final double fontSize;
  final bool live;
  final bool isActiveLine;

  @override
  Widget build(BuildContext context) {
    if (line.text.trim().isEmpty) {
      return SizedBox(height: fontSize * 0.8);
    }

    final baseColor = live
        ? AppColors.prompterText
        : AppColors.prompterText.withValues(alpha: 0.78);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: fontSize * 0.42),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.hasCue)
            Padding(
              padding: EdgeInsets.only(top: fontSize * 0.22, right: 14),
              child: Container(
                width: 4,
                height: fontSize * 0.95,
                decoration: BoxDecoration(
                  color: AppColors.cue.withValues(alpha: isActiveLine ? 1 : 0.55),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          Expanded(child: _taggedText(baseColor)),
        ],
      ),
    );
  }

  /// Renders the line, drawing any cue tag in bold red brackets.
  Widget _taggedText(Color baseColor) {
    final spans = <TextSpan>[];
    var cursor = 0;

    for (final match in cueTagPattern.allMatches(line.text)) {
      if (match.start > cursor) {
        spans.add(
          TextSpan(text: line.text.substring(cursor, match.start)),
        );
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: TextStyle(
            color: AppColors.cue,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            backgroundColor: AppColors.cue.withValues(alpha: 0.12),
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < line.text.length) {
      spans.add(TextSpan(text: line.text.substring(cursor)));
    }

    return Text.rich(
      TextSpan(
        style: TextStyle(
          color: baseColor,
          fontSize: fontSize,
          height: 1.42,
          fontWeight: FontWeight.w500,
        ),
        children: spans,
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.playing,
    required this.speed,
    required this.fontSize,
    required this.log,
    required this.scrollController,
    required this.onToggle,
    required this.onSpeedChanged,
    required this.onFontSizeChanged,
    required this.onRestart,
    required this.onNextCue,
  });

  final bool playing;
  final double speed;
  final double fontSize;
  final String log;
  final ScrollController scrollController;
  final VoidCallback onToggle;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<double> onFontSizeChanged;
  final VoidCallback onRestart;
  final VoidCallback onNextCue;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.prompterBackground,
        border: Border(top: BorderSide(color: AppColors.prompterBorder)),
      ),
      child: Column(
        children: [
          ProgressBar(controller: scrollController),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 18,
              runSpacing: 12,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PlayButton(playing: playing, onPressed: onToggle),
                    const SizedBox(width: 10),
                    _GhostButton(
                      icon: Icons.restart_alt_rounded,
                      label: 'Restart',
                      onPressed: onRestart,
                    ),
                    const SizedBox(width: 8),
                    _GhostButton(
                      icon: Icons.keyboard_double_arrow_down_rounded,
                      label: 'Next cue',
                      onPressed: onNextCue,
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'SPEED',
                      style: TextStyle(
                        color: AppColors.prompterDim,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    SizedBox(
                      width: 170,
                      child: SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 3,
                          activeTrackColor: AppColors.prompterText,
                          inactiveTrackColor: AppColors.prompterBorder,
                          thumbColor: AppColors.prompterText,
                          overlayColor: Colors.white.withValues(alpha: 0.08),
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                        ),
                        child: Slider(
                          // Clamped: the slider asserts on out-of-range values.
                          value: speed.clamp(12.0, 140.0),
                          min: 12,
                          max: 140,
                          onChanged: onSpeedChanged,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 62,
                      child: Text(
                        '${speed.round()} px/s',
                        style: const TextStyle(
                          color: AppColors.prompterDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'TEXT',
                      style: TextStyle(
                        color: AppColors.prompterDim,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          onFontSizeChanged((fontSize - 2).clamp(18, 54)),
                      tooltip: 'Smaller text',
                      color: AppColors.prompterText,
                      icon: const Icon(Icons.text_decrease_rounded, size: 20),
                    ),
                    IconButton(
                      onPressed: () =>
                          onFontSizeChanged((fontSize + 2).clamp(18, 54)),
                      tooltip: 'Larger text',
                      color: AppColors.prompterText,
                      icon: const Icon(Icons.text_increase_rounded, size: 20),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(
                        log,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.prompterDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: AppColors.ink,
            size: 26,
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: AppColors.prompterText,
        backgroundColor: AppColors.prompterSurface,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.prompterBorder),
        ),
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Thin read-through indicator: how far into the script we are.
class ProgressBar extends StatelessWidget {
  const ProgressBar({super.key, required this.controller});

  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        var progress = 0.0;
        if (controller.hasClients) {
          final position = controller.position;
          // maxScrollExtent is unknown until the scroll view has been laid out.
          if (position.hasContentDimensions && position.maxScrollExtent > 0) {
            progress = (position.pixels / position.maxScrollExtent).clamp(
              0.0,
              1.0,
            );
          }
        }
        return SizedBox(
          height: 3,
          child: Row(
            children: [
              Expanded(
                flex: math.max(1, (progress * 1000).round()),
                child: const ColoredBox(
                  color: AppColors.cue,
                  child: SizedBox.expand(),
                ),
              ),
              Expanded(
                flex: math.max(1, ((1 - progress) * 1000).round()),
                child: const SizedBox.expand(),
              ),
            ],
          ),
        );
      },
    );
  }
}
