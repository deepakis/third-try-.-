import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'obs_models.dart';

class ObsRequestException implements Exception {
  ObsRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The slice of OBS the UI talks to. Kept as an interface so widget tests can
/// swap in a fake instead of opening a real socket.
abstract class ObsConnection {
  Stream<ObsStatus> get statusStream;
  Stream<Map<String, dynamic>> get eventStream;
  ObsStatus get status;

  Future<void> connect();
  Future<void> dispose();

  Future<SceneSnapshot> fetchScenes();
  Future<int> sceneItemCount(String sceneName);
  Future<Uint8List?> scenePreview(String sceneName);
  Future<void> setProgramScene(String sceneName);
  Future<void> createScene(String sceneName);

  /// Deletes a scene, and its scene items with it. Only the rig reset uses
  /// this (see obs/auto_setup.dart), and only on scenes this app created.
  Future<void> removeScene(String sceneName);

  /// Deletes a source. OBS drops it from every scene that used it, so this is
  /// reserved for the camera source the setup created itself.
  Future<void> removeInput(String inputName);

  // Used by the first-run setup (see obs/auto_setup.dart).
  Future<ObsVideoSettings> videoSettings();
  Future<List<String>> inputKinds();
  Future<List<ObsInput>> inputs();
  Future<List<ObsPropertyItem>> inputPropertyItems(
    String inputName,
    String propertyName,
  );
  Future<void> createInput({
    required String inputName,
    required String inputKind,
    String? sceneName,
  });
  Future<void> setInputSettings(
    String inputName,
    Map<String, dynamic> settings,
  );

  /// Returns the scene item's id, or null when the source isn't in the scene.
  Future<int?> sceneItemId({
    required String sceneName,
    required String sourceName,
  });
  Future<int> createSceneItem({
    required String sceneName,
    required String sourceName,
  });
  Future<void> setSceneItemTransform({
    required String sceneName,
    required int sceneItemId,
    required Map<String, dynamic> transform,
  });

  /// OBS's own view of where a scene item sits — how a placement gets verified.
  Future<Map<String, dynamic>> sceneItemTransform({
    required String sceneName,
    required int sceneItemId,
  });
}

/// Talks obs-websocket protocol v5 (OBS Studio 28+).
///
/// Handshake: the server sends a Hello (op 0) carrying a salt + challenge; we
/// answer with op 1 and
///   `base64(sha256(base64(sha256(password + salt)) + challenge))`.
/// Everything after that is request/response (op 6 / op 7) plus events (op 5).
class ObsClient implements ObsConnection {
  ObsClient({
    required this.uri,
    required this.password,
    this.onLog,
    this.reconnectDelay = const Duration(seconds: 3),
    this.requestTimeout = const Duration(seconds: 10),
    this.autoReconnect = true,
  });

  final Uri uri;
  final String password;
  final void Function(String message)? onLog;
  final Duration reconnectDelay;
  final Duration requestTimeout;

  /// Whether a dropped or failed connection schedules another attempt.
  ///
  /// The app's own client wants this; a one-shot check ("is this OBS address
  /// real?") does not, because a retry loop would keep the answer pending and
  /// keep the app talking to an address the operator just rejected.
  final bool autoReconnect;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<ObsStatus> _statusController =
      StreamController<ObsStatus>.broadcast();
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  ObsStatus _status = const ObsStatus(ObsConnectionState.disconnected);
  int _requestSeq = 0;
  bool _identified = false;
  bool _disposed = false;
  Timer? _retryTimer;
  String _serverLabel = 'OBS';

  @override
  ObsStatus get status => _status;

  @override
  Stream<ObsStatus> get statusStream => _statusController.stream;

  @override
  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

