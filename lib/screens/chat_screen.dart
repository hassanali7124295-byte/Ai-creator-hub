import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/providers/conversation_provider.dart';
import '../core/services/attachment_processor_service.dart';
import '../core/services/attachment_service.dart';
import '../core/services/gemini_service.dart';
import '../core/services/tts_voice_service.dart';
import '../core/services/voice_input_service.dart';
import '../core/theme/chat_palette.dart';
import '../models/ai_mode.dart';
import '../models/chat_attachment.dart';
import '../models/chat_message.dart';
import '../widgets/ai_mode_sheet.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/attachment_sheet.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/conversation_drawer.dart';
import '../widgets/typing_indicator.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';

/// Step 18.5: the mic button's three states — idle (normal mic icon),
/// listening (animated equalizer, tap again to stop), and processing (a
/// brief spinner while the final result settles before returning to idle).
enum _MicState { idle, listening, processing }

// Step 23/24: per-request attachment limits. Images beyond
// `_kMaxImagesPerRequest` are rejected at pick time; anything at or under
// it that's still more than `GeminiService._kBatchSize` (5) is
// automatically split into batches of `GeminiService._kBatchSize` and
// sent to Gemini all at once in parallel (Step 24 — Smart Large Image
// Batch Processing; Step 25 — Parallel Batch Processing) rather than one
// giant request, which is what keeps large image sets both fast and
// reliable instead of timing out.
const int _kMaxImagesPerRequest = 20;
const int _kMaxPdfsPerRequest = 1;

/// Step 23: a second, more aggressive compression pass applied to every
/// image attachment right before it's sent, on top of whatever
/// `AttachmentProcessorService` already produced. Multi-image requests
/// (up to [_kMaxImagesPerRequest] at once) need every image as small as
/// reasonably possible to upload quickly and keep the UI responsive, so
/// this shrinks the longest edge further and re-encodes at a lower JPEG
/// quality, stepping down until a smaller target size is hit — trading a
/// little more quality for a meaningfully smaller upload than the default
/// single-attachment pipeline aims for.
///
/// Top-level (not a method) so it can run in a background isolate via
/// `compute` — recompressing several images back-to-back never blocks the
/// UI thread. Returns `null` if the bytes aren't a decodable image, in
/// which case the caller falls back to the original bytes.
Uint8List? _recompressImageAggressively(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  img.Image working = decoded;
  const maxDimension = 1280;
  final longestEdge =
      working.width > working.height ? working.width : working.height;
  if (longestEdge > maxDimension) {
    working = working.width >= working.height
        ? img.copyResize(working, width: maxDimension)
        : img.copyResize(working, height: maxDimension);
  }

  // Aggressive but still "readable quality" — noticeably smaller than the
  // ~3 MB target the base attachment pipeline aims for, without dropping
  // to the point images become blurry or illegible.
  const targetBytes = 900 * 1024; // ~0.9 MB
  const qualitySteps = [75, 60, 48, 38];
  Uint8List? best;
  for (final quality in qualitySteps) {
    final encoded = img.encodeJpg(working, quality: quality);
    best = Uint8List.fromList(encoded);
    if (best.lengthInBytes <= targetBytes) return best;
  }
  // Every step tried; return the smallest (last/lowest-quality) attempt.
  return best;
}

/// A picked-but-not-yet-sent attachment, waiting in the input bar.
/// [previewMeta] is built immediately from the raw pick (for instant UI
/// feedback); the actual read/compress/encode work happens lazily in
/// [AttachmentProcessorService.process] only when the message is sent.
class _PendingAttachment {
  final AttachmentResult result;
  final AttachmentType source;
  final ChatAttachment previewMeta;

  const _PendingAttachment({
    required this.result,
    required this.source,
    required this.previewMeta,
  });
}

