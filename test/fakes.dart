import 'dart:async';
import 'dart:typed_data';

import 'package:open_flutter/obs/obs_client.dart';
import 'package:open_flutter/obs/obs_models.dart';

/// One source placed in a scene.
class FakeSceneItem {
  FakeSceneItem({required this.id, required this.sourceName, this.transform});

  final int id;
  final String sourceName;
  Map<String, dynamic>? transform;
}

/// Stands in for a live OBS: enough of the model for the switcher, the
/// prompter and the auto-setup to be driven in tests.
class FakeObsConnection implements ObsConnection {
  FakeObsConnection({
    List<ObsScene>? scenes,
    this.programScene,
    Map<String, int>? sourceCounts,
    this.createThrows = false,
    List<ObsInput>? inputs,
    this.availableKinds = const ['dshow_input', 'wasapi_output_capture'],
    Map<String, List<ObsPropertyItem>>? propertyItems,
    this.video = const ObsVideoSettings(baseWidth: 1366, baseHeight: 768),
    this.listLagReads = 0,
  }) : scenes = scenes ?? const [],
       // A fresh, mutable copy: the reset mutates it when a scene goes.
       sourceCounts = {...?sourceCounts},
       inputList = inputs ?? const [],
       propertyItems = propertyItems ?? const {};

  List<ObsScene> scenes;
  String? programScene;
  final Map<String, int> sourceCounts;
  final bool createThrows;
  List<ObsInput> inputList;
  final List<String> availableKinds;
  final Map<String, List<ObsPropertyItem>> propertyItems;
  final ObsVideoSettings video;

  /// How many scene-list reads still report a scene that was just removed. OBS
  /// really does this (observed on a live install), and a from-scratch rebuild
  /// runs straight into it.
  final int listLagReads;

  /// Scene names still being listed after removal, with reads left to serve.
  final Map<String, int> _lagging = {};

  /// How many scene lists have been handed out, so a test can see the wait.
  int listReads = 0;

  /// Scene name -> items placed in it.
  final Map<String, List<FakeSceneItem>> sceneItems = {};

  /// Every mutation in order, e.g. `set:Camera B`, `createScene:Zoom_Cam`,
  /// `transform:Zoom_Cam:1.3`.
  final List<String> calls = [];

  final Map<String, Map<String, dynamic>> inputSettings = {};
  final StreamController<ObsStatus> _statusController =
      StreamController<ObsStatus>.broadcast();
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();
  ObsStatus _status = const ObsStatus(ObsConnectionState.disconnected);
  bool disposed = false;
  int _nextItemId = 1;

  @override
  ObsStatus get status => _status;

  @override
  Stream<ObsStatus> get statusStream => _statusController.stream;

  @override
  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

  @override
  Future<void> connect() async {
    _status = const ObsStatus(
      ObsConnectionState.identified,
      detail: 'OBS 32.2.2',
    );
    _statusController.add(_status);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _statusController.close();
    await _eventController.close();
  }

  @override
  Future<SceneSnapshot> fetchScenes() async {
    listReads++;
    final stale = <ObsScene>[];
    _lagging.removeWhere((name, readsLeft) {
      if (readsLeft <= 0) return true;
      _lagging[name] = readsLeft - 1;
      stale.add(
        ObsScene(index: scenes.length, name: name, uuid: 'uuid-$name'),
      );
      return false;
    });
    return SceneSnapshot(
      scenes: [...scenes, ...stale],
      programScene: programScene,
    );
  }

  @override
  Future<int> sceneItemCount(String sceneName) async =>
      sourceCounts[sceneName] ?? (sceneItems[sceneName]?.length ?? 0);

  @override
  Future<Uint8List?> scenePreview(String sceneName) async => null;

  @override
  Future<void> setProgramScene(String sceneName) async {
    calls.add('set:$sceneName');
    programScene = sceneName;
    _eventController.add({
      'eventType': 'CurrentProgramSceneChanged',
      'eventData': {'sceneName': sceneName},
    });
  }

