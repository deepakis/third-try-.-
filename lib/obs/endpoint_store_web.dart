import 'package:web/web.dart' as web;

import 'connection_target.dart';
import 'endpoint_store.dart';

/// The web store: `localStorage`, so it is per origin and per browser profile —
/// which is exactly the machine you are sitting at.
///
/// This uses `package:web` rather than `dart:html`. `dart:html` is deprecated,
/// and a Flutter *app* (as opposed to a web plugin package) is told not to
/// import it at all — `avoid_web_libraries_in_flutter`. `package:web` is an
/// ordinary package with no such rule, and its `Storage` methods take and
/// return plain Dart strings, so nothing here needs `dart:js_interop` either.
EndpointStore createEndpointStore() => WebEndpointStore();

/// One key, holding the same JSON the desktop store writes to its file.
const String endpointStorageKey = 'open_flutter.obs_endpoint';

class WebEndpointStore implements EndpointStore {
  @override
  Future<ConnectionTarget?> load() async =>
      decodeTarget(web.window.localStorage.getItem(endpointStorageKey));

  @override
  Future<void> save(ConnectionTarget target) async {
    // Throws when storage is full or blocked (a private window, or "block
    // cookies" settings); the caller reports it rather than losing the pairing
    // quietly.
    web.window.localStorage.setItem(endpointStorageKey, encodeTarget(target));
  }

  @override
  Future<void> clear() async {
    web.window.localStorage.removeItem(endpointStorageKey);
  }
}
