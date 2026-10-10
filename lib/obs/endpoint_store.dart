import 'dart:convert';

import 'connection_target.dart';
import 'endpoint_store_io.dart'
    if (dart.library.js_interop) 'endpoint_store_web.dart' as platform;

/// Remembers which OBS the operator paired with, so it survives a relaunch.
///
/// One endpoint per machine, not per scene: the app talks to a single OBS, and
/// re-pairing is a deliberate act (the switcher offers it).
abstract class EndpointStore {
  Future<ConnectionTarget?> load();

  Future<void> save(ConnectionTarget target);

  Future<void> clear();
}

/// The store for the platform this build runs on: `localStorage` on the web
/// build, a small JSON file on desktop. Tests pass [MemoryEndpointStore].
EndpointStore createEndpointStore() => platform.createEndpointStore();

/// The stored form of an endpoint. Kept here, next to the interface, so the web
/// and file stores cannot drift apart in what they write.
String encodeTarget(ConnectionTarget target) => jsonEncode(target.toJson());

/// Reads back what [encodeTarget] wrote. Anything unreadable — a half-written
/// file, a hand-edited value — counts as "nothing stored", so the operator gets
/// the pairing screen rather than a crash on the way in.
ConnectionTarget? decodeTarget(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    return ConnectionTarget.fromJson(jsonDecode(text));
  } on FormatException {
    return null;
  }
}

/// In-memory store: the default in tests, and the honest fallback when a
/// platform has nowhere to write.
class MemoryEndpointStore implements EndpointStore {
  MemoryEndpointStore([this._target]);

  ConnectionTarget? _target;

  /// Saves so far, so a test can see what pairing wrote.
  int writes = 0;

  @override
  Future<ConnectionTarget?> load() async => _target;

  @override
  Future<void> save(ConnectionTarget target) async {
    _target = target;
    writes++;
  }

  @override
  Future<void> clear() async {
    _target = null;
  }
}
