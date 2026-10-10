import 'package:flutter/material.dart';

/// One restrained palette: white canvas, near-black ink, a single red for "live".
class AppColors {
  const AppColors._();

  static const Color background = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF101014);
  static const Color muted = Color(0xFF71717A);
  static const Color border = Color(0xFFE4E4E7);
  static const Color surface = Color(0xFFF7F7F8);
  static const Color live = Color(0xFFE11D48);
  static const Color success = Color(0xFF16A34A);
  static const Color warn = Color(0xFFB45309);
  static const Color warnSurface = Color(0xFFFEF3C7);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSurface = Color(0xFFFEF2F2);

  // Teleprompter: a dark reading surface, because the presenter stares at it
  // while a camera stares at them.
  static const Color prompterBackground = Color(0xFF0B0B0F);
  static const Color prompterSurface = Color(0xFF17171D);
  static const Color prompterBorder = Color(0xFF2A2A33);
  static const Color prompterText = Color(0xFFF4F4F5);
  static const Color prompterDim = Color(0xFF8A8A93);

  /// The reading line, and any cue tag in the script.
  static const Color cue = Color(0xFFFF3B30);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.ink,
      brightness: Brightness.light,
      surface: AppColors.background,
    ),
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.ink,
      displayColor: AppColors.ink,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.white
            : Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? AppColors.ink
            : const Color(0xFFD4D4D8),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: AppColors.ink),
    ),
  );
}
