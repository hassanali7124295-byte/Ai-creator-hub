import 'dart:io';

import 'package:flutter/material.dart';

import '../models/chat_attachment.dart';

/// Renders a [ChatAttachment] as either an image thumbnail (with a
/// graceful fallback if the underlying file is gone — e.g. after an app
/// restart) or a compact icon-and-name chip for PDFs/other files.
///
/// Used both for the pending-attachment preview above the chat input bar
/// (with [onRemove]) and inside sent message bubbles (without it).
class AttachmentPreview extends StatelessWidget {
  final ChatAttachment attachment;
  final VoidCallback? onRemove;

  const AttachmentPreview({
    super.key,
    required this.attachment,
    this.onRemove,
  });

  IconData get _icon => switch (attachment.kind) {
        ChatAttachmentKind.image => Icons.image_outlined,
        ChatAttachmentKind.pdf => Icons.picture_as_pdf_outlined,
        ChatAttachmentKind.file => Icons.insert_drive_file_outlined,
      };

  String get _sizeLabel {
    final bytes = attachment.sizeBytes;
    if (bytes <= 0) return '';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (attachment.kind == ChatAttachmentKind.image) {
      return _ImageThumb(
        attachment: attachment,
        icon: _icon,
        onRemove: onRemove,
      );
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachment.name,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (_sizeLabel.isNotEmpty)
                  Text(
                    _sizeLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 4),
            Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded,
                      size: 16, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ImageThumb extends StatelessWidget {
  final ChatAttachment attachment;
  final IconData icon;
  final VoidCallback? onRemove;

  const _ImageThumb({
    required this.attachment,
    required this.icon,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final path = attachment.path;

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: path != null
              ? Image.file(
                  File(path),
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _fallback(theme),
                )
              : _fallback(theme),
        ),
        if (onRemove != null)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _fallback(ThemeData theme) {
    return Container(
      width: 96,
      height: 96,
      color: theme.colorScheme.surfaceContainerHigh,
      child: Icon(icon, color: theme.colorScheme.onSurfaceVariant),
    );
  }
}
