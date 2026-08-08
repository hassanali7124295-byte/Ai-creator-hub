import 'package:flutter/material.dart';

/// The kind of attachment source the user picked from [showAttachmentSheet].
///
/// Step 38: `ocr` and `handwriting` aren't attachment sources in the same
/// sense as the original four — picking either one doesn't attach a file to
/// the chat, it launches the Scan Text / Handwriting flow (see
/// `ChatScreen._startTextScan`), which asks for its own Camera/Gallery
/// source via `showImageSourceSheet` afterwards.
enum AttachmentType { gallery, camera, document, file, ocr, handwriting }

class _AttachmentOption {
  final AttachmentType type;
  final IconData icon;
  final String label;
  const _AttachmentOption(this.type, this.icon, this.label);
}

// Step 18.3: single row, ChatGPT (Android)-style ordering — Camera,
// Gallery, Files, PDF.
//
// Step 38: two more entry points — Scan Text (OCR) and Handwriting —
// appended after the original four. Kept in the same list/animation
// sequence as the original options (see `_AttachmentSheetContentState`
// below) rather than a separate widget, so the sheet still reads as one
// consistent set of actions.
const List<_AttachmentOption> _options = [
  _AttachmentOption(
      AttachmentType.camera, Icons.photo_camera_rounded, 'Camera'),
  _AttachmentOption(AttachmentType.gallery, Icons.image_rounded, 'Gallery'),
  _AttachmentOption(AttachmentType.file, Icons.folder_rounded, 'Files'),
  _AttachmentOption(
      AttachmentType.document, Icons.picture_as_pdf_rounded, 'PDF'),
  _AttachmentOption(
      AttachmentType.ocr, Icons.document_scanner_rounded, 'Scan Text'),
  _AttachmentOption(
      AttachmentType.handwriting, Icons.draw_rounded, 'Handwriting'),
];

/// Shows a clean, solid-white, ChatGPT(Android)-style bottom sheet with
/// large circular buttons — Camera, Gallery, Files, PDF, and (Step 38)
/// Scan Text, Handwriting. Returns the chosen [AttachmentType], or `null`
/// if the sheet was dismissed without a selection.
Future<AttachmentType?> showAttachmentSheet(BuildContext context) {
  return showModalBottomSheet<AttachmentType>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    elevation: 16,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    builder: (sheetContext) => const _AttachmentSheetContent(),
  );
}

/// The sheet body: a small drag handle followed by a single evenly-spaced
/// row of [_AttachmentButton]s, wrapped in a fade + slide-up entrance.
class _AttachmentSheetContent extends StatefulWidget {
  const _AttachmentSheetContent();

  @override
  State<_AttachmentSheetContent> createState() =>
      _AttachmentSheetContentState();
}

class _AttachmentSheetContentState extends State<_AttachmentSheetContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Small drag handle.
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2E2E2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                // Step 38: was a single-row `Row`; switched to `Wrap` so the
                // two new options (Scan Text, Handwriting) flow onto a
                // second line instead of squeezing all six into one row.
                // Spacing/alignment intentionally mirror the old Row's
                // `spaceEvenly` look — the original four buttons render
                // identically to Step 37.
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  spacing: 12,
                  runSpacing: 22,
                  children: [
                    for (var i = 0; i < _options.length; i++)
                      _AttachmentButton(
                        option: _options[i],
                        controller: _controller,
                        index: i,
                        onTap: () =>
                            Navigator.of(context).pop(_options[i].type),
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

/// One circular attachment button: a large light-gray circle holding the
/// icon, with its label underneath — no card, no border, no outline. Pops
/// in with a slight staggered scale + fade, and gives a soft circular
/// ripple plus a small press-scale on tap.
class _AttachmentButton extends StatefulWidget {
  final _AttachmentOption option;
  final AnimationController controller;
  final int index;
  final VoidCallback onTap;

  const _AttachmentButton({
    required this.option,
    required this.controller,
    required this.index,
    required this.onTap,
  });

  @override
  State<_AttachmentButton> createState() => _AttachmentButtonState();
}

class _AttachmentButtonState extends State<_AttachmentButton> {
  bool _pressed = false;

  void _setPressed(bool value) => setState(() => _pressed = value);

  static const double _circleSize = 68;

  @override
  Widget build(BuildContext context) {
    final start = (widget.index * 0.08).clamp(0.0, 0.6);
    final end = (start + 0.45).clamp(0.0, 1.0);
    final entrance = CurvedAnimation(
      parent: widget.controller,
      curve: Interval(start, end, curve: Curves.easeOutBack),
    );

    return AnimatedBuilder(
      animation: entrance,
      builder: (context, child) => Opacity(
        opacity: entrance.value.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: entrance.value.clamp(0.0, 1.0),
          child: child,
        ),
      ),
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: const Color(0xFFF2F2F3),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  splashColor: Colors.black.withOpacity(0.06),
                  highlightColor: Colors.black.withOpacity(0.04),
                  onTap: widget.onTap,
                  child: SizedBox(
                    width: _circleSize,
                    height: _circleSize,
                    child: Icon(
                      widget.option.icon,
                      size: 28,
                      color: const Color(0xFF1A1A1A),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.option.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A1A),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
