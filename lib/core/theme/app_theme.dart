import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Centralized theme configuration for Pak AI.
///
/// Design language: modern "premium AI product" look —
/// emerald green primary, soft rounded cards, subtle elevation,
/// and clean typography (Poppins/Inter via Google Fonts).
///
/// Step 18.5: the app's whole palette (light and dark) is now green /
/// white / black / gray only — the old violet primary and cyan-teal
/// secondary both read as blue, so both were replaced with shades of the
/// same emerald green [ChatPalette] already uses, keeping the app-wide
/// theme and the chat screen's own palette visually consistent.
class AppTheme {
  AppTheme._();

  // Brand colors — emerald green, matching ChatPalette's swatch.
  static const Color primaryLight = Color(0xFF0E9F6E); // emerald-600
  static const Color secondaryLight = Color(0xFF6B7280); // neutral gray-500
  static const Color primaryDark = Color(0xFF6EE7B7); // emerald-300
  static const Color secondaryDark = Color(0xFF9CA3AF); // neutral gray-400

  static const double borderRadius = 20.0;

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryLight,
      secondary: secondaryLight,
      brightness: Brightness.light,
    );

    return _buildTheme(colorScheme);
  }

  static ThemeData get darkTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primaryDark,
      secondary: secondaryDark,
      brightness: Brightness.dark,
    );

    return _buildTheme(colorScheme);
  }

  static ThemeData _buildTheme(ColorScheme colorScheme) {
    final baseTextTheme = GoogleFonts.interTextTheme();
    final headlineFont = GoogleFonts.poppinsTextTheme();

    final textTheme = baseTextTheme.copyWith(
      headlineLarge: headlineFont.headlineLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineMedium: headlineFont.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      headlineSmall: headlineFont.headlineSmall?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleLarge: headlineFont.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      titleMedium: headlineFont.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
        ),
        iconTheme: IconThemeData(color: colorScheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        margin: EdgeInsets.zero,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        labelStyle: textTheme.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(50),
        ),
        side: BorderSide.none,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: textTheme.titleMedium,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 72,
        // Step 12.2: a fuller, softer indicator pill (was the Material
        // default oval) plus a touch more label weight for a more
        // premium, less "stock" Material 3 feel.
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        indicatorColor: colorScheme.primary.withOpacity(0.15),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            letterSpacing: 0.1,
            color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
          );
        }),
      ),
      splashFactory: InkRipple.splashFactory,
    );
  }
}
