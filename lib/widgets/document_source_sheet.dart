import 'package:flutter/material.dart';

import 'attachment_sheet.dart' show AttachmentType;

/// Step 39 — source picker used only by the Document Intelligence entry
/// point: offers Camera, Gallery, and PDF (a document/image can be a photo
/// of a page or an existing PDF file), in the same white, rounded,
/// ChatGPT(Android)-style sheet as [showAttachmentSheet] and Step 38's
/// [showImageSourceSheet] so the whole picker family feels consistent.
/// Returns the chosen [AttachmentType] (`.camera`, `.gallery`, or
/// `.document`), or `null` if dismissed without a selection.
///
/// Deliberately a separate widget from Step 38's `showImageSourceSheet`
/// (which only offers Camera/Gallery, for OCR/Handwriting) rather than
/// modifying it — keeps that Step 38 flow completely untouched.
Future<AttachmentType?> showDocumentSourceSheet(BuildContext context) {
  return showModalBottomSheet<AttachmentType>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    elevation: 16,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    builder: (sheetContext) => const _DocumentSourceSheetContent(),
  );
}

class _DocumentSourceSheetContent extends StatelessWidget {
  const _DocumentSourceSheetContent();

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
            const Text(
              'Analyze Document',
              style: TextStyle(
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
                _SourceButton(
                  icon: Icons.picture_as_pdf_rounded,
                  label: 'PDF',
                  onTap: () =>
                      Navigator.of(context).pop(AttachmentType.document),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Same circular-icon-with-label look used by the main attachment sheet and
/// Step 38's image source sheet.
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
