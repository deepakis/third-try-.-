import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../obs/auto_setup.dart';
import '../obs/layouts.dart';
import '../obs/obs_client.dart';
import '../obs/obs_models.dart';
import '../teleprompter/teleprompter_screen.dart';
import 'camera_tile.dart';
import 'rig_picker.dart';
import 'setup_banner.dart';
import 'theme.dart';
import 'wizard.dart';

/// How much of the first-run wizard this screen should run.
///
/// Step 1 (connect) is the pairing screen; this screen owns steps 2 and 3, and
/// whether they run is a decision the app makes, not the screen: it depends on
/// why the operator is here.
enum WizardMode {
  /// No wizard — a launch that was told to set up later, or a test with
  /// nowhere to pair.
  off,

  /// The screen pairing just handed over to. The shot picker opens by itself
  /// when the rig needs building, and step 3 confirms the operator is live.
  pairing,

  /// A launch that restored an endpoint paired earlier. Step 2 is offered if
  /// the rig turns out not to be set up (and never opened unasked), and a rig
  /// that already works gets no wizard at all.
  ifMissing,
}

/// Which step of the first-run wizard this screen is showing.
///
/// Step 1 (connect) is the pairing screen; this screen owns 2 and 3.
enum _WizardStage { shots, live }

/// The whole app: two shots, one tap each, and a live read-out of what OBS is
/// actually sending.
class SwitcherScreen extends StatefulWidget {
  const SwitcherScreen({
    super.key,
    this.slots = AppConfig.cameras,
    this.connection,
    this.previewInterval = AppConfig.previewInterval,
    this.onPair,
    this.endpoint,
    this.wizard = WizardMode.off,
  });

  final List<CameraSlot> slots;

  /// Injected in tests; in the app we build a real [ObsClient].
  final ObsConnection? connection;
  final Duration previewInterval;

  /// Opens the pairing screen, so a wrong address can be fixed without
  /// restarting the app. Null in tests that have nowhere to go.
  final VoidCallback? onPair;

  /// The OBS this session is pointed at (`host:port`), shown in the header once
  /// connected. Without it the only way to say "which OBS?" is the connection
  /// chip, which reports OBS's own version rather than where it lives.
  final String? endpoint;

  /// How much of the first-run wizard to run here.
  final WizardMode wizard;

  @override
  State<SwitcherScreen> createState() => _SwitcherScreenState();
}

class _SwitcherScreenState extends State<SwitcherScreen> {
  /// The shots on screen. Starts from the config, and changes when the operator
  /// picks a different rig or OBS turns out to hold one they built earlier.
  late List<CameraSlot> _slots = List<CameraSlot>.of(widget.slots);

  /// True once the shots were chosen in this session, so the rig is never
  /// swapped out from under a deliberate pick.
  bool _userPickedRig = false;

  late final ObsConnection _obs;
  late final bool _ownsConnection;
  StreamSubscription<ObsStatus>? _statusSubscription;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  Timer? _previewTimer;

  ObsStatus _status = const ObsStatus(ObsConnectionState.disconnected);
  List<ObsScene> _scenes = const [];
  String? _programScene;
  final Map<String, Uint8List?> _previews = {};
  final Map<String, int?> _sourceCounts = {};
  final Map<String, bool> _busy = {};
  final Map<String, String?> _errors = {};
  final Map<String, bool> _previewInFlight = {};
  bool _autoCreateScenes = true;
  String _activity = '';
  bool _setupRunning = false;
  bool _setupDismissed = false;
  final List<SetupStep> _setupSteps = [];
  SetupReport? _setupReport;

  /// The wizard step on screen, or null when the wizard is not running.
  _WizardStage? _wizardStage;

  /// True once the scene list has been read with the wizard running, so the
  /// step-2/step-3 decision is made once and against real data.
  bool _wizardSettled = false;

