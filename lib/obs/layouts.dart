import 'obs_models.dart';

/// A shot the operator can pick when setting OBS up. Picking N of these builds
/// N scenes and gives the switcher N buttons.
class LayoutOption {
  const LayoutOption({
    required this.id,
    required this.label,
    required this.description,
    required this.layout,
    required this.sceneName,
  });

  final String id;

  /// Short name for the picker, e.g. "Side".
  final String label;

  /// What the shot is, shown under the tile's name.
  final String description;
  final CameraLayout layout;

  /// The OBS scene this option creates.
  final String sceneName;

  /// Slots keep position-based names (Camera A/B/C) because that is what the
  /// cue tags address — `[CAM 2]` means the second button, whatever it shows.
  CameraSlot toSlot(int index) => CameraSlot(
    id: String.fromCharCode(65 + index),
    label: 'Camera ${String.fromCharCode(65 + index)}',
    sceneName: sceneName,
    description: description,
    layout: layout,
  );
}

/// Everything the setup can build, in the order it is offered.
const List<LayoutOption> layoutOptions = [
  LayoutOption(
    id: 'full',
    label: 'Full',
    description: 'Webcam · full frame',
    layout: CameraLayout.fullBleed,
    sceneName: 'Full_Cam',
  ),
  LayoutOption(
    id: 'zoom',
    label: 'Zoom',
    description: 'Webcam · 130% digital zoom',
    layout: CameraLayout.zoomedBleed,
    sceneName: 'Zoom_Cam',
  ),
  LayoutOption(
    id: 'side',
    label: 'Side',
    description: 'Webcam · strip down the side',
    layout: CameraLayout.sideBleed,
    sceneName: 'Side_Cam',
  ),
  LayoutOption(
    id: 'bottom',
    label: 'Bottom',
    description: 'Webcam · box in the bottom corner',
    layout: CameraLayout.bottomPiP,
    sceneName: 'Bottom_Cam',
  ),
  LayoutOption(
    id: 'top',
    label: 'Top',
    description: 'Webcam · box in the top corner',
    layout: CameraLayout.topPiP,
    sceneName: 'Top_Cam',
  ),
];

/// How many shots one rig can have: the switcher has hotkeys 1..3 and a tile
/// per shot.
const int maxRigSize = 3;

/// The fewest we allow — one button that never changes shot is not a switcher.
const int minRigSize = 1;

/// Every scene name this app creates, i.e. the app's own namespace in OBS. A
/// from-scratch setup clears these and rebuilds the picked ones.
final Set<String> rigSceneNames = {
  for (final option in layoutOptions) option.sceneName,
};

LayoutOption? layoutOptionById(String id) {
  for (final option in layoutOptions) {
    if (option.id == id) return option;
  }
  return null;
}

LayoutOption? layoutOptionForScene(String sceneName) {
  final wanted = sceneName.toLowerCase();
  for (final option in layoutOptions) {
    if (option.sceneName.toLowerCase() == wanted) return option;
  }
  return null;
}

/// Reads a rig back out of OBS: the catalog scenes that exist, in catalog
/// order.
///
/// This is what makes a chosen rig survive a restart — otherwise every launch
/// would decide the configured shots are missing and offer the first-run setup
/// again.
List<CameraSlot> rigFromScenes(Iterable<String> sceneNames) {
  final present = {for (final name in sceneNames) name.toLowerCase()};
  final found = [
    for (final option in layoutOptions)
      if (present.contains(option.sceneName.toLowerCase())) option,
  ];
  final count = found.length < maxRigSize ? found.length : maxRigSize;
  return [for (var i = 0; i < count; i++) found[i].toSlot(i)];
}

/// Builds the slot list for a selection, in the order they were picked.
List<CameraSlot> slotsForLayoutIds(Iterable<String> ids) {
  final slots = <CameraSlot>[];
  for (final id in ids) {
    final option = layoutOptionById(id);
    if (option == null) continue;
    if (slots.length >= maxRigSize) break;
    slots.add(option.toSlot(slots.length));
  }
  return slots;
}
