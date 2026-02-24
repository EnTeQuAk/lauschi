import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Color system
//
// Forest green identity + warm cream backgrounds + terracotta accent.
// Album art is the hero — UI colors recede to let covers pop.
// ---------------------------------------------------------------------------

abstract final class AppColors {
  // Primary — forest green
  static const primary = Color(0xFF2D7A54);
  static const primarySoft = Color(0xFF5BA37D);
  static const primaryPale = Color(0xFFD4EDDF);

  // Accent — warm terracotta
  static const accent = Color(0xFFD4845A);
  static const accentPale = Color(0xFFFAEEE6);

  // Surfaces — warm cream, matched to mascot illustration background
  static const background = Color(0xFFF0EDE0);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceDim = Color(0xFFE7E3CE);
  static const surfaceTinted = Color(0xFFE8F2EB);

  // Parent mode surfaces — slightly cooler variant
  static const parentBackground = Color(0xFFEAE8DD);
  static const parentSurface = Color(0xFFF4F3EF);

  // Text
  static const textPrimary = Color(0xFF1A1E1C);
  static const textSecondary = Color(0xFF6B706D);
  static const textHint = Color(0xFFABAFAD);
  static const textOnPrimary = Color(0xFFFFFFFF);

  // Semantic
  static const error = Color(0xFFC44B3B);
  static const warning = Color(0xFFAA7A18);
  static const success = Color(0xFF2D7A54);
}

// ---------------------------------------------------------------------------
// Spacing — 4dp base unit
// ---------------------------------------------------------------------------

abstract final class AppSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;

  // Screen padding
  static const screenH = 20.0;

  // Touch targets
  static const minTouchTarget = 48.0;
  static const kidTouchTarget = 64.0;

  // Bottom padding to clear a FAB (56dp FAB + 16dp margin + 8dp buffer).
  static const fabClearance = 80.0;
}

/// Column count for kid-facing grids (series tiles, episode tiles).
/// Fewer columns = bigger tiles = easier to tap for small fingers.
/// Caps at 3 even on large landscape tablets to keep tiles recognizable.
int kidGridColumns(double width) => width < 600 ? 2 : 3;

// ---------------------------------------------------------------------------
// Radii — rounded organic feel
// ---------------------------------------------------------------------------

abstract final class AppRadius {
  static const card = Radius.circular(16);
  static const button = Radius.circular(12);
  static const sheet = Radius.circular(24);
  static const pill = Radius.circular(999);
}

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

ThemeData buildAppTheme() {
  const colorScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.primary,
    onPrimary: AppColors.textOnPrimary,
    primaryContainer: AppColors.primaryPale,
    onPrimaryContainer: AppColors.primary,
    secondary: AppColors.accent,
    onSecondary: AppColors.textOnPrimary,
    secondaryContainer: AppColors.accentPale,
    onSecondaryContainer: AppColors.accent,
    surface: AppColors.surface,
    onSurface: AppColors.textPrimary,
    onSurfaceVariant: AppColors.textSecondary,
    surfaceContainerHighest: AppColors.surfaceDim,
    error: AppColors.error,
    onError: AppColors.textOnPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Nunito',
    cardTheme: const CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(AppRadius.card),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(
          AppSpacing.minTouchTarget,
          AppSpacing.minTouchTarget,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(AppRadius.button),
        ),
        textStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w700,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(
          AppSpacing.minTouchTarget,
          AppSpacing.minTouchTarget,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(AppRadius.button),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        textStyle: const TextStyle(
          fontFamily: 'Nunito',
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(
          AppSpacing.kidTouchTarget,
          AppSpacing.kidTouchTarget,
        ),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Nunito',
        color: AppColors.textPrimary,
        fontSize: 28,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: AppRadius.sheet),
      ),
      showDragHandle: true,
      dragHandleColor: AppColors.surfaceDim,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.primary,
      linearTrackColor: AppColors.surfaceDim,
      linearMinHeight: 6,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + AppSpacing.xs,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(AppRadius.button),
        borderSide: BorderSide(color: AppColors.surfaceDim),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(AppRadius.button),
        borderSide: BorderSide(color: AppColors.surfaceDim),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(AppRadius.button),
        borderSide: BorderSide(color: AppColors.primary, width: 2),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.surfaceDim,
      thickness: 1,
      space: 1,
    ),
  );
}
