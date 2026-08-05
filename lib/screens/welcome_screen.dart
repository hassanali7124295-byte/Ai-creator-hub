import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/chat_palette.dart';
import 'chat_screen.dart';

/// Step 19.2: tiny local auth-flag store, shared by [WelcomeScreen] (which
/// sets it) and `ProfileScreen` (which reads it and clears it on logout),
/// plus `main.dart`'s startup auth gate (which reads it once at launch).
///
/// No backend yet, so "signed in" today only ever means "chose Guest" —
/// but the flag is deliberately split into two keys so a real Google/Email
/// login can later set [isSignedIn] true while [isGuest] stays false,
/// without any call site needing to change.
class AuthPrefs {
  AuthPrefs._();

  static const _signedInKey = 'pak_ai_signed_in';
  static const _guestKey = 'pak_ai_guest_mode';

  /// True once the user has chosen Guest (or, in the future, actually
  /// signed in) — i.e. the app should skip [WelcomeScreen] on launch.
  static Future<bool> isSignedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_signedInKey) ?? false;
  }

  /// True specifically for the Guest path, so the Profile screen can show
  /// "Guest User" rather than real account info.
  static Future<bool> isGuest() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_guestKey) ?? false;
  }

  static Future<void> setGuest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestKey, true);
    await prefs.setBool(_signedInKey, true);
  }

  /// Logout: clears both flags so the next launch — and any push right
  /// now — lands back on [WelcomeScreen].
  static Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestKey, false);
    await prefs.setBool(_signedInKey, false);
  }
}

/// Startup screen shown the first time the app launches (and again after
/// logout) — mirrors the "pick a sign-in method" pattern used by ChatGPT,
/// Gemini, and Claude's own mobile apps. Runs on the same emerald
/// [ChatPalette] as the rest of the authenticated app.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _slideAnimation;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showComingSoon(String provider, ColorScheme scheme) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text('$provider — Coming soon'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _continueAsGuest() async {
    if (_busy) return;
    setState(() => _busy = true);
    await AuthPrefs.setGuest();
    if (!mounted) return;
    // Guest never sees Welcome again until they log out — replace, don't
    // push, so there's nothing to pop back into.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = ChatPalette.themeFor(context);
    final scheme = theme.colorScheme;
    final isDark = scheme.brightness == Brightness.dark;

    return Theme(
      data: theme,
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                scheme.primary.withOpacity(isDark ? 0.30 : 0.16),
                scheme.surface,
                scheme.surface,
              ],
            ),
          ),
          child: SafeArea(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SlideTransition(
                position: _slideAnimation,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 24, 28, 32),
                  child: Column(
                    children: [
                      const Spacer(flex: 3),
                      _WelcomeLogo(scheme: scheme),
                      const SizedBox(height: 32),
                      Text(
                        'Welcome to Pak AI',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Your private, on-device AI assistant.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(flex: 4),
                      _AuthButton(
                        scheme: scheme,
                        icon: Icons.g_mobiledata_rounded,
                        label: 'Continue with Google',
                        filled: true,
                        onTap: () => _showComingSoon('Google sign-in', scheme),
                      ),
                      const SizedBox(height: 14),
                      _AuthButton(
                        scheme: scheme,
                        icon: Icons.mail_outline_rounded,
                        label: 'Continue with Email',
                        filled: false,
                        onTap: () => _showComingSoon('Email sign-in', scheme),
                      ),
                      const SizedBox(height: 14),
                      _AuthButton(
                        scheme: scheme,
                        icon: Icons.person_outline_rounded,
                        label: 'Continue as Guest',
                        filled: false,
                        onTap: _continueAsGuest,
                        busy: _busy,
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Large circular Pak AI logo, pulled from the app's own launcher icon
/// asset (already declared in pubspec.yaml) rather than a redrawn glyph,
/// so it always matches the real app icon.
class _WelcomeLogo extends StatelessWidget {
  final ColorScheme scheme;
  const _WelcomeLogo({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withOpacity(0.38),
            blurRadius: 40,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/icon/icon.png',
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// One full-width auth option — solid emerald "primary" style for Google
/// (the recommended path, mirroring ChatGPT/Gemini's own convention), soft
/// outlined style for Email/Guest.
class _AuthButton extends StatelessWidget {
  final ColorScheme scheme;
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;
  final bool busy;

  const _AuthButton({
    required this.scheme,
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor =
        filled ? scheme.primary : scheme.surfaceContainerHigh;
    final foregroundColor = filled ? scheme.onPrimary : scheme.onSurface;

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: busy ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: filled
                ? null
                : Border.all(color: scheme.outlineVariant.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.4,
                    color: foregroundColor,
                  ),
                )
              else
                Icon(icon, size: 22, color: foregroundColor),
              const SizedBox(width: 12),
              Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
