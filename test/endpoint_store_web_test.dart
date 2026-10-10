@TestOn('browser')
// Runs only under a browser platform:
//
//   flutter test --platform chrome test/endpoint_store_web_test.dart
//
// It exercises the one part of pairing that cannot be checked on the VM: that
// `package:web`'s localStorage calls really store and return the endpoint, and
// that the key the app writes is the key it reads. The VM runner skips it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/connection_target.dart';
import 'package:open_flutter/obs/endpoint_store_web.dart';

const _target = ConnectionTarget(
  host: '192.168.1.20',
  port: 4466,
  password: 'hunter2',
);

void main() {
  test('stores the paired endpoint in localStorage and reads it back', () async {
    final store = WebEndpointStore();
    await store.clear();
    expect(await store.load(), isNull, reason: 'nothing paired yet');

    await store.save(_target);
    expect(
      await store.load(),
      _target,
      reason: 'a reload must find what pairing wrote',
    );

    await store.clear();
    expect(await store.load(), isNull);
  });

  test('survives a second store instance, the way a reload does', () async {
    await WebEndpointStore().save(_target);
    addTearDown(() => WebEndpointStore().clear());

    // A fresh instance is what a page reload builds: no shared state, same
    // localStorage.
    expect(await WebEndpointStore().load(), _target);
  });
}
