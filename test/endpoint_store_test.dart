import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/connection_target.dart';
import 'package:open_flutter/obs/endpoint_store.dart';
import 'package:open_flutter/obs/endpoint_store_io.dart';

const _target = ConnectionTarget(
  host: '192.168.1.20',
  port: 4466,
  password: 'hunter2',
);

void main() {
  group('MemoryEndpointStore', () {
    test('starts empty and remembers what is saved', () async {
      final store = MemoryEndpointStore();
      expect(await store.load(), isNull);
      await store.save(_target);
      expect(await store.load(), _target);
      expect(store.writes, 1);
      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  group('FileEndpointStore — the desktop store', () {
    late Directory dir;
    late FileEndpointStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('open_flutter_endpoint');
      store = FileEndpointStore(path: '${dir.path}/nested/obs_endpoint.json');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('creates the directory it needs, writes, and reads back', () async {
      await store.save(_target);
      expect(File(store.path).existsSync(), isTrue);
      expect(await store.load(), _target);
    });

    test('a file that is not there reads as nothing stored', () async {
      expect(await store.load(), isNull);
    });

    test('a hand-edited file reads as nothing stored, not a crash', () async {
      File(store.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('{"host": ""}');
      expect(await store.load(), isNull);

      File(store.path).writeAsStringSync('not json at all');
      expect(await store.load(), isNull);
    });

    test('clear removes it, and is safe to call twice', () async {
      await store.save(_target);
      await store.clear();
      await store.clear();
      expect(await store.load(), isNull);
    });
  });

  group('the stored encoding', () {
    test('is the same JSON both stores write', () {
      expect(
        encodeTarget(_target),
        '{"host":"192.168.1.20","port":4466,"password":"hunter2"}',
      );
      expect(decodeTarget(encodeTarget(_target)), _target);
    });

    test('garbage decodes to nothing stored', () {
      expect(decodeTarget(null), isNull);
      expect(decodeTarget(''), isNull);
      expect(decodeTarget('   '), isNull);
      expect(decodeTarget('{'), isNull);
      expect(decodeTarget('[1,2,3]'), isNull);
    });
  });
}
