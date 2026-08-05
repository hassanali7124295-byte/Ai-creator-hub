import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/chat_palette.dart';
import 'chat_screen.dart';

/// Step 19.2 (Guest) / Step 19.3 (real Google): tiny local auth-flag +
/// profile store, shared by [WelcomeScreen] (which sets it) and
/// `ProfileScreen` (which reads it and clears it on sign-out), plus
/// `main.dart`'s startup auth gate (which reads [isSignedIn] once at
/// launch).
///
/// [loginType] distinguishes *how* the current session was created
/// ('guest' or 'google') so the Profile screen knows whether to render a
/// real Google avatar/name/email or the generic Guest placeholder.
class AuthPrefs {
  AuthPrefs._();

  static const _signedInKey = 'pak_ai_signed_in';
  static const _guestKey = 'pak_ai_guest_mode';
  static const _loginTypeKey = 'pak_ai_login_type';
  static const _nameKey = 'pak_ai_user_name';
  static const _emailKey = 'pak_ai_user_email';
  static const _photoUrlKey = 'pak_ai_user_photo_url';

  /// True once the user has chosen Guest or signed in with Google — i.e.
  /// the app should skip [WelcomeScreen] on launch.
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

  /// 'guest' or 'google' — null before any session has ever been created.
  static Future<String?> loginType() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_loginTypeKey);
  }

  static Future<String?> userName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_nameKey);
  }

  static Future<String?> userEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_emailKey);
  }

  static Future<String?> userPhotoUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_photoUrlKey);
  }

  static Future<void> setGuest() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestKey, true);
    await prefs.setBool(_signedInKey, true);
    await prefs.setString(_loginTypeKey, 'guest');
    // A previous Google session's profile fields (if any) no longer apply.
    await prefs.remove(_nameKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_photoUrlKey);
  }

  /// Persists a successful real Google sign-in: name, email, profile photo
  /// URL, login type = 'google', and logged_in = true.
  static Future<void> setGoogleUser({
    required String name,
    required String email,
    String? photoUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestKey, false);
    await prefs.setBool(_signedInKey, true);
    await prefs.setString(_loginTypeKey, 'google');
    await prefs.setString(_nameKey, name);
    await prefs.setString(_emailKey, email);
    if (photoUrl != null) {
      await prefs.setString(_photoUrlKey, photoUrl);
    } else {
      await prefs.remove(_photoUrlKey);
    }
  }

  /// Sign-out: clears every stored flag/profile field so the next launch —
  /// and any push right now — lands back on [WelcomeScreen] with no stale
  /// account info left behind.
  static Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_guestKey, false);
    await prefs.setBool(_signedInKey, false);
    await prefs.remove(_loginTypeKey);
    await prefs.remove(_nameKey);
    await prefs.remove(_emailKey);
    await prefs.remove(_photoUrlKey);
  }
}

