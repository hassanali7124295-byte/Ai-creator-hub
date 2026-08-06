import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../screens/profile_screen.dart';
import '../screens/welcome_screen.dart' show AuthPrefs;

/// STEP 27B — Premium Home Screen Redesign.
///
/// Everything in this file is purely presentational and is only ever
/// mounted on the empty/"home" state of [ChatScreen]. None of it touches
/// chat bubbles, streaming, attachments, routing, or the Gemini service —
/// per the Step 27B brief, this is a Home-UI-only visual layer.

// ---------------------------------------------------------------------------
// Subtle Pakistan-outline background
// ---------------------------------------------------------------------------

/// A near-invisible decorative backdrop: a soft emerald wash plus a single
/// stylized Pakistan border line rendered at 2–3% opacity. Purely an
/// atmospheric texture — never meant to be "read", just felt.
class PakSubtleBackground extends StatelessWidget {
  const PakSubtleBackground({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // Soft emerald gradient wash — the "premium" glow behind the
            // content, not a hard-edged block of color.
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.85, -0.9),
                  radius: 1.35,
                  colors: [
                    scheme.primary.withOpacity(isDark ? 0.10 : 0.07),
                    scheme.primary.withOpacity(0.0),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.9, 1.0),
                  radius: 1.1,
                  colors: [
                    scheme.tertiary.withOpacity(isDark ? 0.07 : 0.05),
                    scheme.tertiary.withOpacity(0.0),
                  ],
                ),
              ),
            ),
            // The almost-invisible map line itself.
            CustomPaint(
              painter: _PakOutlinePainter(
                color: scheme.onSurface.withOpacity(isDark ? 0.05 : 0.035),
              ),
              child: const SizedBox.expand(),
            ),
          ],
        ),
      ),
    );
  }
}

/// A deliberately simplified, stylized silhouette evoking Pakistan's
/// borders — decorative texture, not a surveying-grade map. Drawn as a
/// fraction-of-canvas polygon so it scales cleanly to any screen size.
class _PakOutlinePainter extends CustomPainter {
  final Color color;
  const _PakOutlinePainter({required this.color});

