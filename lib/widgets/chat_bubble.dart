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

  /// Removes this message from the conversation. Surfaced only inside the
  /// "More" menu (Step 18.2).
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

enum _Feedback { none, liked, disliked }

/// Actions available inside the "More" popup menu (Step 18.2).
enum _MoreAction { share, regenerate, like, dislike, delete }

class _ChatBubbleState extends State<ChatBubble> {
  // Local-only UI feedback (not persisted) — a lightweight way to let
  // people react to a reply without a backend to send it to.
  _Feedback _feedback = _Feedback.none;

  // --- Streaming reveal state -------------------------------------------
  Timer? _streamTimer;
  int _visibleChars = 0;
  bool _streaming = false;

  // Step 12.4: the action row (copy/share/regenerate/etc.) is now hidden
  // by default and only shown once the person taps or long-presses the
  // AI reply — instead of appearing automatically once streaming ends.
  bool _actionsVisible = false;

  // Step 18.2: anchor for the "More" popup menu so it opens right below
  // the "..." button instead of at a fixed screen position.
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
      _actionsVisible = false;
      _startOrSkipStreaming();
    }
  }

  void _toggleActions() {
    HapticFeedback.selectionClick();
    setState(() => _actionsVisible = !_actionsVisible);
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

  // Step 18.2: the secondary actions (Share, Regenerate, Like, Dislike,
  // Delete) now live behind a single "More" button instead of being shown
  // inline, ChatGPT-style. Opens as a rounded popup menu anchored to the
  // "..." button.
  Future<void> _showMoreMenu() async {
    HapticFeedback.selectionClick();
    final theme = Theme.of(context);
    final renderBox =
        _moreButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlay == null) return;

    final buttonTopLeft =
        renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final position = RelativeRect.fromLTRB(
      buttonTopLeft.dx,
      buttonTopLeft.dy + renderBox.size.height + 6,
      overlay.size.width - (buttonTopLeft.dx + renderBox.size.width),
      0,
    );

    final selection = await showMenu<_MoreAction>(
      context: context,
      position: position,
      color: theme.colorScheme.surfaceContainerHigh,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      constraints: const BoxConstraints(minWidth: 200),
      items: [
        _menuItem(
          theme,
          action: _MoreAction.share,
          icon: Icons.ios_share_outlined,
          label: 'Share',
          enabled: widget.onShare != null,
        ),
        _menuItem(
          theme,
          action: _MoreAction.regenerate,
          icon: Icons.refresh_outlined,
          label: 'Regenerate',
          enabled: widget.onRegenerate != null,
        ),
        _menuItem(
          theme,
          action: _MoreAction.like,
          icon: _feedback == _Feedback.liked
              ? Icons.thumb_up_rounded
              : Icons.thumb_up_outlined,
          label: 'Like',
          active: _feedback == _Feedback.liked,
        ),
        _menuItem(
          theme,
          action: _MoreAction.dislike,
          icon: _feedback == _Feedback.disliked
              ? Icons.thumb_down_rounded
              : Icons.thumb_down_outlined,
          label: 'Dislike',
          active: _feedback == _Feedback.disliked,
        ),
        const PopupMenuDivider(height: 8),
        _menuItem(
          theme,
          action: _MoreAction.delete,
          icon: Icons.delete_outline_rounded,
          label: 'Delete',
          enabled: widget.onDelete != null,
          destructive: true,
        ),
      ],
    );

    if (!mounted || selection == null) return;
    switch (selection) {
      case _MoreAction.share:
        widget.onShare?.call();
        break;
      case _MoreAction.regenerate:
        widget.onRegenerate?.call();
        break;
      case _MoreAction.like:
        _toggleLike();
        break;
      case _MoreAction.dislike:
        _toggleDislike();
        break;
      case _MoreAction.delete:
        widget.onDelete?.call();
        break;
    }
  }

  PopupMenuItem<_MoreAction> _menuItem(
    ThemeData theme, {
    required _MoreAction action,
    required IconData icon,
    required String label,
    bool enabled = true,
    bool active = false,
    bool destructive = false,
  }) {
    final color = !enabled
        ? theme.colorScheme.onSurfaceVariant.withOpacity(0.35)
        : destructive
            ? theme.colorScheme.error
            : active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant;

    return PopupMenuItem<_MoreAction>(
      value: action,
      enabled: enabled,
      height: 44,
      child: Row(
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(width: 12),
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
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
    final showActions = isAiReply && !_streaming && _actionsVisible;

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
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Wrap(
                  spacing: 2,
                  children: [
                    // Step 18.2: the row is trimmed down to the three
                    // primary actions — Copy, Speak, More — ChatGPT-style.
                    // Share/Regenerate/Like/Dislike/Delete now live inside
                    // the "More" popup menu.
                    _ActionIcon(
                      icon: Icons.copy_outlined,
                      tooltip: 'Copy',
                      onTap: widget.onCopy,
                    ),
                    _ActionIcon(
                      icon: widget.isSpeaking
                          ? Icons.stop_circle_rounded
                          : Icons.volume_up_outlined,
                      tooltip: widget.isSpeaking ? 'Stop' : 'Speak',
                      onTap: widget.onReadAloud,
                      active: widget.isSpeaking,
                    ),
                    _ActionIcon(
                      key: _moreButtonKey,
                      icon: Icons.more_horiz_rounded,
                      tooltip: 'More',
                      onTap: _showMoreMenu,
                    ),
                  ],
                ),
              ),
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
    final onTap = widget.onTap;
    final color = onTap == null
        ? theme.colorScheme.onSurfaceVariant.withOpacity(0.35)
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
