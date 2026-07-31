import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/chat_message.dart';
import 'attachment_preview.dart';

/// A single chat bubble, aligned right (user) or left (AI), with
/// distinct colors, Markdown rendering for AI replies, and an error
/// state for failed AI responses.
class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;

    final bubbleColor = message.isError
        ? theme.colorScheme.errorContainer
        : isUser
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHigh;

    final textColor = message.isError
        ? theme.colorScheme.onErrorContainer
        : isUser
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurface;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.isError)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 16,
                      color: textColor,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Something went wrong',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            if (message.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final attachment in message.attachments)
                      AttachmentPreview(attachment: attachment),
                  ],
                ),
              ),
            // AI replies render as Markdown (bold, lists, code blocks, etc.);
            // user messages and error text stay as plain text.
            if (!isUser && !message.isError)
              MarkdownBody(
                data: message.text,
                selectable: true,
                styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                  p: theme.textTheme.bodyMedium?.copyWith(color: textColor),
                  code: theme.textTheme.bodySmall?.copyWith(
                    color: textColor,
                    backgroundColor:
                        theme.colorScheme.surfaceContainerHighest,
                    fontFamily: 'monospace',
                  ),
                  codeblockDecoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              )
            else
              Text(
                message.text,
                style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
              ),
          ],
        ),
      ),
    );
  }
}