/// AI Chat screen — Gemini-powered chat UI with message bubbles, Markdown
/// rendering for AI replies, a typing/loading indicator, persisted chat
/// history, and copy-to-clipboard on any message.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  /// Step 17: with the bottom nav gone, [ChatScreen] is the single root
  /// screen and History/Settings/Profile are pushed on top of it instead
  /// of living in an `IndexedStack`. [HistoryScreen] calls this (then
  /// pops itself) so picking a conversation there reloads the same
  /// `_messages` list the drawer's own conversation picker uses — instead
  /// of only flipping [ConversationProvider]'s `currentId` and leaving
  /// Chat's local state stale.
  static void switchToConversation(BuildContext context, String id) {
    context.findAncestorStateOfType<_ChatScreenState>()?._switchConversation(id);
  }

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  // Step 27A: owned here (instead of inside `_ChatInputBar`) so the
  // premium home screen's search card can hand focus straight to the
  // real composer below it — purely a UI convenience, no send-path change.
  final FocusNode _composerFocusNode = FocusNode();

  bool _isSending = false;
  bool _isLoadingHistory = true;
  bool _hasApiKey = true; // assume true until checked, to avoid a flash

  // Step 26: live network streaming of the AI reply, word-by-word/chunk-
  // by-chunk, replacing the old client-side "fake" character reveal for
  // any plain text turn (no attachments). `_streamSubscription` is the
  // handle the Stop button cancels; `_streamCompleter` is what lets
  // `_stopGenerating` unblock the `await` inside `_streamAiReply` the
  // instant Stop is tapped, instead of waiting for the (now-cancelled)
  // stream to naturally finish.
  bool _isStreaming = false;
  StreamSubscription<String>? _streamSubscription;
  Completer<void>? _streamCompleter;
  // Which `_messages` index is currently being filled in live — lets the
  // list tell that one bubble apart from every other (already-settled)
  // reply so only it skips the local reveal animation and hides its
  // action row until the stream finishes.
  int? _liveStreamIndex;

  // Step 26: smooth auto-scroll that follows a streaming reply only while
  // the person is already at (or very near) the bottom of the list. The
  // moment they scroll up to read something earlier, this flips false and
  // stays false — no further auto-scroll — until they scroll back down
  // themselves or a new message is explicitly sent/regenerated.
  bool _followBottom = true;
  static const double _bottomFollowThreshold = 72;

  // Step 26.1: true once new text has arrived while auto-scroll is paused
  // (`!_followBottom`) — drives the floating "Jump to Latest" pill. Cleared
  // the moment the person scrolls back to the bottom themselves or taps the
  // pill. Kept separate from `_followBottom` so the pill only appears when
  // there's actually something new to jump to, not just because the person
  // happens to be scrolled up.
  bool _newContentWhilePaused = false;

  // Step 26.1: batches live-stream chunks into UI updates on a fixed
  // cadence (see `_streamAiReply`) instead of calling `setState` for every
  // chunk the network delivers — that's what keeps a fast stream from
  // rendering jerky/chunk-by-chunk. Cancelled the moment the stream ends
  // (normally, on error, or via Stop) and on dispose.
  Timer? _streamFlushTimer;

  // Step 22B: zero or more attachments waiting to go out with the next
  // message, in the order they were picked (mixing images and PDFs freely).
  // `_attachmentsLocked` flips true the instant Send is tapped — before any
  // async work — and stays true until the attachments have either failed
  // (put back for editing) or been folded into a sent message. While
  // locked, the row shows no remove buttons and nothing about its layout
  // changes again, which is what keeps the input area from jumping.
  final List<_PendingAttachment> _pendingAttachments = [];
  bool _attachmentsLocked = false;

  // Step 23: true only while a send with at least one image attachment is
  // in flight — drives the status shown in place of the plain typing
  // indicator (see `_AnalyzingIndicator` below), so the person gets an
  // accurate, professional sense of what's taking a moment instead of a
  // generic "typing" dot animation.
  bool _sendingHasImages = false;

  // Step 24: which stage a large-image-batch send is currently in —
  // updated live via `GeminiService.sendMessageWithImages`'s `onProgress`
  // callback so `_AnalyzingIndicator` can show "Uploading images...",
  // "Analyzing images (Batch X of Y)...", or "Generating final answer..."
  // as it happens, instead of one static label for the whole wait. Null
  // whenever `_sendingHasImages` is false.
  GeminiBatchStage? _sendStage;
  int _sendBatchCurrent = 0;
  int _sendBatchTotal = 0;

  // Read Aloud (Step 21A): on-device TTS for AI replies, routed entirely
  // through the shared `VoiceManager` singleton so only one message can
  // ever be speaking across the whole app. `_speakingIndex` mirrors
  // `VoiceManager`'s active id for this screen's messages, and is kept in
  // sync by `_onVoiceStateChanged` — it's what the UI actually reads
  // (`isSpeaking: _speakingIndex == index`), unchanged from before.
  int? _speakingIndex;

  // Streaming reveal (Step 11): identifies the one AI reply — by object
  // identity, not index — that should animate in gradually. Only ever
  // set right after a fresh reply arrives (send or regenerate), never for
  // messages restored from history, so old chats still render instantly.
  ChatMessage? _streamingMessage;

  // Multi-conversation chat (Step 12): the id of the conversation currently
  // loaded into `_messages`. Used as the AnimatedSwitcher key so switching
  // conversations gets a soft cross-fade instead of an abrupt list swap,
  // and to know when the conversation list drawer requests a *different*
  // conversation than the one already open (a same-conversation tap is a
  // no-op).
  String? _conversationId;

  // AI Modes (Step 16): which persona/system-prompt overlay is active for
  // the *next* message sent in this chat — see [AiModeX.systemPrompt] and
  // [GeminiService.sendMessage]'s `modeInstruction` parameter. Purely
  // client-side UI state, not persisted with the conversation, so every
  // chat starts fresh in General AI mode.
  AiMode _mode = AiMode.general;

  // Voice input (Step 18.5): continuous speech recognition behind the mic
  // button. `_voiceInput` is only initialized the first time the person
  // taps the mic (see `_onVoiceTap`), so the OS permission prompt never
  // fires just from opening the chat screen.
  final VoiceInputService _voiceInput = VoiceInputService();
  _MicState _micState = _MicState.idle;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _checkApiKey();
    _scrollController.addListener(_onScrollChanged);
    VoiceManager.instance.addListener(_onVoiceStateChanged);
    // Fire-and-forget: warms the voice cache and applies natural
    // rate/pitch/volume defaults. Runs once per app lifetime; if it's
    // still in flight when the person taps "Read aloud" the first time,
    // `VoiceManager.toggle` awaits the same setup itself before speaking —
    // never blocks or delays the tap itself.
    unawaited(VoiceManager.instance.ensureInitialized());
  }

  /// Mirrors `VoiceManager`'s active id into `_speakingIndex` — the local
  /// state the UI already reads (`isSpeaking: _speakingIndex == index`).
  /// Both the brief "loading" pause and full "speaking" are shown as the
  /// same "stop" affordance the UI has always had; only idle/stopped/error
  /// clear it.
  void _onVoiceStateChanged(VoiceState state, Object? activeId) {
    if (!mounted) return;
    final isActiveHere = activeId is int && (state == VoiceState.loading || state == VoiceState.speaking);
    final next = isActiveHere ? activeId as int : null;
    if (next != _speakingIndex) {
      setState(() => _speakingIndex = next);
    }
  }

  Future<void> _loadHistory() async {
    final provider = context.read<ConversationProvider>();
    await provider.init(); // idempotent — no-ops if already loaded
    if (!mounted) return;
    setState(() {
      _messages.addAll(provider.currentMessages);
      _conversationId = provider.currentId;
      _isLoadingHistory = false;
    });
    _scrollToBottom(force: true);
  }

  /// Swaps `_messages` to a different conversation's history. Stops any
  /// in-flight TTS and streaming state first, since neither should carry
  /// over across conversations.
  Future<void> _switchConversation(String id) async {
    if (id == _conversationId || _isSending) return;
    final provider = context.read<ConversationProvider>();

    if (_speakingIndex != null) {
      await VoiceManager.instance.stop();
    }
    _stopGenerating();
    await provider.selectConversation(id);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(provider.currentMessages);
      _conversationId = id;
      _streamingMessage = null;
      _pendingAttachments.clear();
      _attachmentsLocked = false;
    });
    _scrollToBottom(force: true);
  }

  /// Starts a new chat: reuses the current conversation if it's still
  /// empty, otherwise opens a brand-new one — see
  /// [ConversationProvider.startNewConversation].
  Future<void> _startNewChat() async {
    if (_isSending) return;
    final provider = context.read<ConversationProvider>();

    if (_speakingIndex != null) {
      await VoiceManager.instance.stop();
    }
    _stopGenerating();
    final id = await provider.startNewConversation();
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(provider.currentMessages);
      _conversationId = id;
      _streamingMessage = null;
      _pendingAttachments.clear();
      _attachmentsLocked = false;
    });
    _scrollToBottom(force: true);
  }

  Future<void> _checkApiKey() async {
    final hasKey = await GeminiService.hasApiKey();
    if (!mounted) return;
    setState(() => _hasApiKey = hasKey);
  }

  @override
  void dispose() {
    _inputController.dispose();
    _composerFocusNode.dispose();
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    VoiceManager.instance.removeListener(_onVoiceStateChanged);
    unawaited(VoiceManager.instance.stop());
    _streamFlushTimer?.cancel();
    _streamSubscription?.cancel();
    _voiceInput.cancel();
    super.dispose();
  }

  /// Tracks whether the list is currently scrolled to (near) the bottom,
  /// so streamed text only auto-follows while the person hasn't
  /// deliberately scrolled up to read something earlier — see
  /// [_scrollToBottom]. Also clears the "Jump to Latest" pill the moment
  /// the person scrolls back to the bottom themselves.
  void _onScrollChanged() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final distanceFromBottom = position.maxScrollExtent - position.pixels;
    final atBottom = distanceFromBottom <= _bottomFollowThreshold;
    if (atBottom == _followBottom) return;
    if (!mounted) {
      _followBottom = atBottom;
      return;
    }
    setState(() {
      _followBottom = atBottom;
      if (atBottom) _newContentWhilePaused = false;
    });
  }

  /// Step 26.1: fired the instant the person's finger starts a manual drag
  /// on the message list — stops auto-scroll immediately, without waiting
  /// for the resulting scroll position change to be reported (which
  /// [_onScrollChanged] would otherwise pick up a frame or two later).
  /// Programmatic scrolls (`animateTo`/`jumpTo` from `_scrollToBottom`)
  /// have no `dragDetails`, so they never trip this.
  bool _onListScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null &&
        _followBottom) {
      setState(() => _followBottom = false);
    }
    return false;
  }

  /// Resumes auto-scroll and smoothly scrolls to the newest message —
  /// the floating "Jump to Latest" pill's tap handler.
  void _jumpToLatest() {
    HapticFeedback.selectionClick();
    setState(() {
      _followBottom = true;
      _newContentWhilePaused = false;
    });
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Step 26.1: the floating "↓ Jump to Latest" pill, shown only while
  /// auto-scroll is paused AND fresh text has actually arrived below the
  /// fold (`_newContentWhilePaused`) — not merely because the person has
  /// scrolled up to reread something. Lives in a `Positioned` overlay (not
  /// in the list's own layout flow) and only ever fades/slides in place,
  /// so its appearance never shifts or jitters the message list itself.
  Widget _buildJumpToLatestButton(ThemeData theme) {
    final visible = !_followBottom && _newContentWhilePaused;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 12,
      child: Center(
        child: IgnorePointer(
          ignoring: !visible,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            offset: visible ? Offset.zero : const Offset(0, 0.5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              opacity: visible ? 1 : 0,
              child: Material(
                color: theme.colorScheme.primary,
                elevation: 3,
                shadowColor: Colors.black.withOpacity(0.25),
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _jumpToLatest,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_downward_rounded,
                          size: 16,
                          color: theme.colorScheme.onPrimary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Jump to Latest',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sendMessage() async {
    // If voice input is still active, stop it *before* reading the field:
    // a listening session keeps streaming recognized words into
    // `_inputController` (see `_onVoiceTap`'s `onResult`), so leaving it
    // running would let a late speech result repopulate the field right
    // after it's cleared below, leaving stale/duplicate text behind.
    if (_micState != _MicState.idle) {
      await _voiceInput.cancel();
      if (mounted) setState(() => _micState = _MicState.idle);
    }

    final text = _inputController.text.trim();
    // Snapshot the pending list — everything below works off this local
    // copy, so nothing about it can change mid-send.
    final attachmentsToSend = List<_PendingAttachment>.from(_pendingAttachments);
    if ((text.isEmpty && attachmentsToSend.isEmpty) || _isSending) return;

    final hasImages = attachmentsToSend
        .any((a) => a.previewMeta.kind == ChatAttachmentKind.image);

    // Prevent duplicate sends and lock the attachment preview immediately —
    // before any async work — so the row (and the input area around it)
    // does not change shape again until this whole send resolves.
    setState(() {
      _isSending = true;
      _attachmentsLocked = attachmentsToSend.isNotEmpty;
      _sendingHasImages = hasImages;
      _sendStage = hasImages ? GeminiBatchStage.uploading : null;
      _sendBatchCurrent = 0;
      _sendBatchTotal = 0;
    });

    final attachmentMetas = <ChatAttachment>[];
    final attachmentParts = <GeminiInlinePart>[];
    final attachmentExtractedTexts = <String>[];

    for (final pending in attachmentsToSend) {
      try {
        final processed = await AttachmentProcessorService.process(
          pending.result,
          pending.source,
        );
        attachmentMetas.add(processed.metadata);
        if (processed.part != null) {
          if (processed.metadata.kind == ChatAttachmentKind.image) {
            // Step 23: shrink images further, off the UI isolate, before
            // they go out — keeps multi-image uploads fast without
            // freezing the chat while several are compressed in a row.
            attachmentParts.add(
              await _prepareImagePartForUpload(processed.part!),
            );
          } else {
            attachmentParts.add(processed.part!);
          }
        }
        if (processed.extractedText != null) {
          attachmentExtractedTexts.add(processed.extractedText!);
        }
      } on AttachmentException catch (e) {
        _reportAttachmentFailure(e.message);
        return;
      } catch (_) {
        _reportAttachmentFailure('Could not process that attachment.');
        return;
      }
    }

    // Allow sending attachments on their own with a sensible default
    // prompt, rather than forcing the user to type something first.
    final outgoingText = text.isNotEmpty
        ? text
        : (attachmentMetas.length > 1
            ? 'What can you tell me about these attachments?'
            : 'What can you tell me about this attachment?');

    // Every attachment has now finished processing — only now do we clear
    // the pending row, in the very same frame the sent bubble (carrying
    // those same attachments) appears, so nothing visibly pops in or out.
    setState(() {
      _messages.add(ChatMessage(
        text: outgoingText,
        isUser: true,
        attachments: attachmentMetas,
      ));
      _pendingAttachments.clear();
      _attachmentsLocked = false;
    });
    _inputController.clear();
    _scrollToBottom(force: true);
    unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));

    // Build lightweight history from prior turns so Gemini has context.
    final history = _messages
        .where((m) => !m.isError)
        .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
        .toList();
    // Drop the message we just added from history (it's sent as `prompt`).
    if (history.isNotEmpty) history.removeLast();

    // Step 26: a plain text turn with no attachments at all streams live,
    // word-by-word, straight from Gemini. Anything with an attachment
    // (image, PDF, or generic file) keeps using the existing batched,
    // non-streaming path below — merging several image batches into one
    // answer doesn't map onto a single token stream.
    if (attachmentsToSend.isEmpty) {
      setState(() {
        _isSending = false; // handed off to _streamAiReply, which sets it
        _sendingHasImages = false;
        _sendStage = null;
      });
      await _streamAiReply(
        insertIndex: _messages.length,
        prompt: outgoingText,
        history: history,
      );
      return;
    }

    try {
      // Any PDFs' extracted text is folded into the outgoing prompt for
      // *this* turn only — the chat bubble still shows just what the user
      // typed (or the default prompt), and `history` above already used
      // that shorter text, so a long document is never re-sent on every
      // follow-up message. Multiple PDFs are joined in selection order.
      final geminiPrompt = attachmentExtractedTexts.isNotEmpty
          ? '${attachmentExtractedTexts.join('\n\n')}\n\n$outgoingText'
          : outgoingText;

      // Step 24/25: images go through the batching entry point (a no-op
      // single request when there are 5 or fewer) so more than 5 are
      // automatically split into batches of 5 and sent to Gemini all at
      // once in parallel — each retried once on failure — then merged
      // into one final answer. Everything else (generic file attachments)
      // rides along with the first batch, exactly as a single request
      // would have sent it before.
      final imageParts = attachmentParts
          .where((p) => p.mimeType.startsWith('image/'))
          .toList(growable: false);
      final nonImageParts = attachmentParts
          .where((p) => !p.mimeType.startsWith('image/'))
          .toList(growable: false);

      final reply = await GeminiService.sendMessageWithImages(
        geminiPrompt,
        history: history,
        images: imageParts,
        otherAttachments: nonImageParts,
        modeInstruction: _mode.systemPrompt,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _sendStage = progress.stage;
            _sendBatchCurrent = progress.currentBatch;
            _sendBatchTotal = progress.totalBatches;
          });
        },
      );

      if (!mounted) return;
      final aiMessage = ChatMessage(text: reply, isUser: false);
      setState(() {
        _messages.add(aiMessage);
        _streamingMessage = aiMessage;
        if (!_followBottom) _newContentWhilePaused = true;
      });
    } on GeminiException catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.add(
          ChatMessage(text: e.message, isUser: false, isError: true),
        );
      });
      _checkApiKey();
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _sendingHasImages = false;
          _sendStage = null;
          _sendBatchCurrent = 0;
          _sendBatchTotal = 0;
        });
      }
      _scrollToBottom();
      unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
    }
  }

  /// Streams a fresh AI reply into `_messages` at [insertIndex] (appending
  /// if it's already the end of the list, or replacing a just-removed
  /// slot for regenerate/retry), one chunk at a time, live from Gemini.
  ///
  /// Drives `_isSending`/`_isStreaming` for the duration, keeps the list
  /// auto-scrolled while the person hasn't scrolled away, and — on
  /// failure with no text ever received — swaps the placeholder for an
  /// error bubble. If Stop is tapped mid-stream (`_stopGenerating`),
  /// whatever text has already arrived is kept as the final reply, exactly
  /// as if the response had finished normally.
  Future<void> _streamAiReply({
    required int insertIndex,
    required String prompt,
    required List<Map<String, String>> history,
  }) async {
    final placeholder = ChatMessage(text: '', isUser: false);
    setState(() {
      if (insertIndex >= _messages.length) {
        _messages.add(placeholder);
      } else {
        _messages.insert(insertIndex, placeholder);
      }
      _isSending = true;
      _isStreaming = true;
      _liveStreamIndex = insertIndex;
    });
    _scrollToBottom(force: true);

    final buffer = StringBuffer();
    final completer = Completer<void>();
    _streamCompleter = completer;

    // Step 26.1: chunks land in `buffer` as fast as the network delivers
    // them, but the UI only reflects `buffer` on a fixed ~75ms cadence (see
    // `flush` + `_streamFlushTimer` below) — that's what turns a fast,
    // bursty stream into smooth, evenly-paced text instead of a jumpy
    // rebuild on every network chunk, and keeps `setState` calls to a
    // handful per second no matter how quickly Gemini is sending text.
    String lastRenderedText = '';
    void flush() {
      if (!mounted) return;
      final text = buffer.toString();
      if (text == lastRenderedText) return;
      lastRenderedText = text;
      setState(() {
        if (insertIndex < _messages.length) {
          _messages[insertIndex] = ChatMessage(
            text: text,
            isUser: false,
            timestamp: placeholder.timestamp,
          );
        }
        // Step 26.1: new text arrived while the person is reading further
        // up — surface the "Jump to Latest" pill instead of forcing them
        // back down.
        if (!_followBottom) _newContentWhilePaused = true;
      });
      _scrollToBottom();
    }

    _streamFlushTimer?.cancel();
    _streamFlushTimer =
        Timer.periodic(const Duration(milliseconds: 75), (_) => flush());

    final subscription = GeminiService.sendMessageStream(
      prompt,
      history: history,
      modeInstruction: _mode.systemPrompt,
    ).listen(
      null,
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      cancelOnError: true,
    );
    // Only buffers the chunk here — `flush()` (on its own timer) is solely
    // responsible for pushing text into `_messages`/`setState`, so a burst
    // of several chunks in a few milliseconds costs one rebuild, not many.
    subscription.onData(buffer.write);
    _streamSubscription = subscription;

    try {
      await completer.future;
      if (!mounted) return;
      if (buffer.isNotEmpty) {
        setState(() {
          _streamingMessage =
              insertIndex < _messages.length ? _messages[insertIndex] : null;
        });
      } else {
        // Stopped before any text ever arrived — nothing to show, so
        // just drop the empty placeholder instead of leaving a blank
        // bubble behind.
        setState(() {
          if (insertIndex < _messages.length) {
            _messages.removeAt(insertIndex);
          }
        });
      }
    } catch (e) {
      if (!mounted) return;
      if (buffer.isEmpty) {
        // No text ever arrived — swap the empty placeholder for an error
        // bubble (with Retry available — see the `onRetry` wiring below).
        final message =
            e is GeminiException ? e.message : 'Could not reach Pak AI. Check your connection and try again.';
        setState(() {
          if (insertIndex < _messages.length) {
            _messages[insertIndex] = ChatMessage(
              text: message,
              isUser: false,
              isError: true,
            );
          }
        });
        _checkApiKey();
      }
      // Otherwise: partial text already streamed in — keep it as-is,
      // same as a normal completion.
    } finally {
      // Step 26.1: stop the periodic flush first — no further UI updates
      // for this stream after this point, which is what makes Stop
      // absolute ("no more text should appear after Stop") — then do one
      // last synchronous flush so whatever text had already arrived (but
      // hadn't hit its 75ms tick yet) is still shown, exactly as if it had
      // finished normally.
      _streamFlushTimer?.cancel();
      _streamFlushTimer = null;
      flush();
      await subscription.cancel();
      if (identical(_streamSubscription, subscription)) {
        _streamSubscription = null;
      }
      if (identical(_streamCompleter, completer)) {
        _streamCompleter = null;
      }
      if (mounted) {
        setState(() {
          _isSending = false;
          _isStreaming = false;
          _liveStreamIndex = null;
        });
      }
      _scrollToBottom();
      unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
    }
  }

  /// Stops an in-flight live stream immediately (Step 26 — "Stop
  /// Generating"), keeping whatever text has already arrived as the final
  /// reply. No-ops if nothing is currently streaming.
  void _stopGenerating() {
    if (!_isStreaming) return;
    _streamSubscription?.cancel();
    final completer = _streamCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// Step 23: runs [_recompressImageAggressively] on [part]'s bytes in a
  /// background isolate and returns a new, smaller [GeminiInlinePart] —
  /// or [part] unchanged if recompression fails or doesn't actually shrink
  /// it (e.g. a tiny image that's already well under the target size).
  static Future<GeminiInlinePart> _prepareImagePartForUpload(
    GeminiInlinePart part,
  ) async {
    try {
      final rawBytes = base64Decode(part.base64Data);
      final recompressed = await compute(_recompressImageAggressively, rawBytes);
      if (recompressed != null && recompressed.lengthInBytes < rawBytes.lengthInBytes) {
        return GeminiInlinePart(
          mimeType: part.mimeType,
          base64Data: base64Encode(recompressed),
        );
      }
    } catch (_) {
      // Best-effort only — fall through to the original part below.
    }
    return part;
  }

  /// Surfaces an attachment processing failure as an inline error bubble,
  /// matching how Gemini API errors are already shown. The attachment
  /// stays pending so the user can just remove it or try sending again.
  void _reportAttachmentFailure(String message) {
    if (!mounted) return;
    setState(() {
      _messages.add(ChatMessage(text: message, isUser: false, isError: true));
      _isSending = false;
      // Unlock so the person can remove the offending attachment (or any
      // other) and try again — they're still pending, never lost.
      _attachmentsLocked = false;
      _sendingHasImages = false;
      _sendStage = null;
      _sendBatchCurrent = 0;
      _sendBatchTotal = 0;
    });
    _scrollToBottom(force: true);
  }

  /// Scrolls to the bottom of the chat.
  ///
  /// [force] is for explicit user actions (sending, regenerating,
  /// switching conversations) — it always jumps to bottom and resets
  /// "follow" mode on. Without [force] (e.g. every streamed chunk), this
  /// only moves the list if the person is already following the bottom —
  /// see [_onScrollChanged] — and uses an immediate `jumpTo` rather than
  /// an animation, since re-triggering a 300ms animateTo on every chunk is
  /// what causes jumpy/flickery scrolling during a fast stream.
  void _scrollToBottom({bool force = false}) {
    if (force && (!_followBottom || _newContentWhilePaused)) {
      if (mounted) {
        setState(() {
          _followBottom = true;
          _newContentWhilePaused = false;
        });
      } else {
        _followBottom = true;
        _newContentWhilePaused = false;
      }
    } else if (force) {
      _followBottom = true;
    }
    if (!_followBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (force) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  void _copyMessage(String text) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _shareMessage(String text) {
    Share.share(text);
  }

  /// Starts reading [text] aloud, or stops if [index] is already speaking.
  /// `VoiceManager` owns all the actual state transitions (loading →
  /// speaking → idle/stopped/error) and guarantees only one message can
  /// ever be speaking at a time, app-wide — this just forwards the tap and
  /// lets `_onVoiceStateChanged` update `_speakingIndex` from the result.
  Future<void> _toggleSpeak(int index, String text) async {
    await VoiceManager.instance.toggle(index, text);
  }

  /// Re-asks Gemini for a fresh reply to the user prompt that produced the
  /// AI message at [aiIndex], replacing that message in place. Only
  /// offered for the most recent AI reply (see the `canRegenerate` check
  /// at the call site).
  Future<void> _regenerateResponse(int aiIndex) async {
    if (_isSending) return;
    if (aiIndex < 1 || aiIndex >= _messages.length) return;
    final userMessage = _messages[aiIndex - 1];
    if (!userMessage.isUser) return;

    if (_speakingIndex != null) {
      await VoiceManager.instance.stop();
    }

    setState(() => _messages.removeAt(aiIndex));

    final history = _messages
        .sublist(0, aiIndex - 1)
        .where((m) => !m.isError)
        .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
        .toList();

    await _streamAiReply(
      insertIndex: aiIndex,
      prompt: userMessage.text,
      history: history,
    );
  }

  /// Retries a failed AI reply (Step 26 — "Retry"): removes the error
  /// bubble at [errorIndex] and re-streams a fresh answer to the same
  /// prompt in its place. Only ever offered for the most recent message —
  /// see the `onRetry` wiring at the call site.
  Future<void> _retryLastMessage(int errorIndex) async {
    if (_isSending) return;
    if (errorIndex < 1 || errorIndex >= _messages.length) return;
    final userMessage = _messages[errorIndex - 1];
    if (!userMessage.isUser) return;

    setState(() => _messages.removeAt(errorIndex));

    final history = _messages
        .sublist(0, errorIndex - 1)
        .where((m) => !m.isError)
        .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
        .toList();

    await _streamAiReply(
      insertIndex: errorIndex,
      prompt: userMessage.text,
      history: history,
    );
  }

  /// Removes a single message (used by the AI reply's "Delete" action, in
  /// the ChatBubble overflow menu) and persists the change.
  Future<void> _deleteMessage(int index) async {
    if (index < 0 || index >= _messages.length) return;
    if (_speakingIndex == index) {
      await VoiceManager.instance.stop();
    } else if (_speakingIndex != null && _speakingIndex! > index) {
      // The speaking message isn't the one being deleted, but its index
      // is about to shift down by one — keep VoiceManager's id in sync
      // without touching playback.
      VoiceManager.instance.reassignActiveId(_speakingIndex! - 1);
    }
    setState(() {
      _messages.removeAt(index);
      if (_speakingIndex != null && _speakingIndex! > index) {
        _speakingIndex = _speakingIndex! - 1;
      }
    });
    unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
  }

  Future<void> _clearChat() async {
    setState(() => _messages.clear());
    await context.read<ConversationProvider>().clearCurrentMessages();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    _checkApiKey();
  }

  /// Opens the attachment bottom sheet, hands off to the matching picker,
  /// and holds every result as a pending attachment shown above the input
  /// bar until the message is sent (or an item is individually removed).
  ///
  /// Step 22B: gallery, PDF, and generic-file pickers now support
  /// selecting several items at once; results are appended (never
  /// replacing what's already pending) so opening the sheet more than once
  /// — or mixing images and PDFs — keeps every earlier pick, in the order
  /// everything was selected. Anything already pending (same file path) is
  /// silently skipped so the same file can't be attached twice.
  Future<void> _openAttachmentSheet() async {
    if (_isSending) return;
    final type = await showAttachmentSheet(context);
    if (type == null || !mounted) return;

    try {
      List<AttachmentResult> results;
      switch (type) {
        case AttachmentType.gallery:
          results = await AttachmentService.pickMultipleFromGallery();
          break;
        case AttachmentType.camera:
          // The camera captures one photo per tap — nothing to multiplex
          // here, but repeated taps still append in order like everything
          // else.
          final single = await AttachmentService.pickFromCamera();
          results = single != null ? [single] : const [];
          break;
        case AttachmentType.document:
          results = await AttachmentService.pickMultipleDocuments();
          break;
        case AttachmentType.file:
          results = await AttachmentService.pickMultipleFiles();
          break;
      }

      if (!mounted || results.isEmpty) return;

      final existingPaths =
          _pendingAttachments.map((p) => p.result.path).toSet();
      final existingImageCount = _pendingAttachments
          .where((p) => p.previewMeta.kind == ChatAttachmentKind.image)
          .length;
      final existingPdfCount = _pendingAttachments
          .where((p) => p.previewMeta.kind == ChatAttachmentKind.pdf)
          .length;

      // Step 23: cap a single request at `_kMaxImagesPerRequest` images
      // and `_kMaxPdfsPerRequest` PDF(s). Counted independently — an
      // image-and-PDF request can still mix both, just each within its
      // own limit — and enforced here, at pick time, rather than at send
      // time, so the person sees the row (and the warning) immediately
      // instead of the send silently dropping something later.
      var acceptedImages = existingImageCount;
      var acceptedPdfs = existingPdfCount;
      var imageLimitHit = false;
      var pdfLimitHit = false;

      final additions = <_PendingAttachment>[];
      for (final result in results) {
        // Prevent duplicate attachments — both within this pick (e.g. the
        // same file chosen twice in one picker session) and against
        // anything already pending.
        if (!existingPaths.add(result.path)) continue;

        final mimeType = AttachmentProcessorService.detectMimeType(result.path);
        final kind = AttachmentProcessorService.classify(type, mimeType);

        if (kind == ChatAttachmentKind.image) {
          if (acceptedImages >= _kMaxImagesPerRequest) {
            imageLimitHit = true;
            continue;
          }
          acceptedImages++;
        } else if (kind == ChatAttachmentKind.pdf) {
          if (acceptedPdfs >= _kMaxPdfsPerRequest) {
            pdfLimitHit = true;
            continue;
          }
          acceptedPdfs++;
        }

        additions.add(_PendingAttachment(
          result: result,
          source: type,
          previewMeta: ChatAttachment(
            name: result.name,
            mimeType: mimeType,
            sizeBytes: result.sizeBytes ?? 0,
            kind: kind,
            path: result.path,
          ),
        ));
      }

      if (additions.isNotEmpty) {
        setState(() {
          // Appending — never replacing — is what preserves selection
          // order across multiple trips through the attachment sheet.
          _pendingAttachments.addAll(additions);
        });
      }

      if (!mounted) return;
      if (imageLimitHit) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Maximum 20 images allowed per request.'),
            duration: Duration(seconds: 2),
          ),
        );
      } else if (pdfLimitHit) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Only 1 PDF allowed per request.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not access that source. Check app permissions.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// Removes one pending attachment by its position in the row. No-ops
  /// while the row is locked (an in-flight send) so it can't be edited out
  /// from under itself.
  void _removePendingAttachmentAt(int index) {
    if (_attachmentsLocked) return;
    setState(() {
      if (index >= 0 && index < _pendingAttachments.length) {
        _pendingAttachments.removeAt(index);
      }
    });
  }

  /// Fills the composer with a tapped suggestion chip's text (Step 12.3).
  /// Purely a text-field convenience — it does not send the message, so
  /// the person can still edit it first; sending still goes through the
  /// normal [_sendMessage] path untouched.
  void _applySuggestion(String text) {
    _inputController.text = text;
    _inputController.selection =
        TextSelection.collapsed(offset: text.length);
    _composerFocusNode.requestFocus();
  }

  /// Opens the AI Modes sheet and applies the chosen mode, if any, to the
  /// *next* message sent — see [AiModeX.systemPrompt].
  Future<void> _pickMode() async {
    HapticFeedback.selectionClick();
    final chosen = await showAiModeSheet(context, _mode);
    if (chosen == null || !mounted || chosen == _mode) return;
    setState(() => _mode = chosen);
  }

  /// Toggles the mic button: idle → starts a continuous listening session,
  /// listening → stops it. Recognized speech is streamed straight into
  /// `_inputController` as it comes in (see `startListening`'s `onResult`)
  /// so the person can review and edit it — sending is always a separate,
  /// explicit tap on Send, never automatic.
  Future<void> _onVoiceTap() async {
    if (_micState == _MicState.listening) {
      HapticFeedback.selectionClick();
      await _voiceInput.stop();
      if (!mounted) return;
      setState(() => _micState = _MicState.processing);
      // A short, deliberate beat while the engine settles on its final
      // transcript — mirrors the quick "processing" blip ChatGPT shows
      // between tapping stop and the mic returning to idle.
      await Future.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
      setState(() => _micState = _MicState.idle);
      return;
    }

    if (_micState == _MicState.processing) return;

    HapticFeedback.selectionClick();
    final status = await _voiceInput.ensureReady();
    if (!mounted) return;

    switch (status) {
      case VoiceReadyStatus.permissionDenied:
        _showVoiceSnack(
          'Microphone access is required for voice input. '
          'Please allow it in your device settings.',
        );
        return;
      case VoiceReadyStatus.unavailable:
        _showVoiceSnack('Speech recognition isn\'t available on this device.');
        return;
      case VoiceReadyStatus.ready:
        break;
    }

    setState(() => _micState = _MicState.listening);

    final started = await _voiceInput.startListening(
      onResult: (text, isFinal) {
        if (!mounted) return;
        _inputController.text = text;
        _inputController.selection =
            TextSelection.collapsed(offset: text.length);
      },
      onDone: () {
        if (!mounted || _micState != _MicState.listening) return;
        setState(() => _micState = _MicState.idle);
      },
      onError: (message) {
        if (!mounted) return;
        setState(() => _micState = _MicState.idle);
        _showVoiceSnack(message);
      },
    );

    if (!started && mounted) {
      setState(() => _micState = _MicState.idle);
    }
  }

  /// A friendly, floating SnackBar for voice-input problems (permission
  /// denied, no speech detected, no network, etc.) — never a crash, always
  /// a clear next step.
  void _showVoiceSnack(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            const Icon(Icons.mic_off_rounded, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Chat UI runs its own premium "Emerald + Graphite" palette, scoped to
    // this screen's subtree only — the rest of the app keeps the default
    // theme from app_theme.dart untouched.
    final theme = ChatPalette.themeFor(context);

    // A live-updating title: falls back to "AI Chat" while history is still
    // loading, otherwise reflects the open conversation's title so a
    // rename in the drawer is visible immediately.
    final conversationTitle = context.select<ConversationProvider, String>(
      (p) => p.current?.title ?? 'AI Chat',
    );

    // Step 27A: "Home" is the empty-conversation landing state — it gets
    // the new premium top bar (logo + crescent mark + avatar + settings).
    // The moment a conversation has messages, the original functional
    // chat app bar (live title, new chat, clear chat) takes back over,
    // completely unchanged.
    final isHome = _messages.isEmpty && !_isLoadingHistory;

    return Theme(
      data: theme,
      child: Scaffold(
        drawer: ConversationDrawer(
          currentId: _conversationId,
          onSelect: _switchConversation,
          onNewChat: _startNewChat,
        ),
        appBar: isHome
            ? _buildHomeAppBar(theme)
            : _buildChatAppBar(theme, conversationTitle),
        body: Column(
          children: [
            if (!_hasApiKey) _ApiKeyBanner(onSetUp: _openSettings),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _isLoadingHistory
                        ? const Center(child: CircularProgressIndicator())
                        : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _messages.isEmpty
                          ? _PremiumHomeContent(
                              key: ValueKey('empty-$_conversationId'),
                              theme: theme,
                              onSuggestionTap: _applySuggestion,
                              onComposerTap: _composerFocusNode.requestFocus,
                              onVoiceTap: _onVoiceTap,
                              onAttachmentTap: _openAttachmentSheet,
                            )
                          : NotificationListener<ScrollNotification>(
                              key: ValueKey('list-$_conversationId'),
                              onNotification: _onListScrollNotification,
                              child: ListView.builder(
                              controller: _scrollController,
                              physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                              padding: const EdgeInsets.all(16),
                              // Step 26: while a reply is streaming live,
                              // its own (growing) bubble already lives in
                              // `_messages` and doubles as the "typing"
                              // cue — the old separate typing/analyzing
                              // row is only appended for sends that don't
                              // stream (image/attachment sends still use
                              // it, unchanged).
                              itemCount: _messages.length +
                                  (_isSending && !_isStreaming ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == _messages.length) {
                                  // Step 23: while analyzing image
                                  // attachments specifically, swap the
                                  // generic typing dots for a status line
                                  // that sets accurate expectations for the
                                  // longer image-analysis wait.
                                  return _sendingHasImages
                                      ? _AnalyzingIndicator(
                                          stage: _sendStage,
                                          currentBatch: _sendBatchCurrent,
                                          totalBatches: _sendBatchTotal,
                                        )
                                      : const TypingIndicator();
                                }
                                final message = _messages[index];
                                final isAiReply =
                                    !message.isUser && !message.isError;
                                final isLast = index == _messages.length - 1;
                                final isLive = _isStreaming &&
                                    _liveStreamIndex == index;
                                // Step 12.4: user messages slide in from the
                                // right while fading in; AI (and error)
                                // messages just fade in — no slide, no
                                // bounce/spring on either.
                                final entrance = message.isUser
                                    ? FadeInRight(
                                        duration:
                                            const Duration(milliseconds: 260),
                                        from: 24,
                                        child: GestureDetector(
                                          onLongPress: () =>
                                              _copyMessage(message.text),
                                          child: ChatBubble(
                                            message: message,
                                            animate: identical(
                                                message, _streamingMessage),
                                            onStreamTick: _scrollToBottom,
                                          ),
                                        ),
                                      )
                                    : FadeIn(
                                        duration:
                                            const Duration(milliseconds: 260),
                                        // Step 12.4: the AI action row
                                        // (copy/share/regenerate/read
                                        // aloud/like/dislike) is now hidden
                                        // by default and only revealed by
                                        // tapping or long-pressing the reply
                                        // itself — handled inside
                                        // ChatBubble — so the outer
                                        // long-press-to-copy from before no
                                        // longer applies to AI replies.
                                        child: ChatBubble(
                                          message: message,
                                          onCopy: isAiReply
                                              ? () => _copyMessage(message.text)
                                              : null,
                                          onShare: isAiReply
                                              ? () => _shareMessage(message.text)
                                              : null,
                                          onRegenerate:
                                              isAiReply && isLast && !_isSending
                                                  ? () =>
                                                      _regenerateResponse(index)
                                                  : null,
                                          onReadAloud: isAiReply
                                              ? () =>
                                                  _toggleSpeak(index, message.text)
                                              : null,
                                          onDelete: isAiReply
                                              ? () => _deleteMessage(index)
                                              : null,
                                          onRetry: message.isError &&
                                                  isLast &&
                                                  !_isSending
                                              ? () => _retryLastMessage(index)
                                              : null,
                                          isSpeaking: _speakingIndex == index,
                                          animate: identical(
                                              message, _streamingMessage),
                                          isLive: isLive,
                                          onStreamTick: _scrollToBottom,
                                        ),
                                      );
                                return entrance;
                              },
                            ),
                            ),
                    ),
                  ),
                  _buildJumpToLatestButton(theme),
                ],
              ),
            ),
            // Step 22B: wrapped in AnimatedSize so the row's appearance and
            // disappearance is a smooth height animation instead of an
            // instant pop — that's what stops the mode pill and input bar
            // below it from visibly jumping when attachments are added,
            // removed, or cleared after a send completes.
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _pendingAttachments.isEmpty
                  ? const SizedBox(width: double.infinity, height: 0)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: AttachmentPreviewList(
                        attachments: _pendingAttachments
                            .map((p) => p.previewMeta)
                            .toList(growable: false),
                        locked: _attachmentsLocked,
                        onRemoveAt: _attachmentsLocked
                            ? null
                            : _removePendingAttachmentAt,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ModePill(mode: _mode, onTap: _pickMode),
              ),
            ),
            _ChatInputBar(
              controller: _inputController,
              focusNode: _composerFocusNode,
              isSending: _isSending,
              isStreaming: _isStreaming,
              onSend: _sendMessage,
              onStop: _stopGenerating,
              onAttachment: _openAttachmentSheet,
              onVoice: _onVoiceTap,
              micState: _micState,
            ),
          ],
        ),
      ),
    );
  }

  /// The original functional chat header — live conversation title, new
  /// chat, clear chat. Untouched by Step 27A; only shown once a
  /// conversation has messages.
  PreferredSizeWidget _buildChatAppBar(ThemeData theme, String conversationTitle) {
    return AppBar(
      leadingWidth: 56,
      scrolledUnderElevation: 0,
      leading: Builder(
        builder: (context) => Center(
          child: _AppBarIconButton(
            tooltip: 'Menu',
            icon: Icons.menu_rounded,
            onTap: () {
              HapticFeedback.selectionClick();
              Scaffold.of(context).openDrawer();
            },
          ),
        ),
      ),
      titleSpacing: 4,
      title: Text(
        _isLoadingHistory ? 'AI Chat' : conversationTitle,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        _AppBarIconButton(
          tooltip: 'New chat',
          icon: Icons.mode_edit_outline_rounded,
          onTap: () {
            HapticFeedback.selectionClick();
            _startNewChat();
          },
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: _messages.isNotEmpty
              ? _AppBarIconButton(
                  key: const ValueKey('clear-chat'),
                  tooltip: 'Clear chat',
                  icon: Icons.delete_outline_rounded,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    _clearChat();
                  },
                )
              : const SizedBox(width: 12, key: ValueKey('clear-chat-empty')),
        ),
        const SizedBox(width: 6),
      ],
    );
  }

  /// Step 27A: the premium home top bar — drawer, "Pak AI" wordmark with a
  /// small crescent mark, profile avatar, and settings — shown only on the
  /// empty-conversation landing state. Every action here re-uses an
  /// existing, already-wired handler (`Scaffold.openDrawer`, `_openSettings`,
  /// the `ProfileScreen` route already used by the drawer) — no new
  /// navigation or business logic.
  PreferredSizeWidget _buildHomeAppBar(ThemeData theme) {
    return AppBar(
      leadingWidth: 56,
      scrolledUnderElevation: 0,
      leading: Builder(
        builder: (context) => Center(
          child: _AppBarIconButton(
            tooltip: 'Menu',
            icon: Icons.menu_rounded,
            onTap: () {
              HapticFeedback.selectionClick();
              Scaffold.of(context).openDrawer();
            },
          ),
        ),
      ),
      titleSpacing: 4,
      title: FadeIn(
        duration: const Duration(milliseconds: 300),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary,
                    const Color(0xFF066B47),
                  ],
                ),
              ),
              child: const Icon(Icons.auto_awesome_rounded,
                  size: 16, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Text(
              'Pak AI',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.nightlight_round,
              size: 13,
              color: theme.colorScheme.primary.withOpacity(0.65),
            ),
          ],
        ),
      ),
      actions: [
        Tooltip(
          message: 'Profile',
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              HapticFeedback.selectionClick();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
            child: CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.primary.withOpacity(0.12),
              child: Icon(Icons.person_rounded,
                  size: 18, color: theme.colorScheme.primary),
            ),
          ),
        ),
        _AppBarIconButton(
          tooltip: 'Settings',
          icon: Icons.settings_outlined,
          onTap: () {
            HapticFeedback.selectionClick();
            _openSettings();
          },
        ),
        const SizedBox(width: 6),
      ],
    );
  }
}

