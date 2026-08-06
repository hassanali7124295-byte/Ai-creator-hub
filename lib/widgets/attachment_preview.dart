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

  /// Step 22B: true while this attachment is locked for an in-flight send
  /// (processing has started, or the message is being sent). Locked
  /// previews never show a remove button — regardless of [onRemove] — and
  /// are dimmed slightly so it's clear they can no longer be edited.
  /// Defaults to false, so every existing call site (including inside
  /// sent message bubbles) renders exactly as before.
  final bool locked;

  const AttachmentPreview({
    super.key,
    required this.attachment,
    this.onRemove,
    this.locked = false,
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
    // A locked preview never shows a remove affordance, no matter what the
    // caller passed in — this is the one place that guarantee is enforced.
    final effectiveOnRemove = locked ? null : onRemove;

    if (attachment.kind == ChatAttachmentKind.image) {
      return Opacity(
        opacity: locked ? 0.7 : 1.0,
        child: _ImageThumb(
          attachment: attachment,
          icon: _icon,
          onRemove: effectiveOnRemove,
        ),
      );
    }

    return Opacity(
      opacity: locked ? 0.7 : 1.0,
      child: Container(
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
            if (effectiveOnRemove != null) ...[
              const SizedBox(width: 4),
              Material(
                color: Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  onTap: effectiveOnRemove,
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
      ),
    );
  }
}

/// Step 22B: a horizontal, order-preserving row of pending attachments
/// shown above the chat input bar. Multiple images and/or PDFs picked
/// together are laid out here, in the order they were selected.
///
/// Deliberately a fixed-height row rather than a `Wrap`: a stable height
/// means adding or removing an item never changes how tall this widget is,
/// only how wide its scrollable content is — one less thing that can make
/// the input bar above/below it shift. Pair this with an `AnimatedSize`
/// (or similar) at the call site to animate the row's *appearance* and
/// *disappearance* smoothly instead of popping in/out instantly.
class AttachmentPreviewList extends StatelessWidget {
  final List<ChatAttachment> attachments;

  /// See [AttachmentPreview.locked]. Applies to every item in the row —
  /// used to freeze the whole row the instant Send is tapped.
  final bool locked;

  /// Called with the row index of the attachment to remove. Passing null
  /// (e.g. while [locked] is true, or while sending) hides every remove
  /// button in the row.
  final void Function(int index)? onRemoveAt;

  const AttachmentPreviewList({
    super.key,
    required this.attachments,
    this.locked = false,
    this.onRemoveAt,
  });

  static const double _rowHeight = 100;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: _rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: attachments.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final callback = onRemoveAt;
          return Center(
            child: AttachmentPreview(
              // A stable key per underlying file keeps each thumbnail's
              // identity — and any internal state — tied to that specific
              // attachment as the list is reordered by removal, instead of
              // Flutter reusing elements positionally.
              key: ValueKey(
                  '${attachments[index].path}-${attachments[index].name}-$index'),
              attachment: attachments[index],
              locked: locked,
              onRemove:
                  callback == null ? null : () => callback(index),
            ),
          );
        },
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
