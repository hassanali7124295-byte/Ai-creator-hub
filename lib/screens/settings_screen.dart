import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/theme_provider.dart';
import '../core/services/gemini_service.dart';
import '../core/theme/chat_palette.dart';
import 'about_screen.dart';
import 'privacy_policy_screen.dart';

/// Settings screen — theme switcher, Gemini API key management, and about.
///
/// Step 18.6A: every accent color below is read directly from
/// [ChatPalette]'s emerald [ColorScheme] and passed explicitly into each
/// widget (button, selected state, heading, focus border, cursor,
/// selection) instead of only being inherited through an ambient [Theme].
/// This guarantees the emerald brand color — never the app-wide violet
/// [AppTheme] — is what actually renders here, in both Light and Dark
/// mode. No storage, navigation, or provider logic changed.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _isLoadingKey = true;
  bool _hasSavedKey = false;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final key = await GeminiService.getApiKey();
    if (!mounted) return;
    setState(() {
      _apiKeyController.text = key ?? '';
      _hasSavedKey = key != null && key.trim().isNotEmpty;
      _isLoadingKey = false;
    });
  }

  Future<void> _saveApiKey() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) {
      await GeminiService.clearApiKey();
    } else {
      await GeminiService.setApiKey(key);
    }
    if (!mounted) return;
    setState(() => _hasSavedKey = key.isNotEmpty);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(key.isEmpty ? 'API key removed' : 'API key saved'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  static String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System default';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  static String _themeModeSubtitle(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Match your device setting';
      case ThemeMode.light:
        return 'Always use the light theme';
      case ThemeMode.dark:
        return 'Always use the dark theme';
    }
  }

  static IconData _themeModeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return Icons.brightness_auto_rounded;
      case ThemeMode.light:
        return Icons.light_mode_rounded;
      case ThemeMode.dark:
        return Icons.dark_mode_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Same premium emerald palette the chat screen uses, instead of the
    // app-wide violet AppTheme — see the class doc above. `scheme` is read
    // once here and threaded explicitly into every widget below that needs
    // an accent color, rather than each one re-resolving it independently.
    final theme = ChatPalette.themeFor(context);
    final scheme = theme.colorScheme;
    final themeProvider = context.watch<ThemeProvider>();

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          leadingWidth: 56,
          scrolledUnderElevation: 0,
          leading: Center(
            child: _RoundedBackButton(
              scheme: scheme,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          title: Text(
            'Settings',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: scheme.onSurface,
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            _SectionLabel('Gemini API Key', color: scheme.primary),
            _SettingsCard(
              scheme: scheme,
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: _isLoadingKey
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: scheme.primary,
                          ),
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _hasSavedKey
                                    ? Icons.check_circle_rounded
                                    : Icons.info_outline_rounded,
                                size: 18,
                                color: _hasSavedKey
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                _hasSavedKey
                                    ? 'Key saved on this device'
                                    : 'No key saved yet',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w500,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _apiKeyController,
                            obscureText: _obscureKey,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: scheme.onSurface),
                            cursorColor: scheme.primary,
                            decoration: InputDecoration(
                              hintText: 'Paste your Gemini API key',
                              filled: true,
                              fillColor: scheme.surfaceContainerHighest,
                              prefixIcon: Icon(
                                Icons.key_rounded,
                                size: 20,
                                color: scheme.onSurfaceVariant,
                              ),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscureKey
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  size: 20,
                                  color: scheme.onSurfaceVariant,
                                ),
                                onPressed: () =>
                                    setState(() => _obscureKey = !_obscureKey),
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
                                borderSide: BorderSide(
                                  color: scheme.primary,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Get a free key at aistudio.google.com/app/apikey. '
                            'It\'s stored only on this device and used solely to '
                            'talk to Gemini from the AI Chat screen.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _saveApiKey,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: scheme.primary,
                                foregroundColor: scheme.onPrimary,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 0,
                              ),
                              child: const Text(
                                'Save API Key',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 28),
            _SectionLabel('Appearance', color: scheme.primary),
            _SettingsCard(
              scheme: scheme,
              child: Column(
                children: [
                  // Quick toggle — same ThemeProvider.toggleTheme() call
                  // as before, just given its own switch instead of only
                  // being reachable through the three tiles below.
                  _SettingsTile(
                    scheme: scheme,
                    leadingIcon: Icons.dark_mode_rounded,
                    title: 'Dark Mode',
                    subtitle: themeProvider.isDarkMode ? 'On' : 'Off',
                    trailing: Switch(
                      value: themeProvider.isDarkMode,
                      activeColor: scheme.primary,
                      activeTrackColor: scheme.primary.withOpacity(0.35),
                      onChanged: (_) => themeProvider.toggleTheme(),
                    ),
                    onTap: themeProvider.toggleTheme,
                  ),
                  _SettingsDivider(scheme: scheme),
                  for (final mode in ThemeMode.values) ...[
                    if (mode != ThemeMode.values.first)
                      _SettingsDivider(scheme: scheme),
                    _ThemeModeTile(
                      scheme: scheme,
                      icon: _themeModeIcon(mode),
                      title: _themeModeLabel(mode),
                      subtitle: _themeModeSubtitle(mode),
                      selected: themeProvider.themeMode == mode,
                      onTap: () => themeProvider.setThemeMode(mode),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 28),
            _SectionLabel('About', color: scheme.primary),
            _SettingsCard(
              scheme: scheme,
              child: Column(
                children: [
                  _SettingsTile(
                    scheme: scheme,
                    leadingIcon: Icons.info_outline_rounded,
                    title: 'About Pak AI',
                    subtitle: 'Version 1.0.0',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AboutScreen()),
                    ),
                  ),
                  _SettingsDivider(scheme: scheme),
                  _SettingsTile(
                    scheme: scheme,
                    leadingIcon: Icons.privacy_tip_outlined,
                    title: 'Privacy Policy',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PrivacyPolicyScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A rounded, low-emphasis back button matching the chat screen's app-bar
/// icon buttons — soft surface-tinted circle, no blue tint, subtle press
/// scale. Kept local to this screen since the chat screen's own version is
/// private to that file. Takes the emerald [ColorScheme] explicitly so its
/// colors never depend on ambient Theme resolution.
class _RoundedBackButton extends StatefulWidget {
  final ColorScheme scheme;
  final VoidCallback onTap;
  const _RoundedBackButton({required this.scheme, required this.onTap});

  @override
  State<_RoundedBackButton> createState() => _RoundedBackButtonState();
}

class _RoundedBackButtonState extends State<_RoundedBackButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    return Tooltip(
      message: 'Back',
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.90 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Material(
            color: scheme.surfaceContainerHigh.withOpacity(0.7),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(9),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 21,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Section header — takes its color explicitly from the caller (the
/// emerald `scheme.primary`) instead of resolving it internally, so it
/// always renders as Pak AI green regardless of where in the tree it sits.
class _SectionLabel extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionLabel(this.label, {required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// A large, rounded, softly-shadowed card — the shared container every
/// settings section sits in. Takes the emerald [ColorScheme] explicitly so
/// its fill is always correct in both Light and Dark mode — never a
/// hardcoded, and never a stray white/black, color.
class _SettingsCard extends StatelessWidget {
  final ColorScheme scheme;
  final Widget child;
  const _SettingsCard({required this.scheme, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = scheme.brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withOpacity(0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withOpacity(isDark ? 0.0 : 0.05),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A thin, inset divider between tiles inside a [_SettingsCard] — replaces
/// the default full-bleed [Divider] so it reads as separating rows within
/// one rounded card rather than cutting across it. Colored explicitly from
/// the emerald [ColorScheme].
class _SettingsDivider extends StatelessWidget {
  final ColorScheme scheme;
  const _SettingsDivider({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: 62,
      endIndent: 16,
      color: scheme.outlineVariant.withOpacity(0.3),
    );
  }
}

/// A premium Material 3 settings row: leading icon in a soft tinted circle,
/// title, optional subtitle, and either a supplied [trailing] widget or a
/// chevron. Takes the emerald [ColorScheme] explicitly so its accent color
/// is always Pak AI green in both Light and Dark mode.
class _SettingsTile extends StatelessWidget {
  final ColorScheme scheme;
  final IconData leadingIcon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.scheme,
    required this.leadingIcon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  leadingIcon,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  Icon(
                    Icons.chevron_right_rounded,
                    color: scheme.onSurfaceVariant.withOpacity(0.6),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row of the "Appearance" theme-mode picker (System/Light/Dark) —
/// visually distinct from [_SettingsTile] with a filled/selected state
/// instead of a chevron, but wired to the exact same
/// `ThemeProvider.setThemeMode` call the old [RadioListTile] used. Takes
/// the emerald [ColorScheme] explicitly so the selected state is always
/// Pak AI green.
class _ThemeModeTile extends StatelessWidget {
  final ColorScheme scheme;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeModeTile({
    required this.scheme,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? scheme.primary.withOpacity(0.08)
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withOpacity(0.16)
                      : scheme.surfaceContainerHighest,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: selected
                    ? Icon(
                        Icons.check_circle_rounded,
                        key: const ValueKey('selected'),
                        color: scheme.primary,
                        size: 22,
                      )
                    : Icon(
                        Icons.circle_outlined,
                        key: const ValueKey('unselected'),
                        color: scheme.outlineVariant,
                        size: 22,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
