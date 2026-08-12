import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/services/document_intelligence_service.dart';
import '../models/chat_message.dart';
import 'attachment_preview.dart';
import 'document_result_card.dart';

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

  /// Step 40 — Chat-Native Intelligence UX Refactor (Part 6): the label
  /// shown next to the pulsing dot while [isLive] is true and the message
  /// has no text yet. Defaults to the existing streaming label so normal
  /// AI replies are unaffected; the chat screen overrides this with a
  /// specific status ("Reading your document…", "Extracting text…",
  /// "Analyzing the document…") while a smart-routed capability is
  /// in flight.
  final String liveLabel;

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
    this.liveLabel = 'Writing...',
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

enum _Feedback { none, liked, disliked }

/// Step 18.4: the AI action row shows Copy, Speak, and a "More" overflow
/// button that reveals the rest (Share, Regenerate, Like, Delete) in a
/// bottom sheet — matching the ChatGPT pattern of a minimal, always-visible
/// row under every reply.
///
/// Step 52: the row now shows all six actions inline — Copy, Like,
/// Dislike, Voice, Share, More — matching the supplied reference image.
/// Like/Dislike are still local-only UI feedback (not persisted), now
/// mutually exclusive. The "More" button opens a small, compact popup
/// (Share, Regenerate, Delete) anchored near the button itself instead of
/// the old full-width bottom sheet.

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

  /// Toggles [value] on, or back off if it was already the active
  /// feedback. Like and Dislike are mutually exclusive, same as the
  /// existing (pre-Step-52) Like-only behavior — still local-only UI
  /// state, not persisted.
  void _toggleFeedback(_Feedback value) {
    setState(() {
      _feedback = _feedback == value ? _Feedback.none : value;
    });
    if (_feedback != _Feedback.none) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Thanks for the feedback!'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _toggleLike() => _toggleFeedback(_Feedback.liked);
  void _toggleDislike() => _toggleFeedback(_Feedback.disliked);

  /// Opens the compact "More" popup (Share, Regenerate, Delete) anchored
  /// near the More button that was tapped. [buttonContext] is the More
  /// icon's own context, used to find its on-screen position. Disabled
  /// actions (e.g. Regenerate on an older reply) render dimmed and inert,
  /// same as before.
  void _openMoreMenu(BuildContext buttonContext) {
    HapticFeedback.selectionClick();
    final box = buttonContext.findRenderObject() as RenderBox;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final anchor = box.localToGlobal(
      Offset(box.size.width, box.size.height),
      ancestor: overlayBox,
    );
    _showMoreMenu(
      context: context,
      anchor: anchor,
      onShare: widget.onShare,
      onRegenerate: widget.onRegenerate,
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
                // Step 12.4: the user bubble is kept noticeably smaller —
                // about 68% of the screen, unchanged. Step 33: AI replies
                // use a wide, ChatGPT/Claude-style reading column. Step 48:
                // widened further from 89% to 94% (within the requested
                // 92-96% range) to cut down on unnecessary line breaks —
                // width only; padding, font, colors, and markdown are
                // untouched.
                maxWidth: MediaQuery.of(context).size.width *
                    (isUser ? 0.68 : 0.94),
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
                // Step 33: before the first chunk of a live stream has
                // arrived, show the minimal single-dot live status right
                // inside the bubble that will hold the answer — no more
                // three-dot typing bubble.
                if (showLiveTypingDots)
                  _InlineLiveDot(label: widget.liveLabel)
                // Step 40 — Chat-Native Intelligence UX Refactor (Part 4):
                // a Document Intelligence result renders as a compact,
                // expandable card instead of the plain Markdown body.
                // `message.text` still holds the flat summary (used by
                // Copy/Share/history/follow-up context above and
                // unaffected by this branch) — this is purely additional,
                // richer rendering for that one message.
                else if (isAiReply && message.documentResult != null)
                  DocumentResultCard(
                    result: DocumentIntelligenceResult.fromJson(
                      message.documentResult!,
                    ),
                  )
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
                // Step 43: a voice message stores an empty `text` (its
                // meaning is entirely the audio attachment above) — skip
                // the empty `Text` so no stray blank line shows under it.
                else if (message.text.isNotEmpty)
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
                      disliked: _feedback == _Feedback.disliked,
                      onToggleDislike: _toggleDislike,
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

/// Step 33: the premium, bubble-free live status used inside a fresh AI
/// reply before the first chunk of a live network stream has arrived —
/// this replaces the old in-bubble three-dot typing animation. It mirrors
/// the chat screen's own pre-send `_LiveStatus` indicator: a single small
/// green dot with a subtle pulse, plain text beside it, and no bubble,
/// background, border, or shadow of any kind.
class _InlineLiveDot extends StatefulWidget {
  final String label;
  const _InlineLiveDot({required this.label});

  @override
  State<_InlineLiveDot> createState() => _InlineLiveDotState();
}

class _InlineLiveDotState extends State<_InlineLiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              final t = _pulse.value;
              return Opacity(
                opacity: 0.45 + 0.55 * t,
                child: Transform.scale(scale: 0.8 + 0.2 * t, child: child),
              );
            },
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Color(0xFF22C55E),
                shape: BoxShape.circle,
              ),
              child: SizedBox(width: 8, height: 8),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
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

/// Step 52: shows a small, premium, contextual popup with the actions that
/// don't fit in the six-icon row — Share, Regenerate, Delete — anchored
/// near the More button rather than as a full-width bottom sheet. Each
/// action renders dimmed and inert when its callback is `null` (e.g.
/// Regenerate on anything but the latest reply). Dismisses on outside tap
/// or after choosing an action, both with a matching reverse animation.
Future<void> _showMoreMenu({
  required BuildContext context,
  required Offset anchor,
  required VoidCallback? onShare,
  required VoidCallback? onRegenerate,
  required VoidCallback? onDelete,
}) {
  final overlay = Overlay.of(context);
  final completer = Completer<void>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _MorePopup(
      anchor: anchor,
      onShare: onShare,
      onRegenerate: onRegenerate,
      onDelete: onDelete,
      onDismissed: () {
        entry.remove();
        if (!completer.isCompleted) completer.complete();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

/// The compact popup itself: a small rounded card containing Share,
/// Regenerate, and Delete, positioned just below-and-left of [anchor] (the
/// bottom-right corner of the tapped More button) and clamped so it never
/// runs off-screen. A full-screen transparent barrier behind it closes the
/// popup on outside tap. Opens with a combined scale-up + fade-in (ease
/// out) and closes with a matching scale-down + fade-out (ease in), per
/// the Step 52 spec — short, subtle, not flashy.
class _MorePopup extends StatefulWidget {
  final Offset anchor;
  final VoidCallback? onShare;
  final VoidCallback? onRegenerate;
  final VoidCallback? onDelete;
  final VoidCallback onDismissed;

  const _MorePopup({
    required this.anchor,
    required this.onShare,
    required this.onRegenerate,
    required this.onDelete,
    required this.onDismissed,
  });

  @override
  State<_MorePopup> createState() => _MorePopupState();
}

class _MorePopupState extends State<_MorePopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 120),
  );
  late final Animation<double> _scale = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
    reverseCurve: Curves.easeIn,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  Future<void> _dismiss() async {
    await _controller.reverse();
    if (mounted) widget.onDismissed();
  }

  void _runAction(VoidCallback? action) {
    if (action == null) return;
    HapticFeedback.selectionClick();
    _dismiss();
    action();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.of(context).size;
    const popupWidth = 190.0;
    const edgeMargin = 12.0;

    // Right-align the popup to the anchor (bottom-right of the More
    // button), clamped so it stays fully on-screen.
    double left = widget.anchor.dx - popupWidth;
    if (left < edgeMargin) left = edgeMargin;
    if (left + popupWidth > screen.width - edgeMargin) {
      left = screen.width - popupWidth - edgeMargin;
    }
    double top = widget.anchor.dy + 6;
    // Flip above the anchor if there isn't enough room below.
    const estimatedHeight = 168.0;
    if (top + estimatedHeight > screen.height - edgeMargin) {
      top = widget.anchor.dy - estimatedHeight - 6;
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: const SizedBox.shrink(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              alignment: Alignment.topRight,
              child: Material(
                color: theme.colorScheme.surfaceContainerHigh,
                elevation: 10,
                shadowColor: Colors.black.withOpacity(0.28),
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: popupWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MorePopupTile(
                          icon: Icons.ios_share_outlined,
                          label: 'Share',
                          onTap: widget.onShare == null
                              ? null
                              : () => _runAction(widget.onShare),
                        ),
                        _MorePopupTile(
                          icon: Icons.refresh_rounded,
                          label: 'Regenerate',
                          onTap: widget.onRegenerate == null
                              ? null
                              : () => _runAction(widget.onRegenerate),
                        ),
                        _MorePopupTile(
                          icon: Icons.delete_outline_rounded,
                          label: 'Delete',
                          destructive: true,
                          onTap: widget.onDelete == null
                              ? null
                              : () => _runAction(widget.onDelete),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A single compact row inside the More popup — icon, label, and a subtle
/// pressed state.
class _MorePopupTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  const _MorePopupTile({
    required this.icon,
    required this.label,
    required this.onTap,
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
            : theme.colorScheme.onSurface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
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
        ),
      ),
    );
  }
}

/// The AI-reply action row. Step 52: expanded from three to six actions,
/// shown in this exact order to match the supplied reference image —
/// Copy, Like, Dislike, Voice, Share, More (the last opens the compact
/// popup with Share, Regenerate, Delete). Styled as a minimal,
/// transparent, borderless row of icons (no pill background, no card, no
/// shadow), matching the reference's clean, outlined icon language.
class _ActionRow extends StatelessWidget {
  final VoidCallback? onCopy;
  final VoidCallback? onShare;
  final VoidCallback? onRegenerate;
  final VoidCallback? onReadAloud;
  final VoidCallback? onDelete;
  final void Function(BuildContext buttonContext) onMore;
  final bool isSpeaking;
  final bool liked;
  final VoidCallback onToggleLike;
  final bool disliked;
  final VoidCallback onToggleDislike;

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
    required this.disliked,
    required this.onToggleDislike,
  });

  @override
  Widget build(BuildContext context) {
    // Regenerate stays reachable only through the "More" popup — the
    // visible row holds the six reference-image actions below.
    return Container(
      decoration: const BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.all(Radius.circular(18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionIcon(
            icon: Icons.copy_outlined,
            tooltip: 'Copy',
            onTap: onCopy,
          ),
          const SizedBox(width: 4),
          _ActionIcon(
            icon: liked ? Icons.thumb_up_rounded : Icons.thumb_up_outlined,
            tooltip: liked ? 'Liked' : 'Like',
            active: liked,
            onTap: onToggleLike,
          ),
          const SizedBox(width: 4),
          _ActionIcon(
            icon: disliked
                ? Icons.thumb_down_rounded
                : Icons.thumb_down_outlined,
            tooltip: disliked ? 'Disliked' : 'Dislike',
            active: disliked,
            onTap: onToggleDislike,
          ),
          const SizedBox(width: 4),
          _ActionIcon(
            icon: isSpeaking
                ? Icons.stop_circle_outlined
                : Icons.volume_up_outlined,
            tooltip: isSpeaking ? 'Stop' : 'Speak',
            onTap: onReadAloud,
          ),
          const SizedBox(width: 4),
          _ActionIcon(
            icon: Icons.share_outlined,
            tooltip: 'Share',
            onTap: onShare,
          ),
          const SizedBox(width: 4),
          Builder(
            builder: (moreContext) => _ActionIcon(
              icon: Icons.more_vert_rounded,
              tooltip: 'More',
              onTap: () => onMore(moreContext),
            ),
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
    final onTap = this.onTap;
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
