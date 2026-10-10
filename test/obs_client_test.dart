import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/obs/obs_client.dart';
import 'package:open_flutter/obs/obs_models.dart';

void main() {
  // These strings are the ones dart:io and a browser actually produce. The
  // classifier matches on text rather than on `SocketException` because
  // `dart:io` does not exist in the web build, so the phrasings are the
  // contract — and a forced password mistake must never be confused with an
  // unreachable one, because the fixes have nothing in common.
  group('classifyConnectError', () {
    test('a wrong password is left to the close code, not guessed here', () {
      // Nothing about a refused *password* passes through this function: that
      // arrives as a 4009 close, long after the socket is up.
      expect(
        ObsClient.classifyConnectError(Exception('connection reset by peer')),
        ObsFailure.unreachable,
      );
    });

    test('a port with nothing on it reads as refused, on every wording', () {
      // Windows.
      expect(
        ObsClient.classifyConnectError(
          Exception(
            'SocketException: Connection refused (OS Error: Connection refused, '
            'errno = 10061)',
          ),
        ),
        ObsFailure.refused,
      );
      // Linux and macOS share their wording with Windows' errno name.
      expect(
        ObsClient.classifyConnectError(Exception('Connection refused')),
        ObsFailure.refused,
      );
      // dart:io when something *is* listening but is not obs-websocket.
      expect(
        ObsClient.classifyConnectError(
          Exception(
            "WebSocketException: Connection to 'http://127.0.0.1:1/' was not "
            'upgraded to websocket',
          ),
        ),
        ObsFailure.refused,
      );
    });

    test('a host that never answers reads as unreachable', () {
      expect(
        ObsClient.classifyConnectError(
          Exception('SocketException: Failed host lookup: obs.local'),
        ),
        ObsFailure.unreachable,
      );
      expect(
        ObsClient.classifyConnectError(Exception('Network is unreachable')),
        ObsFailure.unreachable,
      );
    });

    test('a blocked ws:// socket from an https page is its own failure', () {
      // What a browser throws before any request leaves the page.
      expect(
        ObsClient.classifyConnectError(
          Exception(
            'SecurityError: An insecure WebSocket connection may not be '
            'initiated from a page loaded over HTTPS.',
          ),
        ),
        ObsFailure.mixedContent,
      );
    });
  });

  group('ObsStatus', () {
    test('a failure makes an attempt settled, so nothing waits forever', () {
      const failed = ObsStatus(
        ObsConnectionState.disconnected,
        detail: 'unreachable',
        failure: ObsFailure.unreachable,
      );
      expect(failed.failed, isTrue);
      expect(failed.isConnected, isFalse);

      const connecting = ObsStatus(ObsConnectionState.connecting);
      expect(connecting.failed, isFalse);
      expect(connecting.isConnected, isFalse);
    });

    test('a wrong password is not reachable, and says so in its detail', () {
      const rejected = ObsStatus(
        ObsConnectionState.disconnected,
        detail: 'password rejected by OBS',
        failure: ObsFailure.wrongPassword,
      );
      expect(rejected.failure, isNot(ObsFailure.unreachable));
      expect(rejected.label, contains('password'));
    });
  });
}
