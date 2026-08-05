import 'package:flutter/material.dart';

import '../core/theme/chat_palette.dart';
import 'about_screen.dart';
import 'privacy_policy_screen.dart';
import 'welcome_screen.dart';

/// Premium Pak AI profile screen.
///
/// Runs on the same "Emerald + Graphite" [ChatPalette] used by Chat,
/// History, and Settings — never the app-wide violet [AppTheme] — so the
/// whole authenticated-shell of the app stays visually consistent.
///
/// Step 19.2: [ProfileScreen] is now only ever reached *after* the
/// [WelcomeScreen] auth gate, so there's no "not signed in" state to
/// render here any more — this screen just reflects Guest vs. (future)
/// real account status via [AuthPrefs], and offers Logout, which clears
/// the auth flag and returns the user to [WelcomeScreen].
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  bool _isGuest = false;
  bool _isLoading = true;

  late final AnimationController _entranceController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _entranceController,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _entranceController, curve: Curves.easeOutCubic),
    );
    _loadAuthState();
  }

  Future<void> _loadAuthState() async {
    final isGuest = await AuthPrefs.isGuest();
    if (!mounted) return;
    setState(() {
      _isGuest = isGuest;
      _isLoading = false;
    });
    _entranceController.forward();
  }

  void _showSnack(String message, ColorScheme scheme) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _logout() async {
    await AuthPrefs.signOut();
    if (!mounted) return;
    // Clear the whole stack — Chat, drawer routes, this screen — so
    // there's nothing to pop back into behind Welcome.
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const WelcomeScreen()),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same premium emerald palette Chat/History/Settings use — see class
    // doc above. Threaded explicitly into every widget below.
    final theme = ChatPalette.themeFor(context);
    final scheme = theme.colorScheme;

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
            'Profile',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: scheme.onSurface,
            ),
          ),
        ),
        body: _isLoading
            ? const SizedBox.shrink()
            : FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _ProfileHeaderCard(scheme: scheme, theme: theme, isGuest: _isGuest),
                      const SizedBox(height: 28),
                      _SectionLabel('Account', color: scheme.primary),
                      _ProfileCard(
                        scheme: scheme,
                        children: [
                          _ProfileTile(
                            scheme: scheme,
                            leadingIcon: Icons.person_outline_rounded,
                            title: 'Account',
                            subtitle: 'Manage your account details',
                            onTap: () => _showSnack(
                              'Account settings coming soon',
                              scheme,
                            ),
                          ),
                          _ProfileDivider(scheme: scheme),
                          _ProfileTile(
                            scheme: scheme,
                            leadingIcon: Icons.workspace_premium_rounded,
                            title: 'Subscription',
                            subtitle: 'Plans and billing',
                            onTap: () => _showSnack(
                              'Subscription coming soon',
                              scheme,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _SectionLabel('Support & Legal', color: scheme.primary),
                      _ProfileCard(
                        scheme: scheme,
                        children: [
                          _ProfileTile(
                            scheme: scheme,
                            leadingIcon: Icons.privacy_tip_outlined,
                            title: 'Privacy',
                            subtitle: 'How we handle your data',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const PrivacyPolicyScreen(),
                              ),
                            ),
                          ),
                          _ProfileDivider(scheme: scheme),
                          _ProfileTile(
                            scheme: scheme,
                            leadingIcon: Icons.help_outline_rounded,
                            title: 'Help',
                            subtitle: 'Support and FAQs',
                            onTap: () => _showSnack('Help coming soon', scheme),
                          ),
                          _ProfileDivider(scheme: scheme),
                          _ProfileTile(
                            scheme: scheme,
                            leadingIcon: Icons.info_outline_rounded,
                            title: 'About',
                            subtitle: 'Version and app info',
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const AboutScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _SectionLabel('Session', color: scheme.primary),
                      _ProfileCard(
                        scheme: scheme,
                        children: [
                          _ProfileTile(
                            scheme: scheme,
                            leadingIcon: Icons.logout_rounded,
                            title: 'Logout',
                            subtitle: _isGuest
                                ? 'End guest session'
                                : 'Sign out of your account',
                            iconColor: scheme.error,
                            titleColor: scheme.error,
                            onTap: _logout,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// Large avatar + account-status copy, in a soft emerald-tinted card.
/// Swaps its title/subtitle with an [AnimatedSwitcher] whenever [isGuest]
/// changes (e.g. the moment Logout clears it, if this widget were ever
/// rebuilt in place instead of navigated away from).
class _ProfileHeaderCard extends StatelessWidget {
  final ColorScheme scheme;
  final ThemeData theme;
  final bool isGuest;

  const _ProfileHeaderCard({
    required this.scheme,
    required this.theme,
    required this.isGuest,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = scheme.brightness == Brightness.dark;

    final String headline = isGuest ? 'Guest User' : 'Pak AI User';
    final String subtitle = isGuest
        ? "You're browsing as a guest — sign in anytime to sync your conversations."
        : 'Signed in to Pak AI.';

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withOpacity(isDark ? 0.22 : 0.14),
            scheme.surfaceContainerHigh,
          ],
        ),
        border: Border.all(
          color: scheme.outlineVariant.withOpacity(0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withOpacity(isDark ? 0.0 : 0.06),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          _LargeAvatar(scheme: scheme, isGuest: isGuest),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.15),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: Column(
              key: ValueKey(isGuest),
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Large circular avatar — filled emerald glyph, swapping between a
/// generic person icon and a guest icon via [AnimatedSwitcher].
class _LargeAvatar extends StatelessWidget {
  final ColorScheme scheme;
  final bool isGuest;

  const _LargeAvatar({required this.scheme, required this.isGuest});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary,
            scheme.primary.withOpacity(0.65),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.35),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
          child: Icon(
            isGuest ? Icons.person_rounded : Icons.person_outline_rounded,
            key: ValueKey(isGuest),
            size: 48,
            color: scheme.onPrimary,
          ),
        ),
      ),
    );
  }
}

/// Section header — matches the style used across Settings/History.
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

/// A large, rounded, softly-shadowed card — shared container for the
/// grouped profile ListTiles below the header.
class _ProfileCard extends StatelessWidget {
  final ColorScheme scheme;
  final List<Widget> children;
  const _ProfileCard({required this.scheme, required this.children});

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
      child: Column(children: children),
    );
  }
}

/// A thin, inset divider between rows inside a [_ProfileCard].
class _ProfileDivider extends StatelessWidget {
  final ColorScheme scheme;
  const _ProfileDivider({required this.scheme});

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

/// A premium Material 3 row: leading icon in a soft tinted circle, title,
/// optional subtitle, and a chevron. Uses Material Symbols Rounded icon
/// glyphs and the emerald [ColorScheme] throughout. [iconColor]/[titleColor]
/// let destructive rows (Logout) use the scheme's error color instead of
/// primary, while staying on the same emerald [ColorScheme].
class _ProfileTile extends StatelessWidget {
  final ColorScheme scheme;
  final IconData leadingIcon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? titleColor;

  const _ProfileTile({
    required this.scheme,
    required this.leadingIcon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.iconColor,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedIconColor = iconColor ?? scheme.primary;
    final resolvedTitleColor = titleColor ?? scheme.onSurface;
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
                  color: resolvedIconColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(leadingIcon, size: 19, color: resolvedIconColor),
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
                        color: resolvedTitleColor,
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

/// Rounded, tinted back button — matches [SettingsScreen]'s app bar leading
/// widget exactly, with a subtle press-scale animation.
class _RoundedBackButton extends StatefulWidget {
  final ColorScheme scheme;
  final VoidCallback onTap;
  const _RoundedBackButton({required this.scheme, required this.onTap});

  @override
  State<_RoundedBackButton> createState() => _RoundedBackButtonState();
}

class _RoundedBackButtonState extends State<_RoundedBackButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.9 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: widget.scheme.surfaceContainerHighest,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.arrow_back_ios_new_rounded,
            size: 17,
            color: widget.scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
