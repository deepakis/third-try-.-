import 'obs/connection_target.dart';
import 'obs/obs_models.dart';

/// Connection + operator setup for the switcher.
///
/// The endpoint and password can be overridden at build time, which is how the
/// app is pointed at the offline fake server in `tools/fake_obs.mjs`:
///
///   flutter run -d web-server --dart-define=OBS_HOST=127.0.0.1
///
/// Defaults target the OBS box on the local network.
class AppConfig {
  const AppConfig._();

  static const String obsHost = String.fromEnvironment(
    'OBS_HOST',
    defaultValue: '10.82.181.253',
  );
  static const int obsPort = int.fromEnvironment('OBS_PORT', defaultValue: 4455);
  static const String obsPassword = String.fromEnvironment(
    'OBS_PASSWORD',
    defaultValue: 'C8RsC84pViTVESA5',
  );

  /// True when this build was aimed at an OBS on the command line, with
  /// `--dart-define=OBS_HOST=…` or `OBS_PASSWORD=…`.
  ///
  /// The defines are read a second time with an empty default, because that is
  /// the only way to tell "this build was pointed at 127.0.0.1" from "nobody
  /// aimed this build anywhere" — and only the first deserves to prefill the
  /// pairing screen.
  ///
  /// A getter, not a `const`: `isNotEmpty` on a String is not a constant
  /// operation, so the compiler rejects it in a const initialiser.
  static bool get fromEnvironment =>
      _envHost.isNotEmpty || _envPassword.isNotEmpty;

  static const String _envHost = String.fromEnvironment('OBS_HOST');
  static const String _envPassword = String.fromEnvironment('OBS_PASSWORD');

  /// The endpoint this build falls back to when nothing has been paired yet.
  ///
  /// Pairing writes a chosen endpoint to local storage and takes over from this;
  /// the values above are the seed, not the rule.
  static ConnectionTarget get defaultTarget => ConnectionTarget(
    host: obsHost,
    port: obsPort,
    password: obsPassword,
  );

  static Uri get obsUri => Uri.parse('ws://$obsHost:$obsPort/');

  /// Boot straight into the teleprompter instead of the switcher. Used to
  /// record the demo, and by kiosk builds that only ever prompt:
  ///
  ///   flutter run -d web-server --dart-define=START_SCREEN=prompter
  static const bool startOnPrompter =
      String.fromEnvironment('START_SCREEN', defaultValue: 'switcher') ==
      'prompter';

  /// How often tile preview thumbnails are pulled from OBS.
  static const Duration previewInterval = Duration(seconds: 2);

  /// The shots the switcher starts with — the default selection from the picker
  /// catalog in `obs/layouts.dart`.
  ///
  /// These are a starting point, not a constraint: the operator can pick any
  /// combination of shots at first run, and the switcher then follows whatever
  /// rig OBS actually holds. `sceneName` is what OBS calls the scene, and
  /// `layout` tells the setup how to place the camera in it.
  static const List<CameraSlot> cameras = [
    CameraSlot(
      id: 'A',
      label: 'Camera A',
      sceneName: 'Full_Cam',
      description: 'Webcam · full frame',
      layout: CameraLayout.fullBleed,
    ),
    CameraSlot(
      id: 'B',
      label: 'Camera B',
      sceneName: 'Zoom_Cam',
      description: 'Webcam · 130% digital zoom',
      layout: CameraLayout.zoomedBleed,
    ),
  ];
}
