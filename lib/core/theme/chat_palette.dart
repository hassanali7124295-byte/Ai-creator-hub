import 'package:flutter/material.dart';

/// Shared "Emerald + Graphite" palette used across the AI Chat experience —
/// the chat screen itself, the attachment sheet, and any other chat-scoped
/// widget that needs to match it exactly.
///
/// Extracted as its own helper (Step 11) so widgets like
/// `showAttachmentSheet` — which are shown via `context`s that sit *above*
/// [ChatScreen]'s local `Theme` override in the widget tree — can still
/// resolve the same emerald colors instead of falling back to the app-wide
/// purple `AppTheme`. [themeFor] only reads [Theme.of]'s brightness from the
/// given context; the seed color is always the emerald swatch below, so it
/// produces identical results regardless of where in the tree it's called.
class ChatPalette {
  ChatPalette._();

  // Step 12.1: lightened from emerald-600/emerald-400 to a softer,
  // more premium emerald-500/emerald-300 pairing — the old emerald-600
  // read as too dark/heavy against surfaces in both light and dark mode.
  static const Color emeraldLight = Color(0xFF10B981); // emerald-500
  static const Color emeraldDark = Color(0xFF6EE7B7); // emerald-300
  static const Color graphite = Color(0xFF37474F); // blue-graphite 800

  /// Step 12.4: a muted "sea green" used specifically for the user
  /// message bubble and the typing dot — noticeably lighter/softer than
  /// [emeraldLight], so the user's own messages read as gentle rather
  /// than a heavy solid block of saturated green. Deliberately the same
  /// in both light and dark mode, per spec.
  static const Color userBubble = Color(0xFF2E8B57);

  static ThemeData themeFor(BuildContext context) {
    final base = Theme.of(context);
    final isDark = base.brightness == Brightness.dark;

    final scheme = ColorScheme.fromSeed(
      seedColor: isDark ? emeraldDark : emeraldLight,
      brightness: base.brightness,
    ).copyWith(secondary: graphite);

    // Step 18.7: `base` (app_theme.dart's light/dark ThemeData) already has
    // its component themes — card, chip, input fields, dialogs, popup
    // menus, snackbars, dividers, etc. — pre-computed from the app-wide
    // (violet) colorScheme. A plain `base.copyWith(colorScheme: scheme)`
    // swaps the scheme but leaves those nested themes pointing at the old
    // colors, which is exactly what made Dark Mode look inconsistent here
    // (e.g. cards/inputs not matching the emerald surfaces). Rebuilding
    // each one from `scheme` keeps this whole subtree visually consistent
    // in both light and dark mode.
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: Colors.transparent,
        iconTheme: IconThemeData(color: scheme.onSurface),
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: scheme.surfaceContainerHigh,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: scheme.surfaceContainerHigh,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: base.elevatedButtonTheme.style?.copyWith(
          backgroundColor: WidgetStatePropertyAll(scheme.primary),
          foregroundColor: WidgetStatePropertyAll(scheme.onPrimary),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: base.outlinedButtonTheme.style?.copyWith(
          foregroundColor: WidgetStatePropertyAll(scheme.primary),
          side: WidgetStatePropertyAll(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
        titleTextStyle: base.dialogTheme.titleTextStyle?.copyWith(
          color: scheme.onSurface,
        ),
        contentTextStyle: base.dialogTheme.contentTextStyle?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: scheme.surfaceContainerHigh,
        modalBackgroundColor: scheme.surfaceContainerHigh,
      ),
      popupMenuTheme: base.popupMenuTheme.copyWith(
        color: scheme.surfaceContainerHigh,
        textStyle: base.popupMenuTheme.textStyle?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      snackBarTheme: base.snackBarTheme.copyWith(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: base.snackBarTheme.contentTextStyle?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
      ),
      dividerTheme: base.dividerTheme.copyWith(
        color: scheme.outlineVariant,
      ),
      listTileTheme: base.listTileTheme.copyWith(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
      drawerTheme: base.drawerTheme.copyWith(
        backgroundColor: scheme.surface,
        scrimColor: scheme.scrim.withOpacity(0.4),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withOpacity(0.3),
        selectionHandleColor: scheme.primary,
      ),
    );
  }

  /// Just the emerald [ColorScheme] for callers (like the attachment sheet)
  /// that only need colors, not a full [ThemeData].
  static ColorScheme colorSchemeFor(BuildContext context) =>
      themeFor(context).colorScheme;
}