  @override
  void initState() {
    super.initState();
    if (widget.wizard != WizardMode.off) _wizardStage = _WizardStage.shots;
    _ownsConnection = widget.connection == null;
    _obs =
        widget.connection ??
        ObsClient(
          uri: AppConfig.obsUri,
          password: AppConfig.obsPassword,
          onLog: _log,
        );
    _status = _obs.status;
    _statusSubscription = _obs.statusStream.listen(_onStatus);
    _eventSubscription = _obs.eventStream.listen(_onEvent);
    // When the app owns the connection it has already started it.
    if (_ownsConnection) unawaited(_obs.connect());
    _previewTimer = Timer.periodic(
      widget.previewInterval,
      (_) => unawaited(_refreshPreviews()),
    );
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _statusSubscription?.cancel();
    _eventSubscription?.cancel();
    if (_ownsConnection) unawaited(_obs.dispose());
    super.dispose();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() => _activity = message);
  }

  void _onStatus(ObsStatus status) {
    if (!mounted) return;
    setState(() {
      _status = status;
      if (!status.isConnected) {
        _scenes = const [];
        _programScene = null;
      }
    });
    if (status.isConnected) {
      // Both the wizard and the previews need the scene list, so the wizard's
      // decision waits for it rather than reading a stale list.
      unawaited(_refreshScenes().then((_) => _maybeAdvanceWizard()));
      unawaited(_refreshPreviews());
    }
  }

  void _onEvent(Map<String, dynamic> event) {
    final eventData = event['eventData'] as Map<String, dynamic>? ?? const {};
    switch (event['eventType']) {
      case 'CurrentProgramSceneChanged':
        if (!mounted) return;
        setState(() => _programScene = eventData['sceneName'] as String?);
      case 'SceneListChanged':
      case 'SceneCreated':
      case 'SceneRemoved':
        unawaited(_refreshScenes());
    }
  }

  Future<void> _refreshScenes() async {
    if (!_status.isConnected) return;
    try {
      final snapshot = await _obs.fetchScenes();
      if (!mounted) return;
      setState(() {
        _scenes = snapshot.scenes;
        _programScene = snapshot.programScene;
        if (_adoptRigFromOBS()) {
          _previews.clear();
          _sourceCounts.clear();
        }
      });
    } catch (error) {
      _log('scene list failed: $error');
    }
  }

  /// Takes the rig from OBS when the configured shots aren't there but a rig
  /// from an earlier run is.
  ///
  /// Without this, choosing shots would only last for one session: the next
  /// launch would look for the configured scenes, not find them, and offer the
  /// first-run setup again — over a rig that is sitting right there.
  bool _adoptRigFromOBS() {
    if (_userPickedRig) return false;
    // Not while a run is mutating those very scenes. A reset removes our rig
    // scenes one at a time, and each removal sends a scene-list event: adopting
    // from the list mid-run picked up a half-deleted rig, so the screen showed
    // one shot that had just been removed (found by a test that names the
    // button after the shots it would build).
    if (_setupRunning) return false;
    // Only when *none* of the current shots exist: a half-built rig is a job
    // for the setup, not a reason to rearrange the screen.
    if (_targets.values.any((scene) => scene != null)) return false;
    final adopted = rigFromScenes([for (final scene in _scenes) scene.name]);
    if (adopted.isEmpty) return false;
    if (_sameScenes(adopted, _slots)) return false;
    _slots = adopted;
    _log('using the rig already in OBS: ${_labelList(adopted)}');
    return true;
  }

  bool _sameScenes(List<CameraSlot> a, List<CameraSlot> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].sceneName != b[i].sceneName) return false;
    }
    return true;
  }

  String _labelList(List<CameraSlot> slots) =>
      slots.map((slot) => slot.sceneName).join(', ');

  Map<String, ObsScene?> get _targets => resolveTargets(_slots, _scenes);

  /// Pulls a fresh thumbnail for every tile whose scene actually has sources.
  /// Empty scenes are skipped so we never render OBS's black placeholder frame.
  Future<void> _refreshPreviews() async {
    if (!_status.isConnected) return;
    final targets = _targets;

    for (final slot in _slots) {
      final id = slot.id;
      if (_previewInFlight[id] == true) continue;
      final scene = targets[id];
      if (scene == null) continue;

      _previewInFlight[id] = true;
      try {
        var count = _sourceCounts[scene.name];
        count ??= await _obs.sceneItemCount(scene.name);
        if (!mounted) return;
        setState(() => _sourceCounts[scene.name] = count);

        if (count == 0) {
          if (_previews[id] != null) setState(() => _previews[id] = null);
          continue;
        }
        final bytes = await _obs.scenePreview(scene.name);
        if (!mounted || bytes == null) continue;
        setState(() => _previews[id] = bytes);
      } catch (error) {
        _log('preview failed for ${slot.label}: $error');
      } finally {
        _previewInFlight[id] = false;
      }
    }
  }

  /// Scene names the slots expect but OBS doesn't have yet.
  List<String> get _missingScenes {
    if (!_status.isConnected) return const [];
    final targets = _targets;
    return [
      for (final slot in _slots)
        if (targets[slot.id] == null) slot.sceneName,
    ];
  }

  /// The app's own rig scenes sitting in OBS right now — what a from-scratch
  /// run would clear.
  List<String> get _rigScenesInOBS {
    if (!_status.isConnected) return const [];
    final present = {for (final scene in _scenes) scene.name};
    return [
      for (final name in rigSceneNames)
        if (present.contains(name)) name,
    ]..sort();
  }

  /// Names of the shots on screen, for the banner's button copy.
  List<String> get _shotLabels => [
    for (final slot in _slots)
      layoutOptionForScene(slot.sceneName)?.label ?? slot.label,
  ];

  /// Rig scenes in OBS that the shots on screen don't use — the leftovers a
  /// reset exists for. (A rig that is fully built has none, so the banner stays
  /// out of the way.)
  List<String> get _leftoverRigScenes {
    final used = {for (final slot in _slots) slot.sceneName.toLowerCase()};
    return [
      for (final name in _rigScenesInOBS)
        if (!used.contains(name.toLowerCase())) name,
    ];
  }

  bool get _showSetupBanner =>
      !_setupDismissed &&
      (_setupRunning ||
          _setupReport != null ||
          _missingScenes.isNotEmpty ||
          _leftoverRigScenes.isNotEmpty);

  /// Builds the rig from scratch: the app's own rig scenes (and the camera
  /// source it created) are cleared first, then the shots are built.
  ///
  /// Starting clean is the point — a scene that already exists would keep its
  /// old framing, so a re-run would silently not apply what was just picked.
  Future<void> _runSetup({bool build = true}) async {
    setState(() {
      _setupRunning = true;
      _setupSteps.clear();
      _setupReport = null;
    });
    void step(SetupStep step) {
      if (mounted) setState(() => _setupSteps.add(step));
    }

    var ok = true;
    String? error;
    String? cameraSource;

    final reset = await ObsRigReset(connection: _obs, onStep: step).run();
    ok = reset.ok;
    error = reset.error;

    if (ok && build) {
      final setup = await ObsAutoSetup(
        connection: _obs,
        slots: _slots,
        onStep: step,
      ).run();
      ok = setup.ok;
      error = setup.error;
      cameraSource = setup.cameraSource;
    }

    await _refreshScenes();
    if (!mounted) return;
    setState(() {
      _setupRunning = false;
      // After a reset-only run there is nothing to report as configured: the
      // banner drops back to offering the setup, with the steps still listed.
      _setupReport = build
          ? SetupReport(
              steps: List<SetupStep>.of(_setupSteps),
              ok: ok,
              cameraSource: cameraSource,
              error: error,
            )
          : null;
      if (!build) _setupDismissed = false;
      // A rig that just got built is step 3: the wizard's last word is that the
      // operator is live, not that the setup finished.
      if (ok && build && _wizardStage == _WizardStage.shots) {
        _wizardStage = _WizardStage.live;
      }
    });
    unawaited(_refreshPreviews());
  }

  /// Settles which step the wizard is on, once OBS has answered with its scene
  /// list.
  ///
  /// The scene list is the point: a rig built on an earlier run is adopted in
  /// [_refreshScenes], and only then is "is the rig already set up?" an
  /// answerable question.
  void _maybeAdvanceWizard() {
    if (!mounted) return;
    if (_wizardStage != _WizardStage.shots || _wizardSettled) return;
    _wizardSettled = true;

    // Nothing is asked of the operator here. Step 2 is the setup banner's
    // primary button — building the shots they already have — so the only
    // question left is whether there is anything to build at all.
    if (_missingScenes.isNotEmpty || _leftoverRigScenes.isNotEmpty) return;
    // Straight after pairing, a rig that already exists is still worth one
    // line: step 3 was promised and "you're live" is how the wizard ends. On a
    // later launch a working rig is no reason to say anything.
    setState(
      () => _wizardStage = widget.wizard == WizardMode.pairing
          ? _WizardStage.live
          : null,
    );
  }

  /// The wizard's version of "where you are", for the setup banner's first
  /// line. Null when no wizard is running, so an ordinary launch says nothing
  /// about steps.
  String? get _wizardStepLabel {
    if (_wizardStage == null) return null;
    final number = _wizardStage == _WizardStage.shots ? 2 : 3;
    return 'Step $number of ${WizardSteps.labels.length} · '
        '${WizardSteps.labels[number - 1]}';
  }

  /// Step 3's line: which scene is going out, and how to change it.
  String get _wizardLiveMessage {
    final cuts = _slots.isEmpty
        ? 'Tap a tile to cut.'
        : 'Press ${[
            for (var i = 0; i < _slots.length; i++) i + 1,
          ].join(' / ')} or tap a tile to cut.';
    final live = _programScene;
    if (live == null || live.isEmpty) return 'You are live. $cuts';
    return 'You are live on "$live". $cuts';
  }

  /// Opens the shot picker, then rebuilds the rig with what was picked.
  ///
  /// The alternative to the primary action: the shots the operator already has
  /// are what step 2 sets up, and this is how they change them instead.
  Future<void> _chooseShots() async {
    final current = [
      for (final slot in _slots)
        if (layoutOptionForScene(slot.sceneName) != null)
          layoutOptionForScene(slot.sceneName)!.id,
    ];
    final picked = await RigPickerDialog.show(
      context,
      initialIds: current.isEmpty ? const ['full', 'zoom'] : current,
    );
    if (picked == null || !mounted) return;

    final next = slotsForLayoutIds(picked);
    if (next.isEmpty) return;
    if (!await _confirmRebuild(next)) return;
    setState(() {
      _slots = next;
      _userPickedRig = true;
      _setupDismissed = false;
      _previews.clear();
      _sourceCounts.clear();
      _programScene = null;
    });
    await _runSetup();
  }

  /// Re-runs the setup with the shots that are already on screen.
  Future<void> _rebuildCurrentRig() async {
    if (!await _confirmRebuild(_slots)) return;
    await _runSetup();
  }

  /// Clears the rig without building anything back.
  Future<void> _resetRig() async {
    if (!await _confirmRebuild(const [])) return;
    await _runSetup(build: false);
  }

  /// Scenes (and our own camera source) a from-scratch run would delete, so the
  /// operator sees exactly what goes before it goes.
  Future<List<String>> _removals() async {
    if (!_status.isConnected) return const [];
    final present = {for (final scene in _scenes) scene.name};
    final doomed = [
      for (final name in rigSceneNames)
        if (present.contains(name)) name,
    ];
    // A failed input query only costs us the note about the camera below; the
    // reset itself checks again before deleting anything.
    try {
      final ours = (await _obs.inputs()).where(
        (input) => input.name == defaultCameraInputName,
      );
      if (ours.isNotEmpty) doomed.add(defaultCameraInputName);
    } catch (_) {
      // Reported by the run itself.
    }
    return doomed..sort();
  }

  /// Returns true when it is safe to go ahead: either nothing gets deleted, or
  /// the operator confirmed the list.
  Future<bool> _confirmRebuild(List<CameraSlot> next) async {
    final doomed = await _removals();
    if (doomed.isEmpty) return true;
    if (!mounted) return false;

    final builds = next.isEmpty
        ? null
        : [for (final slot in next) slot.sceneName].join(', ');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: const Text(
          'Rebuild the rig from scratch?',
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(
            'Deleted from OBS first: ${doomed.join(', ')}.\n\n'
            '${builds == null ? 'Nothing is built back.' : 'Then built: $builds.'}\n\n'
            'OBS\'s own camera source and your own scenes are left alone.',
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.45,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            child: Text(
              builds == null ? 'Remove' : 'Remove & rebuild',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _openTeleprompter() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TeleprompterScreen(connection: _obs, slots: _slots),
      ),
    );
  }

  Future<void> _cut(CameraSlot slot) async {
    if (!_status.isConnected || _busy[slot.id] == true) return;
    setState(() {
      _busy[slot.id] = true;
      _errors[slot.id] = null;
    });
    try {
      var target = _targets[slot.id];
      if (target == null) {
        if (!_autoCreateScenes) {
          setState(
            () => _errors[slot.id] = 'no "${slot.sceneName}" scene in OBS',
          );
          return;
        }
        await _obs.createScene(slot.sceneName);
        await _refreshScenes();
        target = _targets[slot.id];
      }
      if (target == null) {
        setState(() => _errors[slot.id] = 'could not resolve a scene');
        return;
      }
      if (_programScene == target.name) return;

      await _obs.setProgramScene(target.name);
      if (!mounted) return;
      setState(() => _programScene = target!.name);
      _log('cut to ${target.name}');
    } catch (error) {
      if (mounted) setState(() => _errors[slot.id] = '$error');
    } finally {
      if (mounted) setState(() => _busy[slot.id] = false);
    }
  }

  String? _placeholderHint(CameraSlot slot, ObsScene? scene) {
    if (scene == null) {
      return 'No "${slot.sceneName}" scene in OBS yet — tap to create it';
    }
    final count = _sourceCounts[scene.name];
    if (count == null) return 'Reading scene…';
    if (count == 0) return 'Scene is empty — add a capture source in OBS';
    return 'Loading preview…';
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            if (_slots.isNotEmpty)
              const SingleActivator(LogicalKeyboardKey.digit1): () =>
                  unawaited(_cut(_slots[0])),
            if (_slots.length > 1)
              const SingleActivator(LogicalKeyboardKey.digit2): () =>
                  unawaited(_cut(_slots[1])),
            if (_slots.length > 2)
              const SingleActivator(LogicalKeyboardKey.digit3): () =>
                  unawaited(_cut(_slots[2])),
            const SingleActivator(LogicalKeyboardKey.keyR): () =>
                unawaited(_obs.connect()),
            const SingleActivator(LogicalKeyboardKey.keyT): _openTeleprompter,
          },
          child: Focus(
            autofocus: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
              child: Column(
                children: [
                  _Header(
                    status: _status,
                    endpoint: widget.endpoint,
                    onReconnect: () => unawaited(_obs.connect()),
                    onOpenTeleprompter: _openTeleprompter,
                    onPair: widget.onPair,
                  ),
                  const SizedBox(height: 20),
                  // One card of guidance, never two: the wizard step folds into
                  // the setup banner (the two stacked cards is what pushed the
                  // cameras off the page), and stands alone only when there is
                  // no banner to fold into.
                  if (_showSetupBanner)
                    SetupBanner(
                      rigScenes: _rigScenesInOBS,
                      shotLabels: _shotLabels,
                      running: _setupRunning,
                      steps: _setupSteps,
                      report: _setupReport,
                      onChooseShots: () => unawaited(_chooseShots()),
                      onQuickSetup: () => unawaited(_rebuildCurrentRig()),
                      onReset: () => unawaited(_resetRig()),
                      onDismiss: () => setState(() => _setupDismissed = true),
                      stepLabel: _wizardStepLabel,
                    )
                  else if (_wizardStage != null)
                    WizardBanner(
                      step: _wizardStage == _WizardStage.shots ? 2 : 3,
                      message: _wizardStage == _WizardStage.shots
                          ? 'Your shots are not set up in OBS yet.'
                          : _wizardLiveMessage,
                      onDone: () => setState(() => _wizardStage = null),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final sideBySide = constraints.maxWidth >= 680;
                        final tiles = <Widget>[
                          for (final slot in _slots)
                            CameraTile(
                              key: ValueKey(slot.id),
                              slot: slot,
                              isLive:
                                  _programScene != null &&
                                  _programScene == targets[slot.id]?.name,
                              isBusy: _busy[slot.id] == true,
                              enabled: _status.isConnected,
                              onTap: () => unawaited(_cut(slot)),
                              preview: _previews[slot.id],
                              error: _errors[slot.id],
                              resolvedScene: targets[slot.id]?.name,
                              placeholderHint: _placeholderHint(
                                slot,
                                targets[slot.id],
                              ),
                              shortcut: '${_slots.indexOf(slot) + 1}',
                            ),
                        ];

                        // Keep a floor on tile size: below it the shots stop
                        // being readable, so the page scrolls instead.
                        // Enough for the preview, the label, the description
                        // and the status line to all be visible.
                        const minTileHeight = 360.0;
                        if (sideBySide) {
                          final row = Row(
                            children: _withGaps(
                              [
                                for (final tile in tiles) Expanded(child: tile),
                              ],
                              20,
                              vertical: false,
                            ),
                          );
                          if (constraints.maxHeight >= 320) return row;
                          return SingleChildScrollView(
                            child: SizedBox(height: 320, child: row),
                          );
                        }

                        const gap = 16.0;
                        final needed =
                            tiles.length * minTileHeight +
                            gap * (tiles.length - 1);
                        if (constraints.maxHeight < needed) {
                          return SingleChildScrollView(
                            child: Column(
                              children: _withGaps([
                                for (final tile in tiles)
                                  SizedBox(height: minTileHeight, child: tile),
                              ], gap, vertical: true),
                            ),
                          );
                        }
                        return Column(
                          children: _withGaps(
                            [
                              for (final tile in tiles) Expanded(child: tile),
                            ],
                            gap,
                            vertical: true,
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                  _Footer(
                    programScene: _programScene,
                    activity: _activity,
                    autoCreate: _autoCreateScenes,
                    onAutoCreateChanged: (value) =>
                        setState(() => _autoCreateScenes = value),
                    onReconnect: () => unawaited(_obs.connect()),
                    shortcuts: [
                      for (var i = 0; i < _slots.length; i++)
                        '${i + 1} → ${_slots[i].label}',
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _withGaps(
    List<Widget> children,
    double gap, {
    required bool vertical,
  }) {
    final out = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        out.add(SizedBox(width: vertical ? 0 : gap, height: vertical ? gap : 0));
      }
      out.add(children[i]);
    }
    return out;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.status,
    required this.onReconnect,
    required this.onOpenTeleprompter,
    this.endpoint,
    this.onPair,
  });

  final ObsStatus status;
  final VoidCallback onReconnect;
  final VoidCallback onOpenTeleprompter;

  /// The OBS this session is pointed at, shown as a tappable chip while
  /// connected.
  final String? endpoint;
  final VoidCallback? onPair;

  @override
  Widget build(BuildContext context) {
    // Wrap, so a narrow window drops the controls onto a second line instead of
    // overflowing.
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Open Flutter',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Live scene switcher · course capture',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted.withValues(alpha: 0.95),
                ),
              ),
            ],
          ),
        ),
        // Wrap as well: on a phone-width window the controls fold onto their
        // own line rather than overflowing.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
          onPressed: onOpenTeleprompter,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.ink,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text(
                'Teleprompter',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            _ConnectionChip(status: status),
            // "Connect" only means something when there is nothing to connect
            // to. While the socket is up the same slot shows *which* OBS, and
            // tapping it is how a different one is paired.
            if (status.isConnected && endpoint != null && onPair != null)
              Tooltip(
                message: 'Change the OBS this app is pointed at',
                child: TextButton.icon(
                  onPressed: onPair,
                  icon: const Icon(Icons.cable_rounded, size: 16),
                  label: Text(
                    endpoint!,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
            else if (onPair != null)
              TextButton.icon(
                onPressed: onPair,
                icon: const Icon(Icons.cable_rounded, size: 16),
                label: const Text(
                  'Connect…',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
            IconButton(
              onPressed: onReconnect,
              tooltip: 'Reconnect to OBS',
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.status});

  final ObsStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (status.state) {
      ObsConnectionState.identified => (AppColors.success, status.label),
      ObsConnectionState.connecting => (AppColors.warn, status.label),
      ObsConnectionState.disconnected => (AppColors.danger, status.label),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 9),
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.programScene,
    required this.activity,
    required this.autoCreate,
    required this.onAutoCreateChanged,
    required this.onReconnect,
    required this.shortcuts,
  });

  final String? programScene;
  final String activity;
  final bool autoCreate;
  final ValueChanged<bool> onAutoCreateChanged;
  final VoidCallback onReconnect;
  final List<String> shortcuts;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      // A Wrap, not a Row: on a narrow window the footer drops to two lines
      // instead of overflowing.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 18,
        runSpacing: 10,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final shortcut in shortcuts) ...[
                _KeycapHint(text: shortcut),
                const SizedBox(width: 8),
              ],
            ],
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              activity.isEmpty ? 'idle' : activity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: AppColors.ink,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: AppColors.live,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'ON AIR · ${programScene ?? '—'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'auto-create scenes',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              Switch(value: autoCreate, onChanged: onAutoCreateChanged),
            ],
          ),
        ],
      ),
    );
  }
}

class _KeycapHint extends StatelessWidget {
  const _KeycapHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Text(
            text.split(' → ').first,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          text.split(' → ').last,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}
