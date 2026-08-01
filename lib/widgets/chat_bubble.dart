import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/chat_message.dart';
import 'attachment_preview.dart';

/// A single chat bubble, aligned right (user) or left (AI), with distinct
/// colors, Markdown rendering for AI replies, an error state for failed
/// AI responses, and — for successful AI replies only — a row of quick
/// actions (copy, share, regenerate, read aloud, like/dislike) shown
/// just below the bubble.
class ChatBubble extends StatefulWidget {
  final ChatMessage message;

  /// Copies [message.text] to the clipboard. Long-pressing any bubble
  /// (wired up by the screen) does this too; this is the explicit button.
  final VoidCallback? onCopy;

  /// Opens the system share sheet with [message.text].
  final VoidCallback? onShare;

  /// Re-asks Gemini for a fresh answer to the prompt behind this reply.
  /// Only wired up for the most recent AI reply — `null` disables the
  /// button (dimmed) for earlier ones.
  final VoidCallback? onRegenerate;

  /// Starts or stops text-to-speech playback of this message.
  final VoidCallback? onReadAloud;

  /// Whether this specific message is the one currently being read aloud.
  final bool isSpeaking;

  /// When true (and this is a fresh, non-error AI reply), the reply text
  /// is revealed gradually — a lightweight, client-side "streaming" effect
  /// — instead of appearing all at once. Historical replies loaded from
  /// storage pass `false` so they render instantly, as before.
  final bool animate;

  /// Invoked on every reveal tick while streaming, so the screen can keep
  /// the list pinned to the bottom as the reply grows. Safe to leave null.
  final VoidCallback? onStreamTick;

  const ChatBubble({
    super.key,
    required this.message,
    this.onCopy,
    this.onShare,
    this.onRegenerate,
    this.onReadAloud,
    this.isSpeaking = false,
    this.animate = false,
    this.onStreamTick,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

enum _Feedback { none, liked, disliked }

class _ChatBubbleState extends State<ChatBubble> {
  // Local-only UI feedback (not persisted) — a lightweight way to let
  // people react to a reply without a backend to send it to.
  _Feedback _feedback = _Feedback.none;

  // --- Streaming reveal state -------------------------------------------
  Timer? _streamTimer;
  int _visibleChars = 0;
  bool _streaming = false;

  bool get _isAiReply => !widget.message.isUser && !widget.message.isError;

  @override
  void initState() {
    super.initState();
    _startOrSkipStreaming();
  }

  @override
  void didUpdateWidget(covariant ChatBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different message landed in this slot (e.g. Regenerate swapped
    // the reply at the same list index) — restart the reveal for it.
    if (!identical(oldWidget.message, widget.message)) {
      _streamTimer?.cancel();
      _startOrSkipStreaming();
    }
  }

  void _startOrSkipStreaming() {
    final length = widget.message.text.length;
    if (_isAiReply && widget.animate && length > 0) {
      _visibleChars = 0;
      _streaming = true;
      const chunk = 4; // characters revealed per tick — smooth, cheap
      _streamTimer = Timer.periodic(const Duration(milliseconds: 14), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _visibleChars += chunk;
          if (_visibleChars > length) _visibleChars = length;
        });
        widget.onStreamTick?.call();
        if (_visibleChars >= length) {
          timer.cancel();
          setState(() => _streaming = false);
        }
      });
    } else {
      _visibleChars = length;
      _streaming = false;
    }
  }

  @override
  void dispose() {
    _streamTimer?.cancel();
    super.dispose();
  }

  void _toggleLike() {
    setState(() {
      _feedback = _feedback == _Feedback.liked ? _Feedback.none : _Feedback.liked;
    });
    _showFeedbackSnack();
  }

  void _toggleDislike() {
    setState(() {
      _feedback =
          _feedback == _Feedback.disliked ? _Feedback.none : _Feedback.disliked;
    });
    _showFeedbackSnack();
  }

  void _showFeedbackSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Thanks for the feedback!'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isUser = message.isUser;
    final isAiReply = _isAiReply;

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

    // While streaming, only the revealed slice of the reply is rendered.
    int safeVisible = _visibleChars;
    if (safeVisible > message.text.length) safeVisible = message.text.length;
    if (safeVisible < 0) safeVisible = 0;
    final displayedText =
        isAiReply ? message.text.substring(0, safeVisible) : message.text;

    // Actions only appear once a reply has fully streamed in, matching the
    // feel of premium AI chat apps and avoiding layout churn mid-reveal.
    final showActions = isAiReply && !_streaming;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: isAiReply
                ? const EdgeInsets.symmetric(horizontal: 20, vertical: 16)
                : const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.8,
            ),
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(isUser ? 20 : 6),
                bottomRight: Radius.circular(isUser ? 6 : 20),
              ),
              border: isAiReply
                  ? Border.all(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                      width: 1,
                    )
                  : null,
              boxShadow: isAiReply
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.shadow.withOpacity(0.06),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
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
                // AI replies render as Markdown (bold, lists, code blocks,
                // etc.) at a slightly larger size with roomier line
                // spacing for readability; user/error text stays plain.
                if (isAiReply)
                  MarkdownBody(
                    data: displayedText,
                    selectable: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                      p: theme.textTheme.bodyLarge?.copyWith(
                        color: textColor,
                        fontSize: 17.5,
                        height: 1.6,
                        letterSpacing: 0.1,
                      ),
                      code: theme.textTheme.bodySmall?.copyWith(
                        color: textColor,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        fontFamily: 'monospace',
                      ),
                      codeblockDecoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      codeblockPadding: const EdgeInsets.all(12),
                      blockSpacing: 10,
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
          if (showActions)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Wrap(
                  spacing: 1,
                  children: [
                    _ActionIcon(
                      icon: Icons.copy_rounded,
                      tooltip: 'Copy',
                      onTap: widget.onCopy,
                    ),
                    _ActionIcon(
                      icon: Icons.ios_share_rounded,
                      tooltip: 'Share',
                      onTap: widget.onShare,
                    ),
                    _ActionIcon(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Regenerate',
                      onTap: widget.onRegenerate,
                    ),
                    _ActionIcon(
                      icon: widget.isSpeaking
                          ? Icons.stop_circle_rounded
                          : Icons.volume_up_rounded,
                      tooltip: widget.isSpeaking ? 'Stop' : 'Read aloud',
                      onTap: widget.onReadAloud,
                      active: widget.isSpeaking,
                    ),
                    _ActionIcon(
                      icon: _feedback == _Feedback.liked
                          ? Icons.thumb_up_rounded
                          : Icons.thumb_up_outlined,
                      tooltip: 'Like',
                      onTap: _toggleLike,
                      active: _feedback == _Feedback.liked,
                    ),
                    _ActionIcon(
                      icon: _feedback == _Feedback.disliked
                          ? Icons.thumb_down_rounded
                          : Icons.thumb_down_outlined,
                      tooltip: 'Dislike',
                      onTap: _toggleDislike,
                      active: _feedback == _Feedback.disliked,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small, low-emphasis icon button used in the AI-reply action row.
/// Renders dimmed and inert when [onTap] is null — e.g. "Regenerate" on
/// any reply but the most recent one.
class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = onTap == null
        ? theme.colorScheme.onSurfaceVariant.withOpacity(0.35)
        : active
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}
