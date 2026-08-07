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

  /// Re-asks Gemini for this same reply after it failed (Step 26 —
  /// "Retry"). Only shown for error bubbles, and only wired up for the
  /// most recent one — `null` renders no retry affordance at all.
  final VoidCallback? onRetry;

  /// Whether this specific message is the one currently being read aloud.
  final bool isSpeaking;

  /// When true (and this is a fresh, non-error AI reply), the reply text
  /// is revealed gradually — a lightweight, client-side "streaming" effect
  /// — instead of appearing all at once. Historical replies loaded from
  /// storage pass `false` so they render instantly, as before. Ignored
  /// while [isLive] is true (see below).
  final bool animate;

  /// Step 26: true while this exact message is being filled in live,
  /// chunk-by-chunk, straight from Gemini's network stream (as opposed to
  /// [animate]'s local, already-complete-text reveal). The bubble renders
  /// whatever text has arrived so far immediately on every rebuild (no
  /// local delay — the network is already pacing it), shows a "typing"
  /// dot row until the first chunk lands, and keeps the action row hidden
  /// until streaming finishes.
  final bool isLive;

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
    this.onRetry,
    this.isSpeaking = false,
    this.animate = false,
    this.isLive = false,
    this.onStreamTick,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

// Step 32: premium ChatGPT/Claude-style message colors. The user bubble
// moves from the old saturated "sea green" fill to a soft, neutral light
// surface with dark text — kept as fixed literals (not theme-derived) so
// the user message reads the same light, premium way in both light and
// dark mode, matching the reference apps. Only used here in chat_bubble.dart;
// no theme file is touched.
const Color _kUserBubbleLight = Color(0xFFF3F4F6);
const Color _kUserTextDark = Color(0xFF111827);

enum _Feedback { none, liked }

/// Step 18.4: the AI action row now always shows exactly three actions —
/// Copy, Speak, and a "More" overflow button that reveals the rest (Share,
/// Regenerate, Like, Delete) in the existing bottom sheet — matching the
/// ChatGPT pattern of a minimal, always-visible row under every reply.

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
    // the reply at the same list index) — restart the reveal for it and
    // hide any actions left showing from the previous message.
    if (!identical(oldWidget.message, widget.message)) {
      _streamTimer?.cancel();
      _startOrSkipStreaming();
    }
  }

  void _startOrSkipStreaming() {
    final length = widget.message.text.length;
    // Step 26: a message being filled in live from the network is already
    // paced by the stream itself — always show every character that has
    // arrived, with no extra local delay on top.
    if (widget.isLive) {
      _visibleChars = length;
      _streaming = false;
      return;
    }
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
  /// Regenerate, Like, Delete). Disabled actions (e.g. Regenerate on an
  /// older reply) render dimmed and inert, same as before.
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

    // Step 32: user messages now use a flat, very light neutral surface
    // (matching the surface previously used behind AI replies) with dark
    // text, instead of the old solid "sea green" fill — a modern,
    // ChatGPT/Claude-style look. AI replies no longer sit in a colored
    // container at all (handled below via `decoration`), so `bubbleColor`
    // is only meaningful for the user and error cases here.
    final bubbleColor = message.isError
        ? theme.colorScheme.errorContainer
        : isUser
            ? _kUserBubbleLight
            : Colors.transparent;

    final textColor = message.isError
        ? theme.colorScheme.onErrorContainer
        : isUser
            ? _kUserTextDark
            : theme.colorScheme.onSurface;

    // While streaming, only the revealed slice of the reply is rendered.
    int safeVisible = _visibleChars;
    if (safeVisible > message.text.length) safeVisible = message.text.length;
    if (safeVisible < 0) safeVisible = 0;
    final displayedText =
        isAiReply ? message.text.substring(0, safeVisible) : message.text;

    // Step 18.4: the action row auto-appears for any settled AI reply as
    // soon as streaming finishes — no tap, long-press, or expand needed.
    // Step 26: also held back while a live network stream is still
    // filling this exact reply in.
    final showActions = isAiReply && !_streaming && !widget.isLive;
    final showLiveTypingDots =
        isAiReply && widget.isLive && message.text.isEmpty;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            // The action row is now always auto-shown (see `showActions`
            // below), so this bubble no longer needs a tap/long-press
            // handler of its own — long-press-to-copy is still wired up
            // one level up, in the screen's list itemBuilder.
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
                // Step 32: AI replies no longer get a border or shadow —
                // the container decoration is fully removed for them so the
                // response sits directly on the page background, open and
                // spacious, ChatGPT/Claude-style. Error bubbles keep their
                // existing (border/shadow-free) look, unchanged.
                border: null,
                // Step 12.4: shadows across the board are now just a very
                // soft touch — no more visible colored glow under the
                // user bubble. Step 32: the AI-reply shadow is removed
                // along with its container; only the user bubble keeps one.
                boxShadow: isUser
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
                // Step 26: before the first chunk of a live stream has
                // arrived, show the same pulsing three-dot "typing" cue
                // the old pre-reply indicator used, right inside the
                // bubble that will hold the answer.
                if (showLiveTypingDots)
                  _LiveTypingDots(color: ChatPalette.userBubble)
                // AI replies render as Markdown (bold, lists, code blocks,
                // etc.) at a slightly larger size with roomier line
                // spacing for readability; user/error text stays plain.
                else if (isAiReply)
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
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: child,
            ),
            child: !showActions
                ? const SizedBox.shrink(key: ValueKey('actions-hidden'))
                : Padding(
                    key: const ValueKey('actions-shown'),
                    padding: const EdgeInsets.only(top: 6, left: 2),
                    child: _ActionRow(
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
          // Step 26: a failed reply gets a lightweight Retry chip in place
          // of the (inapplicable) copy/share/regenerate row — only shown
          // when the screen has wired one up, which it only does for the
          // most recent message.
          if (message.isError && widget.onRetry != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 2),
              child: _RetryChip(onTap: widget.onRetry!),
            ),
        ],
      ),
    );
  }
}

