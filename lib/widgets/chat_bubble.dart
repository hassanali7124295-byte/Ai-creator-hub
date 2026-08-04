import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/theme/chat_palette.dart';
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

  /// Deletes this message from the conversation.
  final VoidCallback? onDelete;

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
    this.onDelete,
    this.isSpeaking = false,
    this.animate = false,
    this.onStreamTick,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

enum _Feedback { none, liked }

/// Step 18.2: the AI action row now has two densities — [full] shows every
/// action (Copy, Share, Regenerate, Speak, Like, Delete), [compact] shows
/// just Copy, Speak, and a "More" overflow button that reveals the rest in
/// a bottom sheet, matching the ChatGPT/Claude pattern of collapsing the
/// row down to essentials once the person has engaged with a reply.
enum _ActionDensity { full, compact }

class _ChatBubbleState extends State<ChatBubble> {
  // Local-only UI feedback (not persisted) — a lightweight way to let
  // people react to a reply without a backend to send it to.
  _Feedback _feedback = _Feedback.none;

  // --- Streaming reveal state -------------------------------------------
  Timer? _streamTimer;
  int _visibleChars = 0;
  bool _streaming = false;

  // Step 18.2: the action row now appears in full as soon as a reply is
  // done streaming (no tap required), and collapses to Copy/Speak/More
  // the first time the person taps the reply — tapping again toggles
  // back, same as before.
  _ActionDensity _density = _ActionDensity.full;

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
    // the reply at the same list index) — restart the reveal for it and
    // hide any actions left showing from the previous message.
    if (!identical(oldWidget.message, widget.message)) {
      _streamTimer?.cancel();
      _density = _ActionDensity.full;
      _startOrSkipStreaming();
    }
  }

  void _toggleActions() {
    HapticFeedback.selectionClick();
    setState(() {
      _density = _density == _ActionDensity.full
          ? _ActionDensity.compact
          : _ActionDensity.full;
    });
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
    if (_feedback == _Feedback.liked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thanks for the feedback!'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// Opens the "More" bottom sheet with the overflow actions (Share,
  /// Regenerate, Like, Delete) — used when the row is in its compact
  /// density. Disabled actions (e.g. Regenerate on an older reply) render
  /// dimmed and inert, same as their inline counterparts did before.
  void _openMoreMenu() {
    HapticFeedback.selectionClick();
    _showMoreMenu(
      context: context,
      onShare: widget.onShare,
      onRegenerate: widget.onRegenerate,
      onLike: _toggleLike,
      liked: _feedback == _Feedback.liked,
      onDelete: widget.onDelete,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    final isUser = message.isUser;
    final isAiReply = _isAiReply;

    final isDark = theme.brightness == Brightness.dark;

    // Step 12.4: the user bubble now uses a flat, lighter "sea green"
    // instead of the theme's punchier primary — no gradient, no heavy
    // solid block of saturated color, just a soft, muted fill.
    final bubbleColor = message.isError
        ? theme.colorScheme.errorContainer
        : isUser
            ? ChatPalette.userBubble
            : theme.colorScheme.surfaceContainerHigh;

    final textColor = message.isError
        ? theme.colorScheme.onErrorContainer
        : isUser
            ? Colors.white
            : theme.colorScheme.onSurface;

    // While streaming, only the revealed slice of the reply is rendered.
    int safeVisible = _visibleChars;
    if (safeVisible > message.text.length) safeVisible = message.text.length;
    if (safeVisible < 0) safeVisible = 0;
    final displayedText =
        isAiReply ? message.text.substring(0, safeVisible) : message.text;

    // Step 12.4: actions are hidden by default and only appear once the
    // person explicitly taps or long-presses the reply (see
    // `_toggleActions`) — no more auto-reveal once streaming finishes.
    // Step 18.2: the row is visible for any settled AI reply — full
    // density as soon as streaming finishes, no tap required — and only
    // its density (full vs. compact) is toggled by tapping the reply.
    final showActions = isAiReply && !_streaming;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            // Step 12.4: tapping or long-pressing an AI reply toggles its
            // action row; user/error bubbles ignore both (long-press-to-
            // copy for those is still wired up one level up, in the
            // screen's list itemBuilder).
            onTap: isAiReply ? _toggleActions : null,
            onLongPress: isAiReply ? _toggleActions : null,
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              padding: isAiReply
                  ? const EdgeInsets.symmetric(horizontal: 20, vertical: 16)
                  : const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              constraints: BoxConstraints(
                // Step 12.4: the user bubble is now noticeably smaller —
                // about 68% of the screen — instead of sharing the AI
                // reply's roomier 80% ceiling.
                maxWidth: MediaQuery.of(context).size.width *
                    (isUser ? 0.68 : 0.8),
              ),
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(24),
                  topRight: const Radius.circular(24),
                  bottomLeft: Radius.circular(isUser ? 24 : 8),
                  bottomRight: Radius.circular(isUser ? 8 : 24),
                ),
                border: isAiReply
                    ? Border.all(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                        width: 1,
                      )
                    : null,
                // Step 12.4: shadows across the board are now just a very
                // soft touch — no more visible colored glow under the
                // user bubble.
                boxShadow: isAiReply
                    ? [
                        BoxShadow(
                          color: theme.colorScheme.shadow
                              .withOpacity(isDark ? 0.0 : 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : isUser
                        ? [
                            BoxShadow(
                              color: Colors.black.withOpacity(isDark ? 0.10 : 0.08),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
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
                      h1: theme.textTheme.titleLarge?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                      ),
                      h2: theme.textTheme.titleMedium?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                      ),
                      h3: theme.textTheme.titleSmall?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                      ),
                      blockquoteDecoration: BoxDecoration(
                        color: theme.colorScheme.primary.withOpacity(0.06),
                        border: Border(
                          left: BorderSide(
                            color: theme.colorScheme.primary.withOpacity(0.5),
                            width: 3,
                          ),
                        ),
                      ),
                      blockquotePadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      tableHead: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w700,
                      ),
                      tableBody: theme.textTheme.bodyMedium?.copyWith(
                        color: textColor,
                      ),
                      tableBorder: TableBorder.all(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      tableCellsPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      horizontalRuleDecoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                          ),
                        ),
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
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topLeft,
            child: !showActions
                ? const SizedBox.shrink()
                : AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: showActions ? 1 : 0,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, left: 2),
                      child: _ActionRow(
                        density: _density,
                        onCopy: widget.onCopy,
                        onShare: widget.onShare,
                        onRegenerate: widget.onRegenerate,
                        onReadAloud: widget.onReadAloud,
                        onDelete: widget.onDelete,
                        onMore: _openMoreMenu,
                        isSpeaking: widget.isSpeaking,
                        liked: _feedback == _Feedback.liked,
                        onToggleLike: _toggleLike,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shows the ChatGPT/Claude-style overflow sheet with the actions that
/// don't fit in the compact row: Share, Regenerate, Like, Delete. Each row
/// renders dimmed and inert when its callback is `null` (e.g. Regenerate
/// on anything but the latest reply).
Future<void> _showMoreMenu({
  required BuildContext context,
  required VoidCallback? onShare,
  required VoidCallback? onRegenerate,
  required VoidCallback onLike,
  required bool liked,
  required VoidCallback? onDelete,
}) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: theme.colorScheme.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              const SizedBox(height: 10),
              _MoreMenuTile(
                icon: Icons.ios_share_outlined,
                label: 'Share',
                onTap: onShare == null
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        onShare();
                      },
              ),
              _MoreMenuTile(
                icon: Icons.refresh_rounded,
                label: 'Regenerate',
                onTap: onRegenerate == null
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        onRegenerate();
                      },
              ),
              _MoreMenuTile(
                icon: liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
                label: liked ? 'Liked' : 'Like',
                active: liked,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  onLike();
                },
              ),
              _MoreMenuTile(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                destructive: true,
                onTap: onDelete == null
                    ? null
                    : () {
                        Navigator.of(sheetContext).pop();
                        onDelete();
                      },
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// A single row in the "More" overflow sheet — icon, label, and a subtle
/// pressed state, styled to match [showAttachmentSheet] for a consistent,
/// premium feel across the app's bottom sheets.
class _MoreMenuTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool destructive;

  const _MoreMenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = onTap == null;
    final color = disabled
        ? theme.colorScheme.onSurfaceVariant.withOpacity(0.35)
        : destructive
            ? theme.colorScheme.error
            : active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 16),
              Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pill-shaped action row beneath an AI reply. Renders either the
