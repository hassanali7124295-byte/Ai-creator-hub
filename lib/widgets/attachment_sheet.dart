import 'package:flutter/material.dart';

/// The kind of attachment source the user picked from [showAttachmentSheet].
enum AttachmentType { gallery, camera, document, file }

class _AttachmentOption {
  final AttachmentType type;
  final IconData icon;
  final String label;
  const _AttachmentOption(this.type, this.icon, this.label);
}

const List<_AttachmentOption> _options = [
  _AttachmentOption(AttachmentType.gallery, Icons.photo_outlined, 'Gallery'),
  _AttachmentOption(
      AttachmentType.camera, Icons.photo_camera_outlined, 'Camera'),
  _AttachmentOption(
      AttachmentType.document, Icons.picture_as_pdf_outlined, 'Document (PDF)'),
  _AttachmentOption(AttachmentType.file, Icons.attach_file_rounded, 'File'),
];

/// Shows a modern bottom sheet letting the user choose an attachment
/// source (Gallery, Camera, Document, File). Returns the chosen
/// [AttachmentType], or `null` if the sheet was dismissed.
Future<AttachmentType?> showAttachmentSheet(BuildContext context) {
  final theme = Theme.of(context);

  return showModalBottomSheet<AttachmentType>(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
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
              const SizedBox(height: 18),
              Text(
                'Add attachment',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              for (final option in _options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(option.icon, color: theme.colorScheme.primary),
                  ),
                  title: Text(option.label, style: theme.textTheme.bodyLarge),
                  onTap: () => Navigator.of(sheetContext).pop(option.type),
                ),
            ],
          ),
        ),
      );
    },
  );
}
