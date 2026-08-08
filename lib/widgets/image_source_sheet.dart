import 'package:flutter/material.dart';

import 'attachment_sheet.dart' show AttachmentType;

/// Step 38 — a small, focused variant of [showAttachmentSheet] used only by
/// the OCR / Handwriting Recognition entry points: offers just Camera and
/// Gallery (the only two sources that make sense for scanning a single
/// image), in the same white, rounded, ChatGPT(Android)-style sheet as the
/// main attachment sheet so the two feel like one consistent picker family.
/// Returns the chosen [AttachmentType] (always `.camera` or `.gallery`), or
/// `null` if dismissed without a selection.
Future<AttachmentType?> showImageSourceSheet(
  BuildContext context, {
  required String title,
}) {
  return showModalBottomSheet<AttachmentType>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    elevation: 16,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    builder: (sheetContext) => _ImageSourceSheetContent(title: title),
  );
}

class _ImageSourceSheetContent extends StatelessWidget {
  final String title;
  const _ImageSourceSheetContent({required this.title});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _SourceButton(
                  icon: Icons.photo_camera_rounded,
                  label: 'Camera',
                  onTap: () =>
                      Navigator.of(context).pop(AttachmentType.camera),
                ),
                _SourceButton(
                  icon: Icons.image_rounded,
                  label: 'Gallery',
                  onTap: () =>
                      Navigator.of(context).pop(AttachmentType.gallery),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Same circular-icon-with-label look as the main attachment sheet's
/// `_AttachmentButton`, minus the staggered entrance animation (this sheet
/// only ever has two options, so the extra motion isn't needed).
class _SourceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SourceButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: const Color(0xFFF2F2F3),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            splashColor: Colors.black.withOpacity(0.06),
            highlightColor: Colors.black.withOpacity(0.04),
            onTap: onTap,
            child: SizedBox(
              width: 68,
              height: 68,
              child: Icon(icon, size: 28, color: const Color(0xFF1A1A1A)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Color(0xFF1A1A1A),
          ),
        ),
      ],
    );
  }
}
