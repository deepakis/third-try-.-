import 'package:flutter_test/flutter_test.dart';
import 'package:open_flutter/app_config.dart';
import 'package:open_flutter/obs/layouts.dart';

void main() {
  test('every shot has its own id, scene and framing', () {
    expect(
      layoutOptions.map((option) => option.id).toSet(),
      hasLength(layoutOptions.length),
    );
    expect(
      layoutOptions.map((option) => option.sceneName).toSet(),
      hasLength(layoutOptions.length),
    );
    expect(
      layoutOptions.map((option) => option.layout).toSet(),
      hasLength(layoutOptions.length),
    );
  });

  test('the config default is the catalog selection it claims to be', () {
    final built = slotsForLayoutIds(const ['full', 'zoom']);

    expect(built, hasLength(AppConfig.cameras.length));
    for (var i = 0; i < built.length; i++) {
      expect(built[i].id, AppConfig.cameras[i].id);
      expect(built[i].label, AppConfig.cameras[i].label);
      expect(built[i].sceneName, AppConfig.cameras[i].sceneName);
      expect(built[i].description, AppConfig.cameras[i].description);
      expect(built[i].layout, AppConfig.cameras[i].layout);
    }
  });

  test('slots are named by position, so cue tags keep their meaning', () {
    final slots = slotsForLayoutIds(const ['top', 'bottom', 'side']);

    expect(slots.map((slot) => slot.id).toList(), ['A', 'B', 'C']);
    expect(
      slots.map((slot) => slot.label).toList(),
      ['Camera A', 'Camera B', 'Camera C'],
    );
  });

  test('never builds more shots than the switcher has keys for', () {
    final slots = slotsForLayoutIds(
      layoutOptions.map((option) => option.id).toList(),
    );

    expect(slots, hasLength(maxRigSize));
    expect(slots.map((slot) => slot.sceneName).toList(), [
      'Full_Cam',
      'Zoom_Cam',
      'Side_Cam',
    ]);
  });

  test('skips an unknown id instead of dropping the whole rig', () {
    final slots = slotsForLayoutIds(const ['nope', 'zoom']);

    expect(slots, hasLength(1));
    expect(slots.single.sceneName, 'Zoom_Cam');
    expect(slots.single.id, 'A');
  });

  group('rigFromScenes', () {
    test('reads the rig back out of OBS in catalog order', () {
      final slots = rigFromScenes(['Bottom_Cam', 'Side_Cam', 'Scene']);

      // Picked first / picked second is not recoverable from a scene list, so
      // the catalog order is the rule.
      expect(slots.map((slot) => slot.sceneName).toList(), [
        'Side_Cam',
        'Bottom_Cam',
      ]);
      expect(slots.map((slot) => slot.id).toList(), ['A', 'B']);
    });

    test('ignores scenes that are not the app\'s own', () {
      expect(rigFromScenes(const ['Camera A', 'Scene']), isEmpty);
    });

    test('caps at the number of keys', () {
      final slots = rigFromScenes(rigSceneNames);

      expect(slots, hasLength(maxRigSize));
    });

    test('matches case-insensitively, the way resolveTargets does', () {
      expect(rigFromScenes(const ['zoom_cam']).single.sceneName, 'Zoom_Cam');
    });
  });
}