/// [_ActionDensity.full] set (Copy, Share, Regenerate, Speak, Like,
/// Delete) or the [_ActionDensity.compact] set (Copy, Speak, More) with a
/// cross-fade between the two, matching the premium, minimal icon-row
/// pattern used by ChatGPT and Claude.
class _ActionRow extends StatelessWidget {
  final _ActionDensity density;
  final VoidCallback? onCopy;
  final VoidCallback? onShare;
  final VoidCallback? onRegenerate;
  final VoidCallback? onReadAloud;
  final VoidCallback? onDelete;
  final VoidCallback onMore;
  final bool isSpeaking;
  final bool liked;
  final VoidCallback onToggleLike;

  const _ActionRow({
    required this.density,
    required this.onCopy,
    required this.onShare,
    required this.onRegenerate,
    required this.onReadAloud,
    required this.onDelete,
    required this.onMore,
    required this.isSpeaking,
    required this.liked,
    required this.onToggleLike,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final speakIcon = _ActionIcon(
      icon: isSpeaking ? Icons.stop_circle_rounded : Icons.volume_up_outlined,
      tooltip: isSpeaking ? 'Stop' : 'Speak',
      onTap: onReadAloud,
      active: isSpeaking,
    );
    final copyIcon = _ActionIcon(
      icon: Icons.copy_outlined,
      tooltip: 'Copy',
      onTap: onCopy,
    );

    final children = density == _ActionDensity.full
        ? [
            copyIcon,
            _ActionIcon(
              icon: Icons.ios_share_outlined,
              tooltip: 'Share',
              onTap: onShare,
            ),
            _ActionIcon(
              icon: Icons.refresh_outlined,
              tooltip: 'Regenerate',
              onTap: onRegenerate,
            ),
            speakIcon,
            _ActionIcon(
              icon: liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
              tooltip: 'Like',
              onTap: onToggleLike,
              active: liked,
            ),
            _ActionIcon(
              icon: Icons.delete_outline_rounded,
              tooltip: 'Delete',
              onTap: onDelete,
              destructive: true,
            ),
          ]
        : [
            copyIcon,
            speakIcon,
            _ActionIcon(
              icon: Icons.more_horiz_rounded,
              tooltip: 'More',
              onTap: onMore,
            ),
          ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.25),
          width: 1,
        ),
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axis: Axis.horizontal,
            child: child,
          ),
        ),
        child: Row(
          key: ValueKey(density),
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

/// A small, low-emphasis icon button used in the AI-reply action row.
/// Renders dimmed and inert when [onTap] is null — e.g. "Regenerate" on
/// any reply but the most recent one.
class _ActionIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final bool destructive;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.destructive = false,
  });

  @override
  State<_ActionIcon> createState() => _ActionIconState();
}

class _ActionIconState extends State<_ActionIcon> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null) return;
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onTap = widget.onTap;
    final color = onTap == null
        ? theme.colorScheme.onSurfaceVariant.withOpacity(0.35)
        : widget.destructive
            ? theme.colorScheme.error
            : widget.active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: widget.tooltip,
      child: GestureDetector(
        onTapDown: (_) => _setPressed(true),
        onTapCancel: () => _setPressed(false),
        onTapUp: (_) => _setPressed(false),
        child: AnimatedScale(
          scale: _pressed ? 0.82 : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: widget.active
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.primary.withOpacity(0.28),
                        blurRadius: 12,
                        spreadRadius: 0.5,
                      ),
                    ]
                  : null,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                splashColor: theme.colorScheme.primary.withOpacity(0.14),
                highlightColor: theme.colorScheme.primary.withOpacity(0.08),
                onTap: onTap == null
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        onTap();
                      },
                child: Padding(
                  // 40dp min touch target (18 icon + 11*2 padding = 40).
                  padding: const EdgeInsets.all(11),
                  child: Icon(widget.icon, size: 18, color: color),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
