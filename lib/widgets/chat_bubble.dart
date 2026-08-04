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

class _ChatBubbleState extends State<ChatBubble> {
  // Local-only UI feedback (not persisted) — a lightweight way to let
  // people react to a reply without a backend to send it to.
  _Feedback _feedback = _Feedback.none;

  // --- Streaming reveal state -------------------------------------------
  Timer? _streamTimer;
  int _visibleChars = 0;
  bool _streaming = false;

  // The floating action pill under an AI reply always shows the same
  // compact set (Copy, Speak, More) — matching the ChatGPT Android
  // pattern of never surfacing every action at once. The remaining
  // actions (Share, Regenerate, Like, Delete) live in the "More" popup.
  final GlobalKey _moreButtonKey = GlobalKey();

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
    if (_feedback == _Feedback.liked) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thanks for the feedback!'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  /// Opens the "More" popup menu with the overflow actions (Share,
  /// Regenerate, Like, Delete), anchored under the More button itself.
  /// Disabled actions (e.g. Regenerate on an older reply) render dimmed
  /// and inert, same as their inline counterparts did before.
  void _openMoreMenu() {
    HapticFeedback.selectionClick();
    final renderBox =
        _moreButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;

    RelativeRect position;
    if (renderBox != null && overlayBox != null) {
      final topLeft =
          renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
      final bottomRight = renderBox.localToGlobal(
        renderBox.size.bottomRight(Offset.zero),
        ancestor: overlayBox,
      );
      position = RelativeRect.fromLTRB(
        topLeft.dx,
        bottomRight.dy + 6,
        overlayBox.size.width - bottomRight.dx,
        0,
      );
    } else {
      position = const RelativeRect.fromLTRB(24, 100, 24, 0);
    }

    _showMoreMenu(
      context: context,
      position: position,
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

    // The compact action pill appears automatically for any settled AI
    // reply, as soon as streaming finishes — no tap required. Long-press-
    // to-copy for other bubble types is still wired up one level up, in
    // the screen's list itemBuilder.
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
                        moreButtonKey: _moreButtonKey,
                        onCopy: widget.onCopy,
                        onReadAloud: widget.onReadAloud,
                        onMore: _openMoreMenu,
                        isSpeaking: widget.isSpeaking,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Shows the ChatGPT-Android-style "More" popup menu with the actions
/// that don't fit in the compact pill: Share, Regenerate, Like, Delete.
/// Anchored to [position] (computed from the More button's on-screen
/// location), with a rounded, elevated, fade+scale popup — Flutter's
/// built-in menu route animation — rather than a bottom sheet. Each item
/// renders dimmed and inert when its callback is `null` (e.g. Regenerate
/// on anything but the latest reply).
Future<void> _showMoreMenu({
  required BuildContext context,
  required RelativeRect position,
  required VoidCallback? onShare,
  required VoidCallback? onRegenerate,
  required VoidCallback onLike,
  required bool liked,
  required VoidCallback? onDelete,
}) async {
  final theme = Theme.of(context);
  final isDark = theme.brightness == Brightness.dark;
  final popupSurface = isDark ? const Color(0xFF2C2C2E) : Colors.white;

  final selected = await showMenu<_MoreMenuAction>(
    context: context,
    position: position,
    color: popupSurface,
    surfaceTintColor: Colors.transparent,
    elevation: 12,
    shadowColor: Colors.black.withOpacity(0.25),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
    ),
    constraints: const BoxConstraints(minWidth: 210),
    padding: const EdgeInsets.symmetric(vertical: 8),
    items: [
      _MoreMenuTile.item(
        value: _MoreMenuAction.share,
        icon: Icons.ios_share_rounded,
        label: 'Share',
        enabled: onShare != null,
      ),
      _MoreMenuTile.item(
        value: _MoreMenuAction.regenerate,
        icon: Icons.refresh_rounded,
        label: 'Regenerate',
        enabled: onRegenerate != null,
      ),
      _MoreMenuTile.item(
        value: _MoreMenuAction.like,
        icon: liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
        label: liked ? 'Liked' : 'Like',
        enabled: true,
        liked: liked,
      ),
      _MoreMenuTile.item(
        value: _MoreMenuAction.delete,
        icon: Icons.delete_outline_rounded,
        label: 'Delete',
        enabled: onDelete != null,
        destructive: true,
      ),
    ],
  );

  switch (selected) {
    case _MoreMenuAction.share:
      onShare?.call();
      break;
    case _MoreMenuAction.regenerate:
      onRegenerate?.call();
      break;
    case _MoreMenuAction.like:
      onLike();
      break;
    case _MoreMenuAction.delete:
      onDelete?.call();
      break;
    case null:
      break;
  }
}

enum _MoreMenuAction { share, regenerate, like, delete }

/// A single row inside the "More" popup menu — icon, label, generous
/// padding. Delete renders red; Like renders green and filled once
/// active; everything else renders a neutral dark grey. Disabled items
/// (e.g. Regenerate on an older reply) render dimmed and inert.
class _MoreMenuTile {
  static PopupMenuItem<_MoreMenuAction> item({
    required _MoreMenuAction value,
    required IconData icon,
    required String label,
    required bool enabled,
    bool destructive = false,
    bool liked = false,
  }) {
    return PopupMenuItem<_MoreMenuAction>(
      value: value,
      enabled: enabled,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
      height: 46,
      child: Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final isDark = theme.brightness == Brightness.dark;
          final neutral = isDark ? Colors.grey.shade300 : Colors.grey.shade800;
          final color = !enabled
              ? neutral.withOpacity(0.35)
              : destructive
                  ? const Color(0xFFE53935)
                  : liked
                      ? const Color(0xFF34A853)
                      : neutral;

          return Row(
            children: [
              Icon(icon, size: 21, color: color),
              const SizedBox(width: 14),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The floating action pill beneath an AI reply — always the compact
/// ChatGPT-Android set (Copy, Speak, More); Share/Regenerate/Like/Delete
/// live behind the More popup so all six actions are never shown at
/// once. A soft, borderless grey pill with a gentle shadow, fading in
/// once the reply finishes streaming.
class _ActionRow extends StatelessWidget {
  final Key moreButtonKey;
  final VoidCallback? onCopy;
  final VoidCallback? onReadAloud;
  final VoidCallback onMore;
  final bool isSpeaking;

  const _ActionRow({
    required this.moreButtonKey,
    required this.onCopy,
    required this.onReadAloud,
    required this.onMore,
    required this.isSpeaking,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2C) : const Color(0xFFF1F1F3),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.22 : 0.08),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionIcon(
            icon: Icons.copy_rounded,
            tooltip: 'Copy',
            onTap: onCopy,
          ),
          const SizedBox(width: 14),
          _ActionIcon(
            icon: isSpeaking
                ? Icons.stop_circle_rounded
                : Icons.volume_up_rounded,
            tooltip: isSpeaking ? 'Stop' : 'Speak',
            onTap: onReadAloud,
            active: isSpeaking,
          ),
          const SizedBox(width: 14),
          _ActionIcon(
            key: moreButtonKey,
            icon: Icons.more_horiz_rounded,
            tooltip: 'More',
            onTap: onMore,
          ),
        ],
      ),
    );
  }
}

/// A small, low-emphasis icon button used in the AI-reply action pill.
/// Dark grey by default (never blue), with a small circular hover/ripple
/// and an AnimatedScale press effect. Renders dimmed and inert when
/// [onTap] is null.
class _ActionIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  const _ActionIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
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
    final isDark = theme.brightness == Brightness.dark;
    final onTap = widget.onTap;
    final neutral = isDark ? Colors.grey.shade300 : Colors.grey.shade700;
    final color = onTap == null
        ? neutral.withOpacity(0.35)
        : widget.active
            ? theme.colorScheme.primary
            : neutral;

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
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              splashColor: (isDark ? Colors.white : Colors.black)
                  .withOpacity(0.08),
              highlightColor: (isDark ? Colors.white : Colors.black)
                  .withOpacity(0.05),
              onTap: onTap == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      onTap();
                    },
              child: Padding(
                // ~36-38dp touch target (21 icon + 8*2 padding).
                padding: const EdgeInsets.all(8),
                child: Icon(widget.icon, size: 21, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