  // Rough, stylized silhouette (fractions of the canvas width/height),
  // loosely tracing the northern mountains, the western border down to
  // the Arabian Sea, and the eastern border back up.
  static const List<Offset> _points = [
    Offset(0.62, 0.06),
    Offset(0.70, 0.10),
    Offset(0.78, 0.09),
    Offset(0.86, 0.15),
    Offset(0.90, 0.24),
    Offset(0.84, 0.30),
    Offset(0.88, 0.38),
    Offset(0.80, 0.46),
    Offset(0.83, 0.55),
    Offset(0.74, 0.64),
    Offset(0.76, 0.74),
    Offset(0.64, 0.84),
    Offset(0.58, 0.92),
    Offset(0.46, 0.90),
    Offset(0.38, 0.80),
    Offset(0.24, 0.78),
    Offset(0.10, 0.70),
    Offset(0.06, 0.60),
    Offset(0.16, 0.54),
    Offset(0.14, 0.44),
    Offset(0.26, 0.40),
    Offset(0.22, 0.30),
    Offset(0.32, 0.24),
    Offset(0.30, 0.14),
    Offset(0.42, 0.10),
    Offset(0.50, 0.14),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (var i = 0; i < _points.length; i++) {
      final p = Offset(_points[i].dx * size.width, _points[i].dy * size.height);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..color = color.withOpacity(color.opacity * 0.4)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _PakOutlinePainter oldDelegate) =>
      oldDelegate.color != color;
}

// ---------------------------------------------------------------------------
// Logo mark
// ---------------------------------------------------------------------------

/// The small emerald "Pak AI" glyph — a soft gradient roundel with a
/// crescent-and-star accent — used in the Home top bar and hero.
class PakLogoMark extends StatelessWidget {
  final double size;
  const PakLogoMark({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
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
            blurRadius: size * 0.5,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: Center(
        child: Icon(
          Icons.nights_stay_rounded,
          color: scheme.onPrimary,
          size: size * 0.52,
        ),
      ),
    );
  }
}

/// Center-of-app-bar wordmark: the small logo roundel plus "Pak AI" text —
/// intentionally modest in size (never a "huge" greeting), for the Home
/// top bar only.
class PakHomeAppBarTitle extends StatelessWidget {
  const PakHomeAppBarTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const PakLogoMark(size: 26),
        const SizedBox(width: 8),
        Text(
          'Pak AI',
          style: GoogleFonts.poppins(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Profile avatar button (top bar, right)
// ---------------------------------------------------------------------------

/// Right-side top-bar avatar. Loads the signed-in account's photo (or a
/// graceful monogram fallback for Guest / no photo) and opens
/// [ProfileScreen] on tap — reusing the exact same profile flow already
/// wired up from the drawer, so nothing about account/session handling is
/// duplicated or redesigned.
class ProfileAvatarButton extends StatefulWidget {
  const ProfileAvatarButton({super.key});

  @override
  State<ProfileAvatarButton> createState() => _ProfileAvatarButtonState();
}

class _ProfileAvatarButtonState extends State<ProfileAvatarButton> {
  String? _photoUrl;
  String? _name;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final photo = await AuthPrefs.userPhotoUrl();
    final name = await AuthPrefs.userName();
    if (!mounted) return;
    setState(() {
      _photoUrl = photo;
      _name = name;
    });
  }

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final initial = (_name?.isNotEmpty ?? false) ? _name![0].toUpperCase() : null;

    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Tooltip(
        message: 'Profile',
        child: GestureDetector(
          onTapDown: (_) => _setPressed(true),
          onTapCancel: () => _setPressed(false),
          onTapUp: (_) => _setPressed(false),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            );
          },
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.primary.withOpacity(0.9),
                    scheme.primary.withOpacity(0.55),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withOpacity(0.25),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(1.6),
              child: ClipOval(
                child: Container(
                  color: scheme.surfaceContainerHigh,
                  child: (_photoUrl?.isNotEmpty ?? false)
                      ? Image.network(
                          _photoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => _fallback(scheme, initial),
                        )
                      : _fallback(scheme, initial),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fallback(ColorScheme scheme, String? initial) {
    return Center(
      child: initial != null
          ? Text(
              initial,
              style: GoogleFonts.poppins(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            )
          : Icon(Icons.person_rounded, size: 18, color: scheme.primary),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick action chips (horizontal scroll)
// ---------------------------------------------------------------------------

class QuickAction {
  final IconData icon;
  final String label;
  final String prompt;
  const QuickAction({required this.icon, required this.label, required this.prompt});
}

const List<QuickAction> pakQuickActions = [
  QuickAction(
    icon: Icons.image_rounded,
    label: 'Explain Image',
    prompt: 'Explain what\'s in this image: ',
  ),
  QuickAction(
    icon: Icons.description_rounded,
    label: 'Write Script',
    prompt: 'Write a script about ',
  ),
  QuickAction(
    icon: Icons.translate_rounded,
    label: 'Translate',
    prompt: 'Translate this into Urdu: ',
  ),
  QuickAction(
    icon: Icons.summarize_rounded,
    label: 'Summarize',
    prompt: 'Summarize this for me: ',
  ),
  QuickAction(
    icon: Icons.lightbulb_rounded,
    label: 'Brainstorm',
    prompt: 'Brainstorm ideas for ',
  ),
];

/// A horizontally scrolling row of small glass-emerald pill chips — the
/// premium, "not a grid of big square boxes" quick-actions row.
class QuickActionsRow extends StatelessWidget {
  final ValueChanged<String> onTap;
  const QuickActionsRow({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: pakQuickActions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final action = pakQuickActions[index];
          return _QuickActionChip(
            action: action,
            onTap: () => onTap(action.prompt),
          );
        },
      ),
    );
  }
}

class _QuickActionChip extends StatefulWidget {
  final QuickAction action;
  final VoidCallback onTap;
  const _QuickActionChip({required this.action, required this.onTap});

  @override
  State<_QuickActionChip> createState() => _QuickActionChipState();
}

class _QuickActionChipState extends State<_QuickActionChip> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(23),
          child: InkWell(
            borderRadius: BorderRadius.circular(23),
            splashColor: scheme.primary.withOpacity(0.12),
            onTap: () {
              widget.onTap();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(23),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.surfaceContainerHigh.withOpacity(isDark ? 0.55 : 0.9),
                    scheme.primary.withOpacity(isDark ? 0.14 : 0.08),
                  ],
                ),
                border: Border.all(
                  color: scheme.primary.withOpacity(isDark ? 0.22 : 0.16),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.shadow.withOpacity(isDark ? 0.0 : 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.action.icon, size: 16, color: scheme.primary),
                  const SizedBox(width: 7),
                  Text(
                    widget.action.label,
                    style: GoogleFonts.poppins(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero wordmark block (body)
// ---------------------------------------------------------------------------

/// The elegant, deliberately small "Pak AI / Smart AI Assistant for
/// Pakistan" brand block that replaces the old oversized greeting heading.
class PakHeroBrand extends StatelessWidget {
  const PakHeroBrand({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PakLogoMark(size: 40),
        const SizedBox(height: 16),
        Text(
          'Pak AI',
          style: GoogleFonts.poppins(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'SMART AI ASSISTANT FOR PAKISTAN',
          style: GoogleFonts.poppins(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.4,
            color: scheme.onSurfaceVariant.withOpacity(0.75),
          ),
        ),
      ],
    );
  }
}