  @override
  Future<void> createScene(String sceneName) async {
    calls.add('createScene:$sceneName');
    if (createThrows) throw ObsRequestException('nope');
    scenes = [
      ...scenes,
      ObsScene(index: scenes.length, name: sceneName, uuid: 'uuid-$sceneName'),
    ];
    _eventController.add({
      'eventType': 'SceneCreated',
      'eventData': {'sceneName': sceneName},
    });
  }

  @override
  Future<void> removeScene(String sceneName) async {
    calls.add('removeScene:$sceneName');
    if (listLagReads > 0) _lagging[sceneName] = listLagReads;
    scenes = [for (final scene in scenes) if (scene.name != sceneName) scene];
    sceneItems.remove(sceneName);
    sourceCounts.remove(sceneName);
    if (programScene == sceneName) programScene = null;
    _eventController.add({
      'eventType': 'SceneRemoved',
      'eventData': {'sceneName': sceneName},
    });
  }

  @override
  Future<void> removeInput(String inputName) async {
    calls.add('removeInput:$inputName');
    // OBS drops a removed source from every scene that used it.
    inputList = [for (final input in inputList) if (input.name != inputName) input];
    for (final items in sceneItems.values) {
      items.removeWhere((item) => item.sourceName == inputName);
    }
    inputSettings.remove(inputName);
  }

  @override
  Future<ObsVideoSettings> videoSettings() async => video;

  @override
  Future<List<String>> inputKinds() async => availableKinds;

  @override
  Future<List<ObsInput>> inputs() async => inputList;

  @override
  Future<List<ObsPropertyItem>> inputPropertyItems(
    String inputName,
    String propertyName,
  ) async =>
      propertyItems['$inputName/$propertyName'] ?? const [];

  @override
  Future<void> createInput({
    required String inputName,
    required String inputKind,
    String? sceneName,
  }) async {
    calls.add('createInput:$inputName:$inputKind');
    inputList = [...inputList, ObsInput(name: inputName, kind: inputKind)];
    if (sceneName != null) {
      sceneItems.putIfAbsent(sceneName, () => []).add(
        FakeSceneItem(id: _nextItemId++, sourceName: inputName),
      );
    }
  }

  @override
  Future<void> setInputSettings(
    String inputName,
    Map<String, dynamic> settings,
  ) async {
    calls.add('inputSettings:$inputName:${settings.values.first}');
    inputSettings.putIfAbsent(inputName, () => {}).addAll(settings);
  }

  @override
  Future<int?> sceneItemId({
    required String sceneName,
    required String sourceName,
  }) async {
    for (final item in sceneItems[sceneName] ?? const <FakeSceneItem>[]) {
      if (item.sourceName == sourceName) return item.id;
    }
    return null;
  }

  @override
  Future<int> createSceneItem({
    required String sceneName,
    required String sourceName,
  }) async {
    calls.add('createSceneItem:$sceneName:$sourceName');
    final item = FakeSceneItem(id: _nextItemId++, sourceName: sourceName);
    sceneItems.putIfAbsent(sceneName, () => []).add(item);
    return item.id;
  }

  @override
  Future<void> setSceneItemTransform({
    required String sceneName,
    required int sceneItemId,
    required Map<String, dynamic> transform,
  }) async {
    // Bounds shots are logged by their box; the zoom by its scale.
    final bounds = transform['boundsType'];
    final kind = bounds == 'OBS_BOUNDS_NONE' || bounds == null
        ? transform['scaleX']
        : bounds;
    calls.add('transform:$sceneName:$kind');
    final items = sceneItems[sceneName] ?? const <FakeSceneItem>[];
    for (final item in items) {
      if (item.id == sceneItemId) item.transform = transform;
    }
  }

  @override
  Future<Map<String, dynamic>> sceneItemTransform({
    required String sceneName,
    required int sceneItemId,
  }) async {
    for (final item in sceneItems[sceneName] ?? const <FakeSceneItem>[]) {
      if (item.id == sceneItemId) return item.transform ?? const {};
    }
    return const {};
  }
}

ObsScene scene(String name, int index) =>
    ObsScene(index: index, name: name, uuid: 'uuid-$name');
