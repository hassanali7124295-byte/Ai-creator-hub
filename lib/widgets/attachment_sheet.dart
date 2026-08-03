import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';

import '../core/theme/chat_palette.dart';

/// The kind of attachment source the user picked from [showAttachmentSheet].
enum AttachmentType { gallery, camera, document, file }

class _AttachmentOption {
  final AttachmentType type;
  final IconData icon;
  final String label;
  final String subtitle;
  const _AttachmentOption(this.type, this.icon, this.label, this.subtitle);
}

// Step 18.2: reordered to the requested Camera / Gallery / Files / PDF
// layout, now presented as large cards in a 2x2 grid instead of a plain
// list.
const List<_AttachmentOption> _options = [
  _AttachmentOption(
      AttachmentType.camera, Icons.photo_camera_rounded, 'Camera', 'Take a photo'),
  _AttachmentOption(
      AttachmentType.gallery, Icons.photo_rounded, 'Gallery', 'Choose a photo'),
  _AttachmentOption(
      AttachmentType.file, Icons.folder_rounded, 'Files', 'Browse files'),
  _AttachmentOption(
      AttachmentType.document, Icons.picture_as_pdf_rounded, 'PDF', 'Pick a PDF'),
];

/// Shows a premium bottom sheet letting the user choose an attachment
/// source (Camera, Gallery, Files, PDF) as large rounded cards. Returns
/// the chosen [AttachmentType], or `null` if the sheet was dismissed.
Future<AttachmentType?> showAttachmentSheet(BuildContext context) {
  final theme = Theme.of(context);
  // Icon accents always use the same Emerald palette as the chat screen
  // itself, regardless of which context this sheet was opened from.
  final accent = ChatPalette.colorSchemeFor(context);

  return showModalBottomSheet<AttachmentType>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _AttachmentSheetBody(theme: theme, accent: accent);
    },
  );
}

class _AttachmentSheetBody extends StatelessWidget {
  final ThemeData theme;
  final ColorScheme accent;

  const _AttachmentSheetBody({required this.theme, required this.accent});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(
                  theme.brightness == Brightness.dark ? 0.4 : 0.12),
              blurRadius: 30,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Add attachment',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose a source to attach to your message',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 1.15,
                children: [
                  for (var i = 0; i < _options.length; i++)
                    FadeInUp(
                      duration: const Duration(milliseconds: 280),
                      delay: Duration(milliseconds: i * 45),
                      from: 16,
                      child: _AttachmentCard(
                        option: _options[i],
                        accent: accent,
                        theme: theme,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single large, rounded, tappable card for one attachment source.
class _AttachmentCard extends StatefulWidget {
  final _AttachmentOption option;
  final ColorScheme accent;
  final ThemeData theme;

  const _AttachmentCard({
    required this.option,
    required this.accent,
    required this.theme,
  });

  @override
  State<_AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<_AttachmentCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final accent = widget.accent;
    final option = widget.option;

    return AnimatedScale(
      scale: _pressed ? 0.96 : 1.0,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTapDown: (_) => _setPressed(true),
          onTapCancel: () => _setPressed(false),
          onTapUp: (_) => _setPressed(false),
          onTap: () {
            HapticFeedback.selectionClick();
            Navigator.of(context).pop(option.type);
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withOpacity(0.25),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: accent.primary.withOpacity(0.13),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(option.icon, color: accent.primary, size: 26),
                ),
                const SizedBox(height: 12),
                Text(
                  option.label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  option.subtitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