/// Step 23/24: shown in place of the plain [TypingIndicator] while a send
/// with image attachments is in flight — the same pulsing dots, plus a
/// short status line, so waiting on a multi-image analysis (which can
/// legitimately take a while — see the 180s image timeout in
/// `GeminiService`) reads as "working on it" rather than looking stuck.
///
/// Step 24: the status line now tracks [stage] live as a large image set
/// moves through uploading → analyzing (one or more batches) →
/// generating the merged final answer, instead of one static label for
/// the whole wait — see `GeminiService.sendMessageWithImages`'s
/// `onProgress` callback, which is what drives these values.
class _AnalyzingIndicator extends StatelessWidget {
  final GeminiBatchStage? stage;
  final int currentBatch;
  final int totalBatches;

  const _AnalyzingIndicator({
    this.stage,
    this.currentBatch = 0,
    this.totalBatches = 0,
  });

  String get _label {
    switch (stage) {
      case GeminiBatchStage.uploading:
        return 'Uploading images...';
      case GeminiBatchStage.analyzing:
        return totalBatches > 1
            ? 'Analyzing images (Batch $currentBatch of $totalBatches)...'
            : 'Analyzing images...';
      case GeminiBatchStage.generating:
        return 'Generating final answer...';
      case null:
        return 'Analyzing images...';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const TypingIndicator(),
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              _label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The AI Modes entry point, now placed above the message input bar
/// (ChatGPT-style) instead of the app bar. Shows the active mode's emoji
/// plus the static "Select Model" label, tapped to open [showAiModeSheet].
/// Purely presentational — [ChatScreen._pickMode] owns the actual sheet
/// call and state update; the underlying AI Modes are unchanged.
class _ModePill extends StatelessWidget {
  final AiMode mode;
  final VoidCallback onTap;

  const _ModePill({required this.mode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer.withOpacity(0.5),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(mode.emoji, style: const TextStyle(fontSize: 15)),
              const SizedBox(width: 6),
              Text(
                'Select Model',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: theme.colorScheme.onPrimaryContainer.withOpacity(0.8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A premium app-bar icon button: a soft rounded-square "chip" behind the
/// icon (instead of a bare [IconButton]'s plain ripple-on-nothing look),
/// with its own gentle press-scale for tactile feedback. Purely visual —
/// forwards straight to [onTap].
class _AppBarIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _AppBarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_AppBarIconButton> createState() => _AppBarIconButtonState();
}

class _AppBarIconButtonState extends State<_AppBarIconButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTapDown: (_) => _setPressed(true),
          onTapCancel: () => _setPressed(false),
          onTapUp: (_) => _setPressed(false),
          child: AnimatedScale(
            scale: _pressed ? 0.90 : 1.0,
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.7),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: widget.onTap,
                child: Padding(
                  padding: const EdgeInsets.all(9),
                  child: Icon(
                    widget.icon,
                    size: 21,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ApiKeyBanner extends StatelessWidget {
  final VoidCallback onSetUp;
  const _ApiKeyBanner({required this.onSetUp});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.primaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.key_rounded, size: 18, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Add your Gemini API key to start chatting.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: onSetUp,
            child: const Text('Set up'),
          ),
        ],
      ),
    );
  }
}

/// Step 27A — Premium Home Screen (UI only).
///
/// Replaces the old plain "empty chat" welcome view with a full landing
/// screen: time-aware greeting, a tappable "search card" that hands off
/// to the real composer below, and a 2-column grid of quick-action cards
/// that pre-fill a prompt into that same composer. Nothing here sends a
/// message, calls the API, or touches routing — every action bottoms out
/// in an existing, already-wired callback (`onSuggestionTap` /
/// `_applySuggestion`, `onVoiceTap` / `_onVoiceTap`, `onAttachmentTap` /
/// `_openAttachmentSheet`).
class _PremiumHomeContent extends StatelessWidget {
  final ThemeData theme;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onComposerTap;
  final VoidCallback onVoiceTap;
  final VoidCallback onAttachmentTap;

  const _PremiumHomeContent({
    super.key,
    required this.theme,
    required this.onSuggestionTap,
    required this.onComposerTap,
    required this.onVoiceTap,
    required this.onAttachmentTap,
  });

  static const List<_QuickAction> _actions = [
    _QuickAction('Ask Question', Icons.chat_bubble_outline_rounded,
        'I have a question about '),
    _QuickAction('Brainstorm', Icons.lightbulb_outline_rounded,
        'Help me brainstorm ideas for '),
    _QuickAction('Write Script', Icons.movie_creation_outlined,
        'Write a script about '),
    _QuickAction('Explain Image', Icons.image_outlined,
        'Explain what is happening in this image'),
    _QuickAction('Summarize PDF', Icons.picture_as_pdf_outlined,
        'Summarize this PDF for me'),
    _QuickAction(
        'Translate', Icons.translate_rounded, 'Translate this into '),
    _QuickAction('Generate Code', Icons.code_rounded,
        'Write code that '),
    _QuickAction(
        'Math Solver', Icons.functions_rounded, 'Help me solve this problem: '),
    _QuickAction('Study Helper', Icons.school_outlined,
        'Help me study '),
  ];

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Very faint background watermark — a soft, oversized map glyph
        // sitting behind everything at ~5% opacity. Purely decorative.
        Positioned(
          right: -60,
          bottom: -40,
          child: Opacity(
            opacity: 0.05,
            child: Icon(
              Icons.map_rounded,
              size: 340,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FadeInUp(
                duration: const Duration(milliseconds: 420),
                child: Text(
                  '$_greeting 👋',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              FadeInUp(
                duration: const Duration(milliseconds: 420),
                delay: const Duration(milliseconds: 60),
                child: Text(
                  'How can Pak AI help you today?',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FadeInUp(
                duration: const Duration(milliseconds: 420),
                delay: const Duration(milliseconds: 100),
                child: Text(
                  'Fast  •  Private  •  Intelligent',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(height: 26),
              FadeInUp(
                duration: const Duration(milliseconds: 460),
                delay: const Duration(milliseconds: 140),
                child: _HomeSearchCard(
                  theme: theme,
                  onTap: onComposerTap,
                  onVoiceTap: onVoiceTap,
                  onCameraTap: onAttachmentTap,
                  onUploadTap: onAttachmentTap,
                ),
              ),
              const SizedBox(height: 28),
              FadeInUp(
                duration: const Duration(milliseconds: 460),
                delay: const Duration(milliseconds: 180),
                child: Text(
                  'Quick actions',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _actions.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 2.5,
                ),
                itemBuilder: (context, index) {
                  final action = _actions[index];
                  return FadeInUp(
                    duration: const Duration(milliseconds: 420),
                    delay: Duration(milliseconds: 40 * index),
                    child: _QuickActionCard(
                      theme: theme,
                      action: action,
                      onTap: () => onSuggestionTap(action.prompt),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuickAction {
  final String label;
  final IconData icon;
  final String prompt;
  const _QuickAction(this.label, this.icon, this.prompt);
}

/// The large rounded "Ask anything..." card. Tapping the body (or the
/// hint text) just hands focus to the real composer at the bottom of the
/// screen; the three bottom-row icons re-use the same voice/attachment
/// handlers already wired to the composer, so behavior is identical no
/// matter which entry point the person taps.
class _HomeSearchCard extends StatefulWidget {
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback onVoiceTap;
  final VoidCallback onCameraTap;
  final VoidCallback onUploadTap;

  const _HomeSearchCard({
    required this.theme,
    required this.onTap,
    required this.onVoiceTap,
    required this.onCameraTap,
    required this.onUploadTap,
  });

  @override
  State<_HomeSearchCard> createState() => _HomeSearchCardState();
}

class _HomeSearchCardState extends State<_HomeSearchCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _pressed ? 0.985 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 14, 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh
                    .withOpacity(isDark ? 0.55 : 0.72),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: Colors.white.withOpacity(isDark ? 0.06 : 0.5),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: theme.colorScheme.shadow.withOpacity(0.08),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.search_rounded,
                          color: theme.colorScheme.onSurfaceVariant, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Ask anything...',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant
                                .withOpacity(0.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(
                    height: 1,
                    color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _SearchCardIcon(
                        icon: Icons.mic_none_rounded,
                        label: 'Voice',
                        theme: theme,
                        onTap: widget.onVoiceTap,
                      ),
                      _SearchCardIcon(
                        icon: Icons.photo_camera_outlined,
                        label: 'Camera',
                        theme: theme,
                        onTap: widget.onCameraTap,
                      ),
                      _SearchCardIcon(
                        icon: Icons.upload_file_outlined,
                        label: 'Upload',
                        theme: theme,
                        onTap: widget.onUploadTap,
                        isLast: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchCardIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final ThemeData theme;
  final VoidCallback onTap;
  final bool isLast;

  const _SearchCardIcon({
    required this.icon,
    required this.label,
    required this.theme,
    required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: isLast ? 6 : 0, right: isLast ? 0 : 6),
      child: Tooltip(
        message: label,
        child: Material(
          color: theme.colorScheme.primary.withOpacity(0.10),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(icon, size: 19, color: theme.colorScheme.primary),
            ),
          ),
        ),
      ),
    );
  }
}

/// One glassy 2-column quick-action card in the grid — icon + label,
/// tapping it just pre-fills the composer via [onTap] (wired to
/// `_applySuggestion`/`onSuggestionTap` from the parent).
class _QuickActionCard extends StatefulWidget {
  final ThemeData theme;
  final _QuickAction action;
  final VoidCallback onTap;

  const _QuickActionCard({
    required this.theme,
    required this.action,
    required this.onTap,
  });

  @override
  State<_QuickActionCard> createState() => _QuickActionCardState();
}

class _QuickActionCardState extends State<_QuickActionCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh
              .withOpacity(isDark ? 0.55 : 0.85),
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: Colors.white.withOpacity(isDark ? 0.05 : 0.5),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(widget.action.icon,
                        size: 18, color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modern, rounded message bar in the style of ChatGPT/Gemini: a circular
/// attachment ("+") button, a pill-shaped text field with an inline mic
/// button, and a circular send button.
class _ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  // Step 27A: optional external focus node so the premium home screen's
  // search card can request focus straight into this field. Falls back
  // to an internally-owned one, exactly as before, if not supplied.
  final FocusNode? focusNode;
  final bool isSending;
  // Step 26: true while a reply is actively streaming in — swaps the
  // Send button for a Stop button (tapping it keeps whatever text has
  // already arrived, exactly like ChatGPT's stop-generating button).
  final bool isStreaming;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttachment;
  final VoidCallback onVoice;
  final _MicState micState;

  const _ChatInputBar({
    required this.controller,
    this.focusNode,
    required this.isSending,
    required this.isStreaming,
    required this.onSend,
    required this.onStop,
    required this.onAttachment,
    required this.onVoice,
    required this.micState,
  });

  @override
  State<_ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<_ChatInputBar> {
  // Step 12.2: drives a subtle border/glow animation so the input pill
  // visibly "wakes up" on focus, matching ChatGPT/Meta AI's composer.
  // Step 27A: uses the externally-supplied node when given (so the home
  // screen's search card can hand off focus here) and only owns/disposes
  // one itself as a fallback.
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  bool get _ownsFocusNode => widget.focusNode == null;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    _focusNode.removeListener(_onFocusChanged);
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  void _onFocusChanged() => setState(() => _focused = _focusNode.hasFocus);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final isSending = widget.isSending;
    final isStreaming = widget.isStreaming;
    final onSend = widget.onSend;
    final onStop = widget.onStop;
    final onAttachment = widget.onAttachment;
    final onVoice = widget.onVoice;

    final hasText = controller.text.trim().isNotEmpty;
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        // Step 12.1: the whole bar is now one rounded, shadowed pill —
        // "+" button, text field, mic, and send all live inside it, like
        // Meta AI — instead of a separate circular "+" button floating
        // outside the field.
        // Step 12.2: the pill now animates its border and shadow when the
        // text field gains focus, so the composer visibly "wakes up" —
        // and the shadow eases off in dark mode, where a plain dark
        // drop-shadow just reads as a muddy smear.
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(
              color: _focused
                  ? theme.colorScheme.primary.withOpacity(0.55)
                  : theme.colorScheme.outlineVariant.withOpacity(0.0),
              width: 1.4,
            ),
            boxShadow: [
              BoxShadow(
                color: (_focused
                        ? theme.colorScheme.primary
                        : theme.colorScheme.shadow)
                    .withOpacity(isDark ? 0.06 : (_focused ? 0.16 : 0.10)),
                blurRadius: _focused ? 22 : 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.only(left: 4, right: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Tooltip(
                  message: 'Add attachment',
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onAttachment();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Icon(
                          Icons.add_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: _focusNode,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: 'Message Pak AI...',
                    hintStyle: TextStyle(
                      color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isCollapsed: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Tooltip(
                  message: switch (widget.micState) {
                    _MicState.listening => 'Listening — tap to stop',
                    _MicState.processing => 'Processing',
                    _MicState.idle => 'Voice input',
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.micState == _MicState.listening
                          ? theme.colorScheme.primary.withOpacity(0.14)
                          : Colors.transparent,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        // Voice input is toggled on every tap regardless of
                        // state — including mid-listen — so the button never
                        // feels stuck; while processing, tapping again just
                        // re-starts a fresh session once it settles.
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onVoice();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(11),
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (child, animation) =>
                                FadeTransition(opacity: animation, child: child),
                            child: switch (widget.micState) {
                              _MicState.listening => _VoiceEqualizer(
                                  key: const ValueKey('listening'),
                                  color: theme.colorScheme.primary,
                                ),
                              _MicState.processing => SizedBox(
                                  key: const ValueKey('processing'),
                                  width: 21,
                                  height: 21,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              _MicState.idle => Icon(
                                  Icons.mic_none_rounded,
                                  key: const ValueKey('idle'),
                                  size: 21,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    color: hasText || isSending || isStreaming
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withOpacity(0.35),
                    shape: BoxShape.circle,
                  ),
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      // Step 26: while a reply is streaming, this button
                      // is a live Stop control instead of being disabled
                      // — tapping it cancels generation immediately and
                      // keeps whatever text has already arrived. Any
                      // other in-flight send (e.g. processing/uploading
                      // attachments, before a stream would even start)
                      // still shows the plain disabled spinner as before.
                      onTap: isStreaming
                          ? () {
                              HapticFeedback.mediumImpact();
                              onStop();
                            }
                          : isSending
                              ? null
                              : () {
                                  HapticFeedback.mediumImpact();
                                  onSend();
                                },
                      child: Padding(
                        padding: const EdgeInsets.all(11),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: isStreaming
                              ? Container(
                                  key: const ValueKey('stop'),
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onPrimary,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                )
                              : isSending
                                  ? SizedBox(
                                      key: const ValueKey('sending'),
                                      width: 17,
                                      height: 17,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    )
                                  : Icon(
                                      Icons.arrow_upward_rounded,
                                      key: const ValueKey('send'),
                                      color: theme.colorScheme.onPrimary,
                                      size: 20,
                                    ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small, three-bar animated equalizer shown in place of the mic icon
/// while voice input is listening — a lightweight, dependency-free stand-in
/// for a waveform, matching the "recording" affordance ChatGPT's mic button
/// uses. Purely decorative: it has no bearing on recognition itself.
class _VoiceEqualizer extends StatefulWidget {
  final Color color;

  const _VoiceEqualizer({super.key, required this.color});

  @override
  State<_VoiceEqualizer> createState() => _VoiceEqualizerState();
}

class _VoiceEqualizerState extends State<_VoiceEqualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // Each bar bounces on its own phase/speed so the three don't move in
  // lockstep — reads as "live" rather than a mechanical loop.
  static const List<double> _phases = [0.0, 0.35, 0.7];
  static const List<double> _speeds = [1.0, 1.35, 0.85];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 21,
      height: 21,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i != 0) const SizedBox(width: 2.5),
                _bar(i),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _bar(int index) {
    final t = (_controller.value * _speeds[index] + _phases[index]) % 1.0;
    // Smooth 0→1→0 pulse per cycle, offset per-bar via its own phase.
    final pulse = (1 - (2 * t - 1).abs());
    final height = 5.0 + pulse * 12.0;
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
