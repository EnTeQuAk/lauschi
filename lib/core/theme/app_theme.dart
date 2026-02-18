import 'package:flutter/material.dart';

abstract final class AppColors {
  // Brand
  static const primary = Color(0xFFFF6B6B); // warm coral — playful but not aggressive
  static const primaryDark = Color(0xFFE05555);
  static const accent = Color(0xFFFFD93D); // sunny yellow for highlights

  // Surfaces
  static const background = Color(0xFFF8F4EF); // warm off-white
  static const surface = Color(0xFFFFFFFF);
  static const surfaceCard = Color(0xFFFFFFFF);

  // Text
  static const textPrimary = Color(0xFF1A1A2E);
  static const textSecondary = Color(0xFF6B7280);
  static const textOnPrimary = Color(0xFFFFFFFF);

  // Semantic
  static const error = Color(0xFFEF4444);
  static const success = Color(0xFF22C55E);

  // Kid mode specific
  static const nowPlayingBorder = Color(0xFFFF6B6B);
}

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;

  // Touch targets — kids need big buttons
  static const minTouchTarget = 48.0;
  static const kidTouchTarget = 64.0;
}

abstract final class AppRadius {
  static const card = Radius.circular(16);
  static const button = Radius.circular(12);
  static const large = Radius.circular(24);
}

ThemeData buildAppTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.primary,
    onPrimary: AppColors.textOnPrimary,
    secondary: AppColors.accent,
    onSecondary: AppColors.textPrimary,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    error: AppColors.error,
    onError: AppColors.textOnPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Nunito', // will fall back to system sans-serif until we add the font
    cardTheme: const CardThemeData(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(AppRadius.card),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(AppSpacing.minTouchTarget, AppSpacing.minTouchTarget),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(AppRadius.button),
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(AppSpacing.kidTouchTarget, AppSpacing.kidTouchTarget),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: AppColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
