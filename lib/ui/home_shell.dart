import 'package:flutter/material.dart';

import '../app_config.dart';
import '../obs/obs_client.dart';
import '../obs/obs_models.dart';
import '../teleprompter/teleprompter_screen.dart';
import 'setup_page.dart';
import 'switcher_screen.dart';
import 'theme.dart';

/// The three pages of the app, behind one navigation bar:
///
///   * Cameras  — the switcher: tiles, cuts, and the first-run setup card
///   * Prompter — the teleprompter, which follows the shots on the Cameras page
///   * Setup    — the OBS connection and the keys and cues to know
///
/// The pages live in an [IndexedStack], so switching tabs keeps each one's state
/// (a half-finished setup, the scroll position). Only the visible page is allowed
/// to animate, though: a hidden prompter must not keep scrolling and firing cues.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.connection,
    this.endpoint,
    this.onPair,
    this.wizard = WizardMode.off,
    this.initialIndex = 0,
  });

  final ObsConnection connection;

  /// The OBS this session is pointed at, shown on the Cameras and Setup pages.
  final String? endpoint;

  /// Opens the pairing screen to change the OBS.
  final VoidCallback? onPair;

  /// How much of the first-run wizard the switcher runs.
  final WizardMode wizard;

  /// 0 = Cameras, 1 = Prompter, 2 = Setup.
  final int initialIndex;

  static const int camerasPage = 0;
  static const int prompterPage = 1;
  static const int setupPage = 2;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialIndex;

  /// The shots on the Cameras page. The Prompter re-reads its cues against them.
  final ValueNotifier<List<CameraSlot>> _slots = ValueNotifier(
    AppConfig.cameras,
  );

  @override
  void dispose() {
    _slots.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final pages = IndexedStack(
      index: _index,
      children: [
        TickerMode(
          enabled: _index == HomeShell.camerasPage,
          child: SwitcherScreen(
            connection: widget.connection,
            endpoint: widget.endpoint,
            onPair: widget.onPair,
            wizard: widget.wizard,
            onOpenPrompter: () => _select(HomeShell.prompterPage),
            onSlotsChanged: (slots) => _slots.value = slots,
          ),
        ),
        TickerMode(
          enabled: _index == HomeShell.prompterPage,
          child: ValueListenableBuilder<List<CameraSlot>>(
            valueListenable: _slots,
            builder: (context, slots, _) => TeleprompterScreen(
              connection: widget.connection,
              slots: slots,
              embedded: true,
            ),
          ),
        ),
        TickerMode(
          enabled: _index == HomeShell.setupPage,
          child: SetupPage(
            connection: widget.connection,
            endpoint: widget.endpoint,
            onPair: widget.onPair,
          ),
        ),
      ],
    );

    // The prompter is a dark page: its navigation goes dark with it, so the
    // bar does not sit on it as a bright strip.
    final dark = _index == HomeShell.prompterPage;

    if (wide) {
      return Scaffold(
        backgroundColor: dark ? AppColors.prompterBackground : AppColors.background,
        body: Row(
          children: [
            NavigationRailTheme(
              data: _railTheme(dark),
              child: NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _select,
                labelType: NavigationRailLabelType.all,
                leading: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: _AppMark(),
                ),
                destinations: [
                  for (final page in _pages)
                    NavigationRailDestination(
                      icon: Icon(page.icon),
                      selectedIcon: Icon(page.selectedIcon),
                      label: Text(page.label),
                    ),
                ],
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: dark ? AppColors.prompterBorder : AppColors.border,
            ),
            Expanded(child: pages),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: dark ? AppColors.prompterBackground : AppColors.background,
      body: pages,
      bottomNavigationBar: NavigationBarTheme(
        data: _barTheme(dark),
        child: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: [
            for (final page in _pages)
              NavigationDestination(
                icon: Icon(page.icon),
                selectedIcon: Icon(page.selectedIcon),
                label: page.label,
              ),
          ],
        ),
      ),
    );
  }

  static const List<_Page> _pages = [
    _Page('Cameras', Icons.videocam_outlined, Icons.videocam_rounded),
    _Page('Prompter', Icons.article_outlined, Icons.article_rounded),
    _Page('Setup', Icons.tune_outlined, Icons.tune_rounded),
  ];

  static NavigationBarThemeData _barTheme(bool dark) {
    final ink = dark ? AppColors.prompterText : AppColors.ink;
    final muted = dark ? AppColors.prompterDim : AppColors.muted;
    return NavigationBarThemeData(
      backgroundColor: dark ? AppColors.prompterBackground : AppColors.background,
      surfaceTintColor: Colors.transparent,
      indicatorColor: dark ? AppColors.prompterSurface : AppColors.surface,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: states.contains(WidgetState.selected) ? ink : muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? ink : muted,
        ),
      ),
    );
  }

  static NavigationRailThemeData _railTheme(bool dark) {
    final ink = dark ? AppColors.prompterText : AppColors.ink;
    final muted = dark ? AppColors.prompterDim : AppColors.muted;
    return NavigationRailThemeData(
      backgroundColor: dark ? AppColors.prompterBackground : AppColors.background,
      indicatorColor: dark ? AppColors.prompterSurface : AppColors.surface,
      selectedIconTheme: IconThemeData(color: ink),
      unselectedIconTheme: IconThemeData(color: muted),
      selectedLabelTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: ink,
      ),
      unselectedLabelTextStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: muted,
      ),
    );
  }
}

class _Page {
  const _Page(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The app's name in the rail, above the pages.
class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'OF',
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: -0.4,
        ),
      ),
    );
  }
}