/// Three small, pulsing dots shown inside a fresh AI bubble before the
/// first chunk of a live network stream has arrived — the in-bubble
/// equivalent of the old pre-reply [TypingIndicator], sized to sit
/// naturally inside the bubble's own padding instead of floating above it.
class _LiveTypingDots extends StatefulWidget {
  final Color color;
  const _LiveTypingDots({required this.color});

  @override
  State<_LiveTypingDots> createState() => _LiveTypingDotsState();
}

class _LiveTypingDotsState extends State<_LiveTypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _dot(double phaseOffset) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = (_controller.value + phaseOffset) % 1.0;
        final eased = Curves.easeInOutSine.transform(t);
        final scale = 0.75 + (eased * 0.5);
        final opacity = 0.35 + (eased * 0.65);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withOpacity(opacity),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dot(0.0),
          const SizedBox(width: 6),
          _dot(0.15),
          const SizedBox(width: 6),
          _dot(0.3),
        ],
      ),
    );
  }
}

/// A small "Retry" chip shown under a failed AI reply (Step 26). Styled
/// to match the app's emerald theme — no red/blue accent, just a subtle
/// outlined pill with a refresh icon.
class _RetryChip extends StatelessWidget {
  final VoidCallback onTap;
  const _RetryChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.4),
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.refresh_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                'Retry',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
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

/// The AI-reply action row: exactly three actions — Copy, Speak, and More
/// (which opens the existing overflow sheet for Share, Regenerate, Like,
/// and Delete) — always shown once a reply finishes streaming. Styled as
/// a minimal, transparent, borderless row of icons (no pill background,
/// no card, no shadow), matching the ChatGPT reply-action pattern.
class _ActionRow extends StatelessWidget {
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
    // Share, Regenerate, and Like/Delete stay reachable only through the
    // "More" overflow sheet (unchanged) — the visible row never exceeds
    // the three ChatGPT-style actions below.
    return Container(
      decoration: const BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.all(Radius.circular(18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionIcon(
            icon: Icons.content_copy_rounded,
            tooltip: 'Copy',
            onTap: onCopy,
          ),
          const SizedBox(width: 6),
          _ActionIcon(
            icon: isSpeaking
                ? Icons.stop_circle_rounded
                : Icons.volume_up_rounded,
            tooltip: isSpeaking ? 'Stop' : 'Speak',
            onTap: onReadAloud,
          ),
          const SizedBox(width: 6),
          _ActionIcon(
            icon: Icons.more_horiz_rounded,
            tooltip: 'More',
            onTap: onMore,
          ),
        ],
      ),
    );
  }
}

/// A small, low-emphasis icon button used in the AI-reply action row.
/// Renders dimmed and inert when [onTap] is null. Deliberately minimal —
/// no background box, no border, no shadow, no scale/bounce — matching
/// ChatGPT's flat icon-only reply actions.
class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _ActionIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onTap = this.onTap;
    final color = onTap == null
        ? theme.colorScheme.onSurfaceVariant.withOpacity(0.35)
        : theme.colorScheme.onSurfaceVariant;

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  onTap();
                },
          child: Padding(
            // ~40dp min touch target (21 icon + 9.5*2 padding ≈ 40).
            padding: const EdgeInsets.all(9.5),
            child: Icon(icon, size: 21, color: color),
          ),
        ),
      ),
    );
  }
}
