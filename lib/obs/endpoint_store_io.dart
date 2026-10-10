import 'dart:io';

import 'connection_target.dart';
import 'endpoint_store.dart';

/// The desktop store: one small JSON file under the user's config directory.
EndpointStore createEndpointStore() => FileEndpointStore();

class FileEndpointStore implements EndpointStore {
  FileEndpointStore({String? path}) : path = path ?? defaultPath();

  /// Where the endpoint is kept. Injectable so tests can use a temp directory
  /// instead of the real config file.
  final String path;

  static String defaultPath() {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['XDG_CONFIG_HOME'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    return [base, 'open_flutter', 'obs_endpoint.json'].join(
      Platform.pathSeparator,
    );
  }

  File get _file => File(path);

  @override
  Future<ConnectionTarget?> load() async {
    try {
      if (!await _file.exists()) return null;
      return decodeTarget(await _file.readAsString());
    } on FileSystemException {
      // An unreadable config is not worth refusing to start over: the operator
      // gets the pairing screen and can point the app somewhere again.
      return null;
    }
  }

  @override
  Future<void> save(ConnectionTarget target) async {
    // Deliberately not swallowed: if the endpoint cannot be written, pairing
    // only lasts this session and the caller should say so.
    await _file.parent.create(recursive: true);
    await _file.writeAsString(encodeTarget(target), flush: true);
  }

  @override
  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }
}