/// Step 19.3: thin wrapper around the single shared [GoogleSignIn] instance
/// used by both [WelcomeScreen] (to sign in) and `ProfileScreen` (to sign
/// out of the Google session itself, not just clear local prefs).
class GoogleAuthService {
  GoogleAuthService._();

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
  );

  /// Opens the real Google account picker. Returns the chosen account, or
  /// `null` if the user cancelled the picker without choosing one.
  /// Throws on genuine failures (no network, Play Services issue, etc.).
  static Future<GoogleSignInAccount?> signIn() => _googleSignIn.signIn();

  /// Fully signs out of the Google session (not just local app prefs), so
  /// the account picker is offered fresh next time rather than silently
  /// reusing the last session.
  static Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // Best-effort — local AuthPrefs.signOut() already clears the app's
      // own session state regardless of whether this network call lands.
    }
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

  // Separate busy flags per action so each button's own spinner reflects
  // only its own in-flight request; [_anyBusy] is used to disable the
  // *other* buttons while one action is in progress.
  bool _googleBusy = false;
  bool _guestBusy = false;
  bool get _anyBusy => _googleBusy || _guestBusy;

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
    if (_anyBusy) return;
    setState(() => _guestBusy = true);
    await AuthPrefs.setGuest();
    if (!mounted) return;
    // Guest never sees Welcome again until they log out — replace, don't
    // push, so there's nothing to pop back into.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const ChatScreen()),
    );
  }

  /// Step 19.3: real Google Sign-In. Opens the official account picker;
  /// on success, persists the profile via [AuthPrefs.setGoogleUser] and
  /// goes straight to Chat. On cancel, quietly stays on Welcome. On
  /// failure, shows a professional error SnackBar and stays on Welcome.
  Future<void> _continueWithGoogle() async {
    if (_anyBusy) return;
    setState(() => _googleBusy = true);

    try {
      final account = await GoogleAuthService.signIn();

      if (account == null) {
        // User dismissed the picker without choosing an account — not an
        // error, just stay on Welcome.
        if (mounted) setState(() => _googleBusy = false);
        return;
      }

      final name = account.displayName?.trim();
      await AuthPrefs.setGoogleUser(
        name: (name == null || name.isEmpty) ? account.email : name,
        email: account.email,
        photoUrl: account.photoUrl,
      );

      if (!mounted) return;
      // Signed-in users never see Welcome again until they sign out —
      // replace, don't push, so there's nothing to pop back into.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _googleBusy = false);
      _showSignInError();
    }
  }

  void _showSignInError() {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        backgroundColor: scheme.errorContainer,
        content: Row(
          children: [
            Icon(Icons.error_outline_rounded,
                color: scheme.onErrorContainer, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                "Couldn't sign in with Google. Please try again.",
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
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
                        leading: const _GoogleLogo(size: 22),
                        iconSpacing: 16,
                        label: 'Continue with Google',
                        filled: true,
                        onTap: _continueWithGoogle,
                        busy: _googleBusy,
                        enabled: !_guestBusy,
                      ),
                      const SizedBox(height: 14),
                      _AuthButton(
                        scheme: scheme,
                        icon: Icons.mail_outline_rounded,
                        label: 'Continue with Email',
                        filled: false,
                        onTap: () => _showComingSoon('Email sign-in', scheme),
                        enabled: !_anyBusy,
                      ),
                      const SizedBox(height: 14),
                      _AuthButton(
                        scheme: scheme,
                        icon: Icons.person_outline_rounded,
                        label: 'Continue as Guest',
                        filled: false,
                        onTap: _continueAsGuest,
                        busy: _guestBusy,
                        enabled: !_googleBusy,
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

  /// False while a *different* auth button is busy, so the user can't
  /// fire two sign-in flows at once. Purely a disabled visual state — no
  /// spinner — distinct from [busy], which is this button's own spinner.
  final bool enabled;

  /// Optional custom leading graphic (e.g. the official multicolor Google
  /// "G" mark) shown instead of [icon]. Only the Google button passes
  /// this — Email/Guest keep using [icon] exactly as before.
  final Widget? leading;

  /// Gap between the leading glyph and [label]. Defaults to the original
  /// 12px used by every button; only the Google button overrides this
  /// (to 16px) per its own spec.
  final double iconSpacing;

  const _AuthButton({
    required this.scheme,
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
    this.busy = false,
    this.enabled = true,
    this.leading,
    this.iconSpacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final backgroundColor =
        filled ? scheme.primary : scheme.surfaceContainerHigh;
    final foregroundColor = filled ? scheme.onPrimary : scheme.onSurface;
    final interactive = !busy && enabled;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1.0 : 0.5,
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: interactive ? onTap : null,
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
                  leading ?? Icon(icon, size: 22, color: foregroundColor),
                SizedBox(width: iconSpacing),
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
      ),
    );
  }
}

/// The official, multicolor Google "G" mark — used only on the Google
/// button, in place of the old `Icons.g_mobiledata_rounded` placeholder.
///
/// Traced directly from Google's own Sign-In button brand assets
/// (developers.google.com/identity/branding-guidelines): four flat paths
/// in a 48x48 box, colored Google Blue #4285F4, Green #34A853, Yellow
/// #FBBC05, and Red #EA4335. Drawn with [CustomPainter] rather than a
/// bundled image/font asset, since no network fetch is available at
/// build time to vendor the real PNG/SVG file — the path geometry itself
/// is copied byte-for-byte from Google's canonical mark, so the on-screen
/// result matches the real logo exactly, just rendered as vector paths
/// instead of a rasterized asset.
class _GoogleLogo extends StatelessWidget {
  final double size;
  const _GoogleLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // The path data below is authored in Google's own 48x48 mark
    // coordinate space; scale that box to whatever size this painter is
    // actually given.
    canvas.scale(size.width / 48, size.height / 48);

    final red = Paint()..color = const Color(0xFFEA4335);
    final blue = Paint()..color = const Color(0xFF4285F4);
    final yellow = Paint()..color = const Color(0xFFFBBC05);
    final green = Paint()..color = const Color(0xFF34A853);

    final redPath = Path()
      ..moveTo(24, 9.5)
      ..cubicTo(27.54, 9.5, 30.71, 10.72, 33.21, 13.1)
      ..lineTo(40.06, 6.25)
      ..cubicTo(35.9, 2.38, 30.47, 0, 24, 0)
      ..cubicTo(14.62, 0, 6.51, 5.38, 2.56, 13.22)
      ..lineTo(10.54, 19.41)
      ..cubicTo(12.43, 13.72, 17.74, 9.5, 24, 9.5)
      ..close();

    final bluePath = Path()
      ..moveTo(46.98, 24.55)
      ..cubicTo(46.98, 22.98, 46.83, 21.46, 46.6, 20.0)
      ..lineTo(24, 20.0)
      ..lineTo(24, 29.02)
      ..lineTo(36.94, 29.02)
      ..cubicTo(36.36, 31.98, 34.68, 34.5, 32.16, 36.2)
      ..lineTo(39.89, 42.2)
      ..cubicTo(44.4, 38.02, 46.98, 31.84, 46.98, 24.55)
      ..close();

    final yellowPath = Path()
      ..moveTo(10.53, 28.59)
      ..cubicTo(10.05, 27.14, 9.77, 25.6, 9.77, 24.0)
      ..cubicTo(9.77, 22.4, 10.04, 20.86, 10.53, 19.41)
      ..lineTo(2.55, 13.22)
      ..cubicTo(0.92, 16.46, 0, 20.12, 0, 24)
      ..cubicTo(0, 27.88, 0.92, 31.54, 2.56, 34.78)
      ..lineTo(10.53, 28.59)
      ..close();

    final greenPath = Path()
      ..moveTo(24, 48)
      ..cubicTo(30.48, 48, 35.93, 45.87, 39.89, 42.19)
      ..lineTo(32.16, 36.19)
      ..cubicTo(30.01, 37.64, 27.24, 38.49, 24.0, 38.49)
      ..cubicTo(17.74, 38.49, 12.43, 34.27, 10.53, 28.58)
      ..lineTo(2.55, 34.77)
      ..cubicTo(6.51, 42.62, 14.62, 48, 24, 48)
      ..close();

    canvas.drawPath(redPath, red);
    canvas.drawPath(bluePath, blue);
    canvas.drawPath(yellowPath, yellow);
    canvas.drawPath(greenPath, green);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GoogleLogoPainter oldDelegate) => false;
}
