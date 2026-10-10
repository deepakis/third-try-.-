import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/connection_target.dart';

void main() {
  group('ConnectionTarget.parse — the line OBS shows', () {
    test('reads the obs-websocket 5.0.0+ form', () {
      final target = ConnectionTarget.parse(
        'obsws://192.168.1.20:4455/hunter2',
      );
      expect(
        target,
        const ConnectionTarget(
          host: '192.168.1.20',
          port: 4455,
          password: 'hunter2',
        ),
      );
      expect(target!.uri, Uri.parse('ws://192.168.1.20:4455/'));
    });

    test('reads the pre-5.0.0 pipe form', () {
      expect(
        ConnectionTarget.parse('obswebsocket|10.0.0.5:4466|hunter2'),
        const ConnectionTarget(
          host: '10.0.0.5',
          port: 4466,
          password: 'hunter2',
        ),
      );
    });

    test('the pipe form survives a missing password', () {
      expect(
        ConnectionTarget.parse('obswebsocket|10.0.0.5:4466'),
        const ConnectionTarget(host: '10.0.0.5', port: 4466),
      );
    });

    test('takes everything after the slash as the password, verbatim', () {
      // A password can hold a '/' or a '#'; a real URI parser would read those
      // as a path separator or a fragment, which is why the line is split by
      // hand.
      expect(
        ConnectionTarget.parse('obsws://127.0.0.1:4455/a/b#c')!.password,
        'a/b#c',
      );
    });

    test('a trailing slash with nothing after it means no password', () {
      expect(ConnectionTarget.parse('obsws://127.0.0.1:4455/')!.password, '');
      expect(ConnectionTarget.parse('obsws://127.0.0.1:4455')!.password, '');
    });

    test('strips the quotes a paste from chat brings along', () {
      expect(
        ConnectionTarget.parse('"obsws://10.0.0.5:4455/hunter2"'),
        const ConnectionTarget(
          host: '10.0.0.5',
          port: 4455,
          password: 'hunter2',
        ),
      );
    });

    test('keeps the port OBS reports rather than assuming the default', () {
      expect(ConnectionTarget.parse('obsws://10.0.0.5:4959/hunter2')!.port, 4959);
    });

    test('handles a bracketed IPv6 host', () {
      final target = ConnectionTarget.parse('obsws://[fe80::1]:4455/hunter2');
      expect(
        target,
        const ConnectionTarget(host: 'fe80::1', password: 'hunter2'),
      );
      // What the client actually dials: the brackets are the URI's job to
      // re-add, and the address must survive as written.
      expect(target!.uri.host, 'fe80::1');
      expect(target.uri.port, 4455);
      expect(target.uri.scheme, 'ws');
    });

    test('normalizes the TLS scheme that OBS Studio never serves', () {
      final target = ConnectionTarget.parse('obswss://obs.local:4455/hunter2');
      expect(target!.host, 'obs.local');
      expect(target.uri.scheme, 'ws', reason: 'OBS ships no TLS listener');
    });
  });

  group('ConnectionTarget.parse — what a human types', () {
    test('a bare host:port', () {
      expect(
        ConnectionTarget.parse('192.168.1.20:4455'),
        const ConnectionTarget(host: '192.168.1.20', port: 4455),
      );
    });

    test('a bare host, with the port defaulted', () {
      expect(
        ConnectionTarget.parse('  obs.local  '),
        const ConnectionTarget(host: 'obs.local', port: 4455),
      );
    });

    test('a ws:// URL someone copied out of another tool', () {
      expect(
        ConnectionTarget.parse('ws://127.0.0.1:4455/')!.host,
        '127.0.0.1',
      );
    });
  });

  group('ConnectionTarget.parse — refusing nonsense', () {
    test('empty or whitespace is not an address', () {
      expect(ConnectionTarget.parse(''), isNull);
      expect(ConnectionTarget.parse('   '), isNull);
      expect(ConnectionTarget.parse('""'), isNull);
    });

    test('prose is not an address', () {
      expect(ConnectionTarget.parse('Connect to OBS on my desktop'), isNull);
      expect(ConnectionTarget.parse('obsws://'), isNull);
      expect(ConnectionTarget.parse(':'), isNull);
    });

    test('a port that is not a port is not an address', () {
      expect(ConnectionTarget.parse('192.168.1.20:http'), isNull);
      expect(ConnectionTarget.parse('obsws://192.168.1.20:0/pw'), isNull);
      expect(ConnectionTarget.parse('obsws://192.168.1.20:99999/pw'), isNull);
    });
  });

  group('the stored form', () {
    test('round-trips', () {
      const target = ConnectionTarget(
        host: '10.0.0.5',
        port: 4959,
        password: 'hunter2',
      );
      expect(ConnectionTarget.fromJson(target.toJson()), target);
    });

    test('reads a half-written entry as nothing stored', () {
      expect(ConnectionTarget.fromJson(const {'port': 4455}), isNull);
      expect(ConnectionTarget.fromJson(const {'host': ''}), isNull);
      expect(ConnectionTarget.fromJson(const {'host': 5}), isNull);
      expect(ConnectionTarget.fromJson('not a map'), isNull);
    });

    test('a nonsense port falls back to the default', () {
      expect(
        ConnectionTarget.fromJson(const {
          'host': '10.0.0.5',
          'port': '4455',
        }),
        const ConnectionTarget(host: '10.0.0.5'),
      );
    });
  });
}