  @override
  Future<void> connect() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _tearDownChannel();
    _identified = false;
    // Every attempt starts from "connecting", which is also the signal the
    // done-handler reads: a status carrying a failure means *this* attempt has
    // already been explained, and nothing should overwrite it.
    _emitStatus(ObsStatus(ObsConnectionState.connecting, detail: uri.host));
    onLog?.call('connecting $uri');
    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        _onFrame,
        onError: (Object error) => onLog?.call('socket error: $error'),
        onDone: _onDone,
        cancelOnError: false,
      );
      await channel.ready;
    } catch (error) {
      onLog?.call('connect failed: $error');
      // This status is the whole diagnosis; the done-event that the failed
      // channel also emits is the same failure and carries none of it.
      final failure = classifyConnectError(error);
      _emitStatus(
        ObsStatus(
          ObsConnectionState.disconnected,
          detail: failure == ObsFailure.mixedContent
              ? 'blocked by the browser (https page, ws:// socket)'
              : 'unreachable — $error',
          failure: failure,
        ),
      );
      _scheduleRetry();
    }
  }

  /// Connects and waits for the handshake to settle either way, so a screen can
  /// say *why* an address did not work instead of spinning forever.
  ///
  /// Returns the status that settled it: identified, or a failure. The listener
  /// is attached before the attempt, because a refusal can be reported while
  /// [connect] is still awaiting the socket.
  Future<ObsStatus> connectAndWait({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final settled = statusStream.firstWhere(
      (status) => status.isConnected || status.failed,
    );
    await connect();
    try {
      return await settled.timeout(timeout);
    } on TimeoutException {
      // Emitting this also settles the listener above, so nothing is left
      // waiting on a socket that never answered.
      final status = ObsStatus(
        ObsConnectionState.disconnected,
        detail: 'no reply from ${uri.host}:${uri.port}',
        failure: ObsFailure.unreachable,
      );
      _emitStatus(status);
      return status;
    }
  }

  /// Reads a failed connection the way an operator would. Kept public and pure
  /// so the wording that decides which advice to show can be tested directly.
  ///
  /// This is message-matching rather than `SocketException` inspection because
  /// `dart:io` does not exist on the web build: the same client runs in a
  /// browser and on the desktop, and only the desktop can tell ECONNREFUSED
  /// (10061 on Windows, 111 on Linux, 61 on BSD) from "no route".
  static ObsFailure classifyConnectError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('insecure') ||
        text.contains('mixed content') ||
        text.contains('securityerror')) {
      return ObsFailure.mixedContent;
    }
    if (text.contains('refused') ||
        text.contains('econnrefused') ||
        text.contains('10061') ||
        // dart:io phrases a refused upgrade as "Connection to '…' was not
        // upgraded to websocket", which is the same operator problem: something
        // is at that address, and it is not OBS's websocket server.
        text.contains('not upgraded')) {
      return ObsFailure.refused;
    }
    return ObsFailure.unreachable;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _failPending('client disposed');
    await _tearDownChannel();
    await _statusController.close();
    await _eventController.close();
  }

  /// Runs an OBS request and returns its `responseData`.
  Future<Map<String, dynamic>> request(
    String requestType, [
    Map<String, dynamic>? requestData,
  ]) async {
    final channel = _channel;
    if (channel == null || !_identified) {
      throw ObsRequestException('$requestType: not connected to OBS');
    }
    final requestId = 'r${++_requestSeq}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    _send(6, {
      'requestType': requestType,
      'requestId': requestId,
      if (requestData != null) 'requestData': requestData,
    });
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      completer.future.ignore();
      throw ObsRequestException('$requestType timed out');
    } finally {
      _pending.remove(requestId);
    }
  }

  @override
  Future<SceneSnapshot> fetchScenes() async {
    final data = await request('GetSceneList');
    final rawScenes = (data['scenes'] as List<dynamic>? ?? const []);
    final scenes = <ObsScene>[
      for (final entry in rawScenes)
        if (entry is Map<String, dynamic>)
          ObsScene(
            index: (entry['sceneIndex'] as num?)?.toInt() ?? 0,
            name: entry['sceneName'] as String? ?? '',
            uuid: entry['sceneUuid'] as String? ?? '',
          ),
    ];
    return SceneSnapshot(
      scenes: scenes,
      programScene: data['currentProgramSceneName'] as String?,
    );
  }

  @override
  Future<int> sceneItemCount(String sceneName) async {
    final data = await request('GetSceneItemList', {'sceneName': sceneName});
    return (data['sceneItems'] as List<dynamic>? ?? const []).length;
  }

  @override
  Future<Uint8List?> scenePreview(String sceneName) async {
    final data = await request('GetSourceScreenshot', {
      'sourceName': sceneName,
      'imageFormat': 'jpeg',
      'imageWidth': 640,
      'imageHeight': 360,
      'imageCompressionQuality': 60,
    });
    final image = data['imageData'] as String?;
    if (image == null) return null;
    final comma = image.indexOf(',');
    return base64.decode(comma >= 0 ? image.substring(comma + 1) : image);
  }

  @override
  Future<void> setProgramScene(String sceneName) async {
    await request('SetCurrentProgramScene', {'sceneName': sceneName});
  }

  @override
  Future<void> createScene(String sceneName) async {
    await request('CreateScene', {'sceneName': sceneName});
  }

  @override
  Future<void> removeScene(String sceneName) async {
    await request('RemoveScene', {'sceneName': sceneName});
  }

  @override
  Future<void> removeInput(String inputName) async {
    await request('RemoveInput', {'inputName': inputName});
  }

  @override
  Future<ObsVideoSettings> videoSettings() async {
    final data = await request('GetVideoSettings');
    return ObsVideoSettings(
      baseWidth: (data['baseWidth'] as num?)?.toInt() ?? 1920,
      baseHeight: (data['baseHeight'] as num?)?.toInt() ?? 1080,
    );
  }

  @override
  Future<List<String>> inputKinds() async {
    final data = await request('GetInputKindList');
    return [
      for (final kind in data['inputKinds'] as List<dynamic>? ?? const [])
        kind.toString(),
    ];
  }

  @override
  Future<List<ObsInput>> inputs() async {
    final data = await request('GetInputList');
    return [
      for (final entry in data['inputs'] as List<dynamic>? ?? const [])
        if (entry is Map<String, dynamic>)
          ObsInput(
            name: entry['inputName'] as String? ?? '',
            kind:
                (entry['unversionedInputKind'] ?? entry['inputKind'])
                    as String? ??
                '',
          ),
    ];
  }

  @override
  Future<List<ObsPropertyItem>> inputPropertyItems(
    String inputName,
    String propertyName,
  ) async {
    final data = await request('GetInputPropertiesListPropertyItems', {
      'inputName': inputName,
      'propertyName': propertyName,
    });
    return [
      for (final entry
          in data['propertyItems'] as List<dynamic>? ?? const [])
        if (entry is Map<String, dynamic>)
          ObsPropertyItem(
            name: entry['itemName'] as String? ?? '',
            value: entry['itemValue']?.toString() ?? '',
            enabled: entry['itemEnabled'] as bool? ?? true,
          ),
    ];
  }

  @override
  Future<void> createInput({
    required String inputName,
    required String inputKind,
    String? sceneName,
  }) async {
    await request('CreateInput', {
      'inputName': inputName,
      'inputKind': inputKind,
      if (sceneName != null) 'sceneName': sceneName,
    });
  }

  @override
  Future<void> setInputSettings(
    String inputName,
    Map<String, dynamic> settings,
  ) async {
    await request('SetInputSettings', {
      'inputName': inputName,
      'inputSettings': settings,
    });
  }

  @override
  Future<int?> sceneItemId({
    required String sceneName,
    required String sourceName,
  }) async {
    try {
      final data = await request('GetSceneItemId', {
        'sceneName': sceneName,
        'sourceName': sourceName,
      });
      return (data['sceneItemId'] as num?)?.toInt();
    } on ObsRequestException {
      // OBS reports "not found" as a failed request; that is a null, not a fault.
      return null;
    }
  }

  @override
  Future<int> createSceneItem({
    required String sceneName,
    required String sourceName,
  }) async {
    final data = await request('CreateSceneItem', {
      'sceneName': sceneName,
      'sourceName': sourceName,
    });
    final id = (data['sceneItemId'] as num?)?.toInt();
    if (id == null) {
      throw ObsRequestException(
        'CreateSceneItem returned no sceneItemId for $sourceName in $sceneName',
      );
    }
    return id;
  }

  @override
  Future<void> setSceneItemTransform({
    required String sceneName,
    required int sceneItemId,
    required Map<String, dynamic> transform,
  }) async {
    await request('SetSceneItemTransform', {
      'sceneName': sceneName,
      'sceneItemId': sceneItemId,
      'sceneItemTransform': transform,
    });
  }

  @override
  Future<Map<String, dynamic>> sceneItemTransform({
    required String sceneName,
    required int sceneItemId,
  }) async {
    final data = await request('GetSceneItemTransform', {
      'sceneName': sceneName,
      'sceneItemId': sceneItemId,
    });
    return data['sceneItemTransform'] as Map<String, dynamic>? ?? const {};
  }

  // ------------------------------------------------------------------ internals

  void _send(int op, Map<String, dynamic> data) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode({'op': op, 'd': data}));
  }

  void _onFrame(dynamic frame) {
    Map<String, dynamic> message;
    try {
      final text = frame is String
          ? frame
          : utf8.decode(frame as List<int>, allowMalformed: true);
      message = jsonDecode(text) as Map<String, dynamic>;
    } catch (error) {
      onLog?.call('ignored malformed frame: $error');
      return;
    }

    final data = message['d'] as Map<String, dynamic>? ?? const {};
    switch (message['op']) {
      case 0:
        _onHello(data);
      case 2:
        _identified = true;
        _emitStatus(
          ObsStatus(ObsConnectionState.identified, detail: _serverLabel),
        );
      case 5:
        if (!_eventController.isClosed) _eventController.add(data);
      case 7:
        _onResponse(data);
      default:
        onLog?.call('unhandled op ${message['op']}');
    }
  }

  void _onHello(Map<String, dynamic> data) {
    final obsVersion = data['obsStudioVersion']?.toString() ?? '?';
    final socketVersion = data['obsWebSocketVersion']?.toString() ?? '?';
    _serverLabel = 'OBS $obsVersion';
    onLog?.call('hello from obs-websocket $socketVersion (OBS $obsVersion)');

    final auth = data['authentication'] as Map<String, dynamic>?;
    _send(1, {
      'rpcVersion': 1,
      if (auth != null)
        'authentication': authString(
          password,
          salt: auth['salt'] as String? ?? '',
          challenge: auth['challenge'] as String? ?? '',
        ),
    });
  }

  void _onResponse(Map<String, dynamic> data) {
    final requestId = data['requestId'] as String?;
    final completer = requestId == null ? null : _pending.remove(requestId);
    if (completer == null || completer.isCompleted) return;

    final status = data['requestStatus'] as Map<String, dynamic>? ?? const {};
    if (status['result'] == true) {
      completer.complete(
        data['responseData'] as Map<String, dynamic>? ?? const {},
      );
    } else {
      final reason = status['comment'] ?? status['code'] ?? 'request failed';
      completer.completeError(ObsRequestException('$reason'));
    }
  }

  void _onDone() {
    // Read the close code before anything clears the channel: obs-websocket
    // says 4009 for a rejected password, and that is the one failure OBS itself
    // names — worth keeping apart from a plain disconnect, because the fix is
    // the password rather than the address.
    final channel = _channel;
    final closeCode = channel?.closeCode;
    final closeReason = channel?.closeReason ?? '';
    final wasIdentified = _identified;
    _identified = false;
    _failPending('connection to OBS closed');
    if (_disposed) return;

    onLog?.call('obs closed the socket: $closeCode $closeReason'.trim());

    // obs-websocket says 4009 for a rejected password, and that is the one
    // failure OBS names itself. Worth its own branch: the fix is the password.
    if (closeCode == authFailedCloseCode ||
        closeReason.toLowerCase().contains('auth')) {
      _emitStatus(
        const ObsStatus(
          ObsConnectionState.disconnected,
          detail: 'password rejected by OBS',
          failure: ObsFailure.wrongPassword,
        ),
      );
      _scheduleRetry();
      return;
    }

    // Measured on Windows against a port with nothing on it: a failed *connect*
    // closes this stream synchronously from inside the adapter's error handler,
    // which runs *before* `connect()`'s catch has classified anything. So there
    // is nothing to report yet — a verdict here would be "disconnected" for a
    // port that the catch is about to call "refused". Wait one turn, and stay
    // quiet if that report has landed by then.
    //
    // A status still at "connecting" means no explanation arrived, so this is a
    // socket that had been up and went away: report it rather than leaving the
    // UI waiting forever.
    if (!wasIdentified && closeCode == null) {
      scheduleMicrotask(() {
        if (_disposed || _status.failure != ObsFailure.none) return;
        _emitStatus(
          const ObsStatus(
            ObsConnectionState.disconnected,
            detail: 'disconnected',
            failure: ObsFailure.closed,
          ),
        );
      });
      _scheduleRetry();
      return;
    }

    _emitStatus(
      ObsStatus(
        ObsConnectionState.disconnected,
        detail: closeCode == null
            ? 'disconnected'
            : 'disconnected ($closeCode)',
        failure: ObsFailure.closed,
      ),
    );
    _scheduleRetry();
  }

  /// obs-websocket's "Authentication failed" close code, sent after a bad
  /// password.
  static const int authFailedCloseCode = 4009;

  void _scheduleRetry() {
    if (_disposed || !autoReconnect) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(reconnectDelay, () {
      _retryTimer = null;
      unawaited(connect());
    });
  }

  void _failPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(ObsRequestException(reason));
      }
    }
    _pending.clear();
  }

  Future<void> _tearDownChannel() async {
    final subscription = _subscription;
    final channel = _channel;
    _subscription = null;
    _channel = null;
    await subscription?.cancel();
    if (channel != null) {
      try {
        await channel.sink.close();
      } catch (_) {
        // Socket already gone; nothing useful to report.
      }
    }
  }

  void _emitStatus(ObsStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }
}

/// obs-websocket v5 auth string. Exposed for tests.
String authString(
  String password, {
  required String salt,
  required String challenge,
}) {
  final secret = base64.encode(
    sha256.convert(utf8.encode(password + salt)).bytes,
  );
  return base64.encode(sha256.convert(utf8.encode(secret + challenge)).bytes);
}
