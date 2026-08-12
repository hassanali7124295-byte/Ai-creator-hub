import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/providers/conversation_provider.dart';
import '../core/services/attachment_processor_service.dart';
import '../core/services/attachment_service.dart';
import '../core/services/document_intelligence_service.dart';
import '../core/services/gemini_service.dart';
import '../core/services/text_recognition_service.dart';
import '../core/services/tts_voice_service.dart';
import '../core/services/voice_playback_service.dart';
import '../core/services/voice_recorder_service.dart';
import '../core/theme/chat_palette.dart';
import '../models/ai_mode.dart';
import '../models/chat_attachment.dart';
import '../models/chat_message.dart';
import '../widgets/ai_mode_sheet.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/attachment_sheet.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/conversation_drawer.dart';
import '../widgets/document_source_sheet.dart' show showDocumentSourceSheet;
import '../widgets/image_source_sheet.dart' show showImageSourceSheet;
import '../widgets/pak_home_widgets.dart';
import 'document_intelligence_screen.dart';
import 'settings_screen.dart';
import 'text_scan_result_screen.dart';

/// Step 43 — Proper Voice Message System: the mic button's states.
/// `idle` is the normal composer (mic icon, ready to tap). `recording`
/// shows the compact "Recording 00:08 · Cancel · ✓ Done" bar in place of
/// the normal input row. `preview` shows the recorded voice message —
/// play/pause, duration, delete, Send — still with an empty text
/// composer underneath. `sending` is the brief moment the voice message
/// is being turned into a sent chat bubble.
///
/// This replaces the pre-Step-43 `_MicState` (idle/listening/processing),
/// which drove continuous speech-to-text streamed into the composer —
/// removed from the mic button along with that flow (see Part 1 of the
/// Step 43 brief). `VoiceInputService`/`speech_to_text` are left in the
/// project untouched, just no longer wired up here.
enum _VoiceRecordState { idle, recording, preview, sending }

/// Step 40 — Chat-Native Intelligence UX Refactor (Part 2): the outcome of
/// local, keyword-based intent routing for a single image/PDF attachment
/// sent together with a typed instruction. `none` means the phrasing was
/// ambiguous (or no attachment/text combination applies) and the existing,
/// unchanged normal image/document understanding flow should be used
/// instead — never a second Gemini call just to decide.
///
/// Step 42 — Natural-Language File Actions: extends the same local,
/// zero-Gemini-call routing with five more document actions
/// (`documentNotes`/`documentQuestions`/`documentMcqs`/
/// `documentExplanation`/`documentTableExplain`), each mapping straight to
/// [DocumentActionType] and rendered as a plain chat message — no new
/// screen, no new persisted fields. `documentIntel` (Step 40's full
/// structured analysis + [DocumentResultCard]) is unchanged and still the
/// fallback for phrasing that doesn't match one of the newer, more
/// specific actions.
enum _SmartIntent {
  none,
  ocr,
  handwriting,
  documentIntel,
  documentNotes,
  documentQuestions,
  documentMcqs,
  documentExplanation,
  documentTableExplain,
}

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

/// Step 27C — Final Home UI Polish: the fixed "premium light" palette used
/// only by the Home (empty-chat) presentational widgets below — greeting,
/// quick-action list, mode pill, and background. Deliberately a plain set
/// of literal colors (not theme-derived) so Home always reads the same
/// clean, minimal way regardless of the app's light/dark theme; nothing
/// outside the Home state reads from this class, so chat bubbles,
/// streaming, and every other screen keep using the existing adaptive
/// theme untouched.
class _PakHome {
  _PakHome._();
  static const Color background = Color(0xFFF8F8F5);
  static const Color emerald = Color(0xFF0B7A57);
  static const Color text = Color(0xFF111827);
  static const Color secondaryText = Color(0xFF6B7280);
  static const Color card = Colors.white;
  static const Color border = Color(0xFFE5E7EB);
}

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
  // in flight — drives the status shown by the live status line (see
  // `_LiveStatus` below), so the person gets an accurate, professional
  // sense of what's taking a moment instead of a generic "typing" dot
  // animation.
  bool _sendingHasImages = false;

  // Step 24: which stage a large-image-batch send is currently in —
  // updated live via `GeminiService.sendMessageWithImages`'s `onProgress`
  // callback so `_LiveStatus` can show "Reading...", "Analyzing (Batch X
  // of Y)...", or "Writing..." as it happens, instead of one static label
  // for the whole wait. Null whenever `_sendingHasImages` is false.
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

  // Voice messages (Step 43): real audio recording behind the mic button
  // — see `_VoiceRecordState` above. `_voiceRecorder` only touches the mic
  // the first time the person taps the button (see `_startRecording`), so
  // the OS permission prompt never fires just from opening the chat
  // screen.
  final VoiceRecorderService _voiceRecorder = VoiceRecorderService();
  _VoiceRecordState _recordState = _VoiceRecordState.idle;

  // Live "Recording 00:08" timer, ticked every second while
  // `_recordState == recording`.
  Duration _recordElapsed = Duration.zero;
  Timer? _recordTimer;

  // The just-finished recording, held in memory while `_recordState ==
  // preview` — its local temp path plus the duration captured at record
  // time (used as the preview/sent-bubble duration label before real
  // playback duration is known).
  String? _recordedPath;
  Duration _recordedDuration = Duration.zero;

  // Step 40 — Chat-Native Intelligence UX Refactor (Part 6): mirrors the
  // existing `_isStreaming`/`_liveStreamIndex` pattern above, but for a
  // discrete (non-token-streamed) smart-routed capability run — OCR,
  // Handwriting, Document Intelligence analysis, or a document Q&A
  // follow-up. `_smartProcessingLabel` drives the in-bubble loading dot's
  // text (see `ChatBubble.liveLabel`) with a status specific to what's
  // actually running ("Reading your document…", "Extracting text…",
  // "Analyzing the document…").
  bool _isSmartProcessing = false;
  int? _smartProcessingIndex;
  String _smartProcessingLabel = '';

  // Step 40 (Part 10): when a smart-routed capability's own error bubble
  // is the most recent message, its Retry action needs to re-run that
  // exact capability (reusing already-processed attachment data) rather
  // than the generic `_retryLastMessage`, which only knows how to re-ask
  // Gemini a plain text prompt. `_smartErrorIndex` identifies which
  // message (if any) this applies to; `_smartRetryAction` is the closure
  // that re-runs it.
  int? _smartErrorIndex;
  VoidCallback? _smartRetryAction;

  // Step 40 (Part 5/8): the most recently analyzed document, cached so a
  // follow-up question doesn't need the file read/compressed/extracted
  // again — reused directly by `DocumentIntelligenceService.askQuestion`.
  // Cleared whenever a new attachment is sent (Step 40 (Part 2) — a fresh
  // attachment always starts a fresh context) or the conversation is
  // switched/cleared/started fresh, since a `PreparedDocument` is in-memory
  // only and conversation-specific.
  PreparedDocument? _activeDocument;
  List<DocumentQaTurn> _activeDocumentQaTurns = const [];

  // Step 41 — Document Intelligence Reliability & Timeout Fix.
  //
  // `GeminiService.sendMessage()` already has its own internal per-request
  // timeout (30/60/180s depending on payload — see Step 23), so a single
  // Gemini call was never *literally* unbounded. But that cap is shared
  // with every other Gemini call in the app (plain chat, generic image
  // understanding, etc.) and, at 180s for image attachments, is longer
  // than reasonable for this specific chat-native "Analyzing the
  // document…" / "Reading your document…" moment — during real-device
  // testing this combined with normal network variance to leave the
  // loading bubble showing for well over 5 minutes before the user saw
  // any result or error.
  //
  // Rather than changing `GeminiService`'s shared timeout (which would
  // also affect normal text chat and generic image/PDF chat — explicitly
  // out of scope), a second, narrowly-scoped deadline is applied here, at
  // the smart-document call sites only, via `Future.timeout()`. This
  // guarantees the smart-document loading state can never outlast this
  // duration, regardless of how long anything deeper in the chain (Gemini
  // itself, or a slow network) takes — the existing `finally` blocks in
  // `_runSmartCapability`/`_runDocumentFollowUp` then clean up
  // `_isSmartProcessing` immediately once this fires.
  static const Duration _kSmartOperationTimeout = Duration(seconds: 90);

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

    // Step 36 — root-cause fix for the cold-launch Quick Action overflow
    // (see CHANGE_REPORT_STEP36.md). `_EmptyState` (and its Poppins quick
    // action pills, Step 37) is only ever built for the first time right
    // here, once `_isLoadingHistory`
    // becomes false above and — when the conversation is empty — the
    // Home quick-action grid mounts. That first build is what actually
    // requests the Poppins font from GoogleFonts; before this point,
    // nothing in the tree has asked for Poppins yet (the AppBar title
    // above only ever requests Playfair Display), so an earlier
    // `GoogleFonts.pendingFonts()` call (as Step 33.2 attempted, from
    // `initState`) has nothing Poppins-related to await and resolves
    // immediately — long before Poppins itself has finished downloading.
    // Waiting one frame *after* this setState (so `_EmptyState` has
    // actually built and requested Poppins) and then awaiting
    // `GoogleFonts.pendingFonts()` correctly tracks that real, in-flight
    // Poppins load; the single corrective `setState()` once it resolves
    // forces `_EmptyState` to rebuild and re-measure with the real font
    // metrics — the same recompute that already happens naturally (and
    // fixes the layout) the first time the person navigates away and
    // back to Home.
    if (_messages.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(GoogleFonts.pendingFonts().then((_) {
          if (mounted) setState(() {});
        }));
      });
    }
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
    await VoicePlaybackManager.instance.stop();
    // Step 42/43 — Conversation Safety: a recording or a still-in-preview
    // voice message belongs to the conversation being left, not the one
    // being opened — cancel/discard it first, same pattern `_sendMessage`
    // already uses. `_cancelRecording` covers both the actively-recording
    // and already-stopped/preview cases, and is a no-op if idle.
    if (_recordState != _VoiceRecordState.idle) {
      await _cancelRecording();
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
      _recordState = _VoiceRecordState.idle;
      // Step 40: in-memory-only smart-routing state belongs to the
      // conversation being left, not the one being opened.
      _activeDocument = null;
      _activeDocumentQaTurns = const [];
      _isSmartProcessing = false;
      _smartProcessingIndex = null;
      _smartErrorIndex = null;
      _smartRetryAction = null;
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
    await VoicePlaybackManager.instance.stop();
    // Step 42/43 — Conversation Safety: see the matching cancel in
    // `_switchConversation` above.
    if (_recordState != _VoiceRecordState.idle) {
      await _cancelRecording();
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
      _recordState = _VoiceRecordState.idle;
      // Step 40: see the matching reset in `_switchConversation` above.
      _activeDocument = null;
      _activeDocumentQaTurns = const [];
      _isSmartProcessing = false;
      _smartProcessingIndex = null;
      _smartErrorIndex = null;
      _smartRetryAction = null;
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
    _scrollController.removeListener(_onScrollChanged);
    _scrollController.dispose();
    VoiceManager.instance.removeListener(_onVoiceStateChanged);
    unawaited(VoiceManager.instance.stop());
    _streamFlushTimer?.cancel();
    _streamSubscription?.cancel();
    // Step 43 — Conversation Safety/Cleanup: a recording still in
    // progress (or a not-yet-sent preview) when the screen is torn down
    // must not leak — stop/delete it and release the recorder. Playback
    // is stopped too, matching the existing `VoiceManager.instance.stop()`
    // call above for TTS.
    _recordTimer?.cancel();
    unawaited(_voiceRecorder.cancel());
    _voiceRecorder.dispose();
    unawaited(VoicePlaybackManager.instance.stop());
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

  /// Step 26.1 / Step 31 / Step 48: the floating "Jump to Latest" control.
  /// Step 48 fix: visibility now depends only on `!_followBottom` — i.e.
  /// the button shows any time the person is away from the bottom of the
  /// list, exactly like ChatGPT/Claude, not only when fresh text has also
  /// arrived while paused. (`_newContentWhilePaused` is still tracked and
  /// still clears the same way, but no longer gates visibility.) Lives in
  /// a `Positioned` overlay (not in the list's own layout flow) and only
  /// ever fades/slides in place, so its appearance never shifts or
  /// jitters the message list itself.
  Widget _buildJumpToLatestButton(ThemeData theme) {
    final visible = !_followBottom;
    const double size = 44;
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
                color: _PakHome.emerald.withOpacity(0.85),
                elevation: 3,
                shadowColor: Colors.black.withOpacity(0.25),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _jumpToLatest,
                  child: const SizedBox(
                    width: size,
                    height: size,
                    child: Icon(
                      Icons.arrow_downward_rounded,
                      size: 20,
                      color: Colors.white,
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
    // Step 43: the normal Send button only ever sends the typed-text/
    // attachment composer — a voice message in progress or in preview has
    // its own explicit Send (see `_sendVoiceMessage`), so this text send
    // path is a no-op while one is active rather than silently discarding
    // it.
    if (_recordState != _VoiceRecordState.idle) return;

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
    // Step 40 (Part 2/11): captured only when exactly one attachment is
    // being sent — reused below for local intent routing (OCR/
    // Handwriting/Document Intelligence) instead of processing the file a
    // second time. `ProcessedAttachment` already holds everything each
    // capability needs (`.part` for images, `.extractedText` for PDFs).
    ProcessedAttachment? singleProcessed;
    AttachmentType? singleSource;
    String? singleFileName;

    for (final pending in attachmentsToSend) {
      try {
        final processed = await AttachmentProcessorService.process(
          pending.result,
          pending.source,
        );
        attachmentMetas.add(processed.metadata);
        if (attachmentsToSend.length == 1) {
          singleProcessed = processed;
          singleSource = pending.source;
          singleFileName = pending.result.name;
        }
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

    // Step 40 (Part 2): local, keyword-based intent routing — decided
    // purely from the user's own typed text and the single attachment's
    // kind, no extra Gemini call. Only considered when the person actually
    // typed an instruction (an attachment sent alone with no text keeps
    // using the existing default-prompt understanding flow, unchanged).
    final smartIntent = (singleProcessed != null && text.isNotEmpty)
        ? _detectSmartIntent(text: text, kind: singleProcessed.metadata.kind)
        : _SmartIntent.none;

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
      // Step 40 (Part 5): any new attachment starts a fresh document
      // context — either this exact attachment becomes the new active
      // document below (on a successful Document Intelligence run), or
      // it's unrelated to whatever was analyzed before, either way the
      // old one no longer applies to what comes next.
      if (attachmentsToSend.isNotEmpty) {
        _activeDocument = null;
        _activeDocumentQaTurns = const [];
      }
      _smartErrorIndex = null;
      _smartRetryAction = null;
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
      // Step 40 (Part 5): a plain-text follow-up that clearly references
      // the most recently analyzed document is answered by that same
      // grounded Q&A instead of the normal chat flow — no re-selecting
      // Document AI, no re-processing the file. Ambiguous/unrelated text
      // (the common case) falls straight through to the unchanged
      // streaming flow below.
      if (_activeDocument != null && _looksLikeDocumentFollowUp(outgoingText)) {
        setState(() {
          _isSending = false; // handed off to _runDocumentFollowUp
          _sendingHasImages = false;
          _sendStage = null;
        });
        await _runDocumentFollowUp(outgoingText);
        return;
      }
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

    // Step 40 (Part 2/3): a single attachment with a clearly-recognized
    // instruction is routed to the matching existing capability and
    // rendered as a chat-native assistant message — no separate result
    // screen. Ambiguous phrasing (`_SmartIntent.none`, the common case for
    // "what can you tell me about this" or open-ended questions) falls
    // straight through to the existing image/document understanding flow
    // below, completely unchanged.
    if (smartIntent != _SmartIntent.none && singleProcessed != null) {
      setState(() {
        _isSending = false; // handed off to _runSmartCapability
        _sendingHasImages = false;
        _sendStage = null;
      });
      await _runSmartCapability(
        intent: smartIntent,
        processed: singleProcessed,
        source: singleSource!,
        fileName: singleFileName!,
        instructionText: outgoingText,
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

  /// Step 40 (Part 2) — local, keyword-based intent detection. Looks only
  /// at the user's own typed [text] (English or Roman Urdu/Hindi phrasing,
  /// matching the examples in the spec) and the single attachment's
  /// [kind]; never makes a network call. Returns `_SmartIntent.none` for
  /// anything ambiguous, generic files, or multi-attachment sends (handled
  /// by the caller before this is even reached) — the safe, existing
  /// normal-flow default.
  ///
  /// Step 42 (Feature 2) extends this with five more phrase groups —
  /// MCQs, plain questions, notes, a table explanation, and a language-
  /// aware explanation — checked in priority order *before* the existing,
  /// unchanged `documentIntelPhrases` catch-all, so a more specific
  /// instruction (e.g. "10 MCQs") routes to the new dedicated action
  /// instead of falling into the general structured-analysis card. Still
  /// entirely local — no extra Gemini call is made just to classify.
  _SmartIntent _detectSmartIntent({
    required String text,
    required ChatAttachmentKind kind,
  }) {
    if (kind != ChatAttachmentKind.image && kind != ChatAttachmentKind.pdf) {
      return _SmartIntent.none;
    }
    final t = text.toLowerCase();
    bool any(List<String> phrases) => phrases.any(t.contains);

    const handwritingPhrases = [
      'handwritten',
      'handwriting',
      'hand written',
      'hand-written',
      'likhawat',
      'haath se likha',
      'hath se likha',
    ];
    const ocrPhrases = [
      'text nikal',
      'nikal do',
      'nikaal',
      'extract text',
      'extract the text',
      'read the text',
      'read text',
      'scan text',
      'ocr',
      'kya likha hai',
      'kya likha h',
      "what's written",
      'what does it say',
      'transcribe',
    ];
    // Step 42: checked before `questionPhrases` — "MCQs" always means
    // multiple-choice, never plain questions.
    const mcqPhrases = [
      'mcq',
      'mcqs',
      'multiple choice',
      'multiple-choice',
      'objective question',
      'objective questions',
    ];
    const questionPhrases = [
      'exam questions',
      'practice questions',
      'generate questions',
      'question generate',
      'questions bana',
      'question bana',
      'quiz bana',
      'banao questions',
    ];
    const notesPhrases = [
      'short notes',
      'exam notes',
      'study notes',
      'notes bana',
      'notes banao',
      'make notes',
      'create notes',
      'notes mein convert',
      'convert into notes',
    ];
    // A table-explanation request needs a table word *and* an explain
    // verb together — bare "table" alone still falls through to the
    // existing `documentIntelPhrases` catch-all below (unchanged Step 40
    // behavior: full structured analysis, which already reconstructs
    // every table it finds).
    const tableWords = ['table'];
    const explainVerbs = [
      'explain',
      'samjhao',
      'samjha do',
      'batao',
      'bata do',
    ];
    // A language-aware explanation needs a named language *and* an
    // explain/translate verb together — "samjhao"/"explain" alone (no
    // language named) still falls through to `documentIntelPhrases`
    // below, same as before Step 42.
    const languageWords = [
      'roman urdu',
      'roman hindi',
      'urdu',
      'hindi',
      'english',
    ];
    const translateVerbs = [
      'samjhao',
      'samjha do',
      'explain',
      'translate',
      'tarjuma',
    ];
    const documentIntelPhrases = [
      'summarize',
      'summarise',
      'summary',
      'important point',
      'key point',
      'key fact',
      'important information',
      'samjhao',
      'samjha do',
      'table',
      'headings',
      'document',
      'payment date',
      'total amount',
      'analyze this',
      'analyse this',
      'analyze the document',
      'analyse the document',
    ];

    final isHandwriting = any(handwritingPhrases);
    final isOcr = !isHandwriting && any(ocrPhrases);
    final isMcq = !isHandwriting && !isOcr && any(mcqPhrases);
    final isQuestions =
        !isHandwriting && !isOcr && !isMcq && any(questionPhrases);
    final isNotes = !isHandwriting &&
        !isOcr &&
        !isMcq &&
        !isQuestions &&
        any(notesPhrases);
    final isTableExplain = !isHandwriting &&
        !isOcr &&
        !isMcq &&
        !isQuestions &&
        !isNotes &&
        any(tableWords) &&
        any(explainVerbs);
    final isExplanation = !isHandwriting &&
        !isOcr &&
        !isMcq &&
        !isQuestions &&
        !isNotes &&
        !isTableExplain &&
        any(languageWords) &&
        any(translateVerbs);
    final isDocIntel = !isHandwriting &&
        !isOcr &&
        !isMcq &&
        !isQuestions &&
        !isNotes &&
        !isTableExplain &&
        !isExplanation &&
        any(documentIntelPhrases);

    // OCR/Handwriting only exist for a single picked image (Step 38's
    // `TextRecognitionService` is image-only) — a matching phrase on a PDF
    // still has a clear intent to read/understand the content, so it's
    // routed to Document Intelligence instead of falling through to the
    // generic flow.
    if (isHandwriting) {
      return kind == ChatAttachmentKind.image
          ? _SmartIntent.handwriting
          : _SmartIntent.documentIntel;
    }
    if (isOcr) {
      return kind == ChatAttachmentKind.image
          ? _SmartIntent.ocr
          : _SmartIntent.documentIntel;
    }
    // Step 42: the remaining new actions are all backed by
    // `DocumentIntelligenceService` (image or extracted-PDF-text, same as
    // `documentIntel`) — no image-only restriction needed.
    if (isMcq) return _SmartIntent.documentMcqs;
    if (isQuestions) return _SmartIntent.documentQuestions;
    if (isNotes) return _SmartIntent.documentNotes;
    if (isTableExplain) return _SmartIntent.documentTableExplain;
    if (isExplanation) return _SmartIntent.documentExplanation;
    if (isDocIntel) return _SmartIntent.documentIntel;
    return _SmartIntent.none;
  }

  /// Step 42 — pulls a requested question/MCQ count out of phrasing like
  /// "10 MCQs" or "5 questions" (English digits only — a reasonable,
  /// deterministic subset of what a purely local, non-Gemini parser can
  /// reliably support). Returns `null` if none was specified, letting
  /// [DocumentIntelligenceService._promptFor] fall back to its own
  /// default count.
  int? _extractRequestedCount(String text) {
    final match = RegExp(r'(\d{1,3})\s*(mcqs?|questions?|qs\b)',
            caseSensitive: false)
        .firstMatch(text);
    final n = match != null ? int.tryParse(match.group(1)!) : null;
    if (n == null || n <= 0) return null;
    return n > 50 ? 50 : n; // sanity ceiling — never a runaway generation
  }

  /// Step 42 — pulls a requested explanation language out of phrasing
  /// like "Urdu mein samjhao" or "explain in Roman Hindi". Returns `null`
  /// if none was named, letting the explanation prompt fall back to the
  /// app's existing reply-in-the-user's-own-language behavior.
  String? _extractRequestedLanguage(String text) {
    final t = text.toLowerCase();
    if (t.contains('roman urdu')) {
      return 'Roman Urdu (Urdu written in English letters)';
    }
    if (t.contains('roman hindi')) {
      return 'Roman Hindi (Hindi written in English letters)';
    }
    if (t.contains('urdu')) return 'Urdu';
    if (t.contains('hindi')) return 'Hindi';
    if (t.contains('english')) return 'English';
    return null;
  }

  /// Step 42 — builds the [DocumentActionRequest] for [intent] from the
  /// user's own typed [instructionText]. Only called for the five new
  /// `_SmartIntent` values this step adds; every other intent has no
  /// matching [DocumentActionType] and isn't routed here.
  DocumentActionRequest? _actionRequestFor(
    _SmartIntent intent,
    String instructionText,
  ) {
    switch (intent) {
      case _SmartIntent.documentNotes:
        return const DocumentActionRequest(type: DocumentActionType.notes);
      case _SmartIntent.documentQuestions:
        return DocumentActionRequest(
          type: DocumentActionType.questions,
          count: _extractRequestedCount(instructionText),
        );
      case _SmartIntent.documentMcqs:
        return DocumentActionRequest(
          type: DocumentActionType.mcqs,
          count: _extractRequestedCount(instructionText),
        );
      case _SmartIntent.documentExplanation:
        return DocumentActionRequest(
          type: DocumentActionType.explanation,
          language: _extractRequestedLanguage(instructionText),
        );
      case _SmartIntent.documentTableExplain:
        return const DocumentActionRequest(
          type: DocumentActionType.tableExplanation,
        );
      case _SmartIntent.none:
      case _SmartIntent.ocr:
      case _SmartIntent.handwriting:
      case _SmartIntent.documentIntel:
        return null;
    }
  }

  /// Step 40 (Part 5) — local heuristic for whether a plain-text message
  /// (no attachment) is a follow-up about [_activeDocument]. Requires an
  /// explicit reference (document/table/page/amount/date/etc., matching
  /// the spec's own follow-up examples) rather than routing every message
  /// there once a document has ever been analyzed — that would silently
  /// break ordinary chat for the rest of the conversation (Part 12).
  bool _looksLikeDocumentFollowUp(String text) {
    final t = text.toLowerCase();
    const followUpPhrases = [
      'document',
      'pdf',
      'table',
      'page',
      'summary',
      'summarize',
      'summarise',
      'amount',
      'total',
      'date',
      'important point',
      'key point',
      'key fact',
      'iska',
      'isme',
      'ismein',
      'usme',
      'usmein',
    ];
    return followUpPhrases.any(t.contains);
  }

  String _labelFor(_SmartIntent intent) {
    switch (intent) {
      case _SmartIntent.ocr:
        return 'Extracting text…';
      case _SmartIntent.handwriting:
        return 'Reading the handwriting…';
      case _SmartIntent.documentIntel:
        return 'Analyzing the document…';
      case _SmartIntent.documentNotes:
        return 'Preparing your notes…';
      case _SmartIntent.documentQuestions:
      case _SmartIntent.documentMcqs:
        return 'Creating questions…';
      case _SmartIntent.documentExplanation:
        return 'Preparing your explanation…';
      case _SmartIntent.documentTableExplain:
        return 'Reading the table…';
      case _SmartIntent.none:
        return 'Reading your document…';
    }
  }

  /// Step 40 (Part 3/4/6/7/8) — runs the local-routed capability chosen by
  /// [intent] on an already-processed [processed] attachment (no
  /// re-reading/re-compressing/re-extracting — see `ProcessedAttachment`
  /// captured in `_sendMessage`), showing an immediate in-chat loading
  /// state and replacing it with the real chat-native result in place.
  ///
  /// [retryIndex], when set (Part 10 — Retry), reruns the exact same
  /// capability against the same already-processed data, replacing that
  /// same message in place instead of appending a new one.
  Future<void> _runSmartCapability({
    required _SmartIntent intent,
    required ProcessedAttachment processed,
    required AttachmentType source,
    required String fileName,
    // Step 42: the user's own typed instruction for this attachment (or
    // the default caption if they sent none) — only consulted for the
    // five new document actions, to pull a requested count ("10 MCQs") or
    // language ("Urdu mein samjhao") out of it via `_actionRequestFor`.
    // Every existing intent (ocr/handwriting/documentIntel) ignores it
    // completely, unchanged from Step 40/41.
    required String instructionText,
    int? retryIndex,
  }) async {
    final reuseSlot = retryIndex != null && retryIndex < _messages.length;
    final insertIndex = reuseSlot ? retryIndex : _messages.length;

    setState(() {
      final placeholder = ChatMessage(text: '', isUser: false);
      if (reuseSlot) {
        _messages[insertIndex] = placeholder;
      } else {
        _messages.add(placeholder);
      }
      _isSending = true;
      _isSmartProcessing = true;
      _smartProcessingIndex = insertIndex;
      _smartProcessingLabel = _labelFor(intent);
      _smartErrorIndex = null;
      _smartRetryAction = null;
    });
    _scrollToBottom(force: true);

    VoidCallback retryAction = () => unawaited(_runSmartCapability(
          intent: intent,
          processed: processed,
          source: source,
          fileName: fileName,
          instructionText: instructionText,
          retryIndex: insertIndex,
        ));

    try {
      ChatMessage result;
      switch (intent) {
        case _SmartIntent.ocr:
        case _SmartIntent.handwriting:
          final part = processed.part;
          if (part == null) {
            throw TextRecognitionException(
              'Could not process this image. Please try a different one.',
            );
          }
          final mode = intent == _SmartIntent.ocr
              ? TextScanMode.ocr
              : TextScanMode.handwriting;
          final scan = await TextRecognitionService.recognizeFromPart(
            part: part,
            mode: mode,
          ).timeout(
            _kSmartOperationTimeout,
            onTimeout: () => throw TextRecognitionException(
              'This is taking too long. Please try again.',
            ),
          );
          result = _buildScanResultMessage(scan);
          break;
        case _SmartIntent.documentIntel:
          // Step 40 (Part 8/11): builds the `PreparedDocument` directly
          // from the already-processed attachment instead of calling
          // `DocumentIntelligenceService.prepare()`, which would call
          // `AttachmentProcessorService.process()` a second time on the
          // same file.
          final doc = PreparedDocument(
            name: fileName,
            kind: processed.metadata.kind,
            imagePart: processed.metadata.kind == ChatAttachmentKind.image
                ? processed.part
                : null,
            extractedText: processed.extractedText,
          );
          final analysis = await DocumentIntelligenceService.analyze(doc)
              .timeout(
            _kSmartOperationTimeout,
            onTimeout: () => throw DocumentIntelligenceException(
              'Document analysis took too long. Please try again.',
            ),
          );
          _activeDocument = doc;
          _activeDocumentQaTurns = const [];
          result = ChatMessage(
            text: analysis.summary,
            isUser: false,
            documentResult: analysis.toJson(),
          );
          break;
        case _SmartIntent.documentNotes:
        case _SmartIntent.documentQuestions:
        case _SmartIntent.documentMcqs:
        case _SmartIntent.documentExplanation:
        case _SmartIntent.documentTableExplain:
          // Step 42 (Feature 2) — same already-processed-attachment reuse
          // as `documentIntel` above (no second
          // `AttachmentProcessorService.process()` call), just routed to
          // `DocumentIntelligenceService.runAction` with the action this
          // phrasing matched. Rendered as a plain chat message (Markdown
          // text, same as OCR/handwriting) rather than a
          // `DocumentResultCard` — no new persisted fields, so existing
          // chat history / `ChatMessage` serialization is untouched.
          final doc = PreparedDocument(
            name: fileName,
            kind: processed.metadata.kind,
            imagePart: processed.metadata.kind == ChatAttachmentKind.image
                ? processed.part
                : null,
            extractedText: processed.extractedText,
          );
          final request = _actionRequestFor(intent, instructionText)!;
          final actionText =
              await DocumentIntelligenceService.runAction(doc, request)
                  .timeout(
            _kSmartOperationTimeout,
            onTimeout: () => throw DocumentIntelligenceException(
              'This is taking too long. Please try again.',
            ),
          );
          _activeDocument = doc;
          _activeDocumentQaTurns = const [];
          result = ChatMessage(text: actionText, isUser: false);
          break;
        case _SmartIntent.none:
          return; // Unreachable — caller only invokes this for a match.
      }

      if (!mounted) return;
      setState(() {
        if (insertIndex < _messages.length) {
          _messages[insertIndex] = result;
        } else {
          _messages.add(result);
        }
        _streamingMessage = result;
        if (!_followBottom) _newContentWhilePaused = true;
      });
    } on TextRecognitionException catch (e) {
      _replaceWithSmartError(insertIndex, e.message, retryAction);
    } on DocumentIntelligenceException catch (e) {
      _replaceWithSmartError(insertIndex, e.message, retryAction);
    } catch (_) {
      _replaceWithSmartError(
        insertIndex,
        'Something went wrong. Please try again.',
        retryAction,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _isSmartProcessing = false;
          _smartProcessingIndex = null;
        });
      }
      _scrollToBottom();
      unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
    }
  }

  /// Step 40 (Part 5/8/10) — answers [question] about `_activeDocument`,
  /// reusing that cached `PreparedDocument` (no re-processing). Same
  /// in-place loading/error/retry pattern as `_runSmartCapability`, kept
  /// separate since it has no `ProcessedAttachment`/intent to route and
  /// must never clear `_activeDocument` on failure (Part 10 — Q&A failure
  /// keeps the document context intact).
  Future<void> _runDocumentFollowUp(String question, {int? retryIndex}) async {
    final doc = _activeDocument;
    if (doc == null) return;

    final reuseSlot = retryIndex != null && retryIndex < _messages.length;
    final insertIndex = reuseSlot ? retryIndex : _messages.length;

    setState(() {
      final placeholder = ChatMessage(text: '', isUser: false);
      if (reuseSlot) {
        _messages[insertIndex] = placeholder;
      } else {
        _messages.add(placeholder);
      }
      _isSending = true;
      _isSmartProcessing = true;
      _smartProcessingIndex = insertIndex;
      _smartProcessingLabel = 'Checking the document…';
      _smartErrorIndex = null;
      _smartRetryAction = null;
    });
    _scrollToBottom(force: true);

    try {
      final turn = await DocumentIntelligenceService.askQuestion(
        doc,
        question,
        priorTurns: _activeDocumentQaTurns,
      ).timeout(
        _kSmartOperationTimeout,
        onTimeout: () => throw DocumentIntelligenceException(
          'This is taking too long. Please try again.',
        ),
      );
      if (!mounted) return;
      final result = ChatMessage(text: turn.answer, isUser: false);
      setState(() {
        _activeDocumentQaTurns = [..._activeDocumentQaTurns, turn];
        if (insertIndex < _messages.length) {
          _messages[insertIndex] = result;
        } else {
          _messages.add(result);
        }
        _streamingMessage = result;
        if (!_followBottom) _newContentWhilePaused = true;
      });
    } on DocumentIntelligenceException catch (e) {
      _replaceWithSmartError(
        insertIndex,
        e.message,
        () => unawaited(
          _runDocumentFollowUp(question, retryIndex: insertIndex),
        ),
      );
    } catch (_) {
      _replaceWithSmartError(
        insertIndex,
        'Could not get an answer. Please try again.',
        () => unawaited(
          _runDocumentFollowUp(question, retryIndex: insertIndex),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
          _isSmartProcessing = false;
          _smartProcessingIndex = null;
        });
      }
      _scrollToBottom();
      unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
    }
  }

  /// Step 40 (Part 10) — replaces the message at [index] with a normal
  /// error bubble (same styling/behavior every other error bubble already
  /// has) and wires [retry] up as its Retry action via `_smartErrorIndex`/
  /// `_smartRetryAction` (see the `onRetry` wiring at the ChatBubble call
  /// site below) instead of the generic `_retryLastMessage`, which
  /// wouldn't know how to re-run a smart capability.
  void _replaceWithSmartError(int index, String message, VoidCallback retry) {
    if (!mounted) return;
    setState(() {
      final errorMessage = ChatMessage(text: message, isUser: false, isError: true);
      if (index < _messages.length) {
        _messages[index] = errorMessage;
      } else {
        _messages.add(errorMessage);
      }
      _smartErrorIndex = index;
      _smartRetryAction = retry;
    });
  }

  /// Step 40 (Part 3/7) — turns a [TextRecognitionResult] into a plain
  /// chat-native assistant message. OCR results are just the recognized
  /// text (rendered as a normal Markdown reply, unchanged bubble styling).
  /// Handwriting results keep Step 38's existing confidence behavior — for
  /// medium/low confidence, the exact same warning text
  /// `TextScanResultScreen` already shows is prepended as a Markdown
  /// blockquote, which the bubble already renders as a distinct tinted
  /// callout (no new UI needed).
  ChatMessage _buildScanResultMessage(TextRecognitionResult scan) {
    if (scan.mode == TextScanMode.ocr) {
      return ChatMessage(text: scan.text, isUser: false);
    }
    String? warning;
    if (scan.confidence == ScanConfidence.low) {
      warning = 'This handwriting was hard to read — the result may '
          'contain mistakes. Please double-check it.';
    } else if (scan.confidence == ScanConfidence.medium) {
      warning = 'Some words in this handwriting were unclear — please '
          'double-check the result.';
    }
    final text = warning != null ? '> ⚠️ $warning\n\n${scan.text}' : scan.text;
    return ChatMessage(text: text, isUser: false);
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
    // Step 42/43 — Conversation Safety: same voice-cancel as
    // `_switchConversation`/`_startNewChat` — no reason to keep a
    // recording or an unsent preview around once the conversation it'd
    // belong to is gone. Playback is stopped too, in case the person had
    // a sent voice message playing.
    await VoicePlaybackManager.instance.stop();
    if (_recordState != _VoiceRecordState.idle) {
      await _cancelRecording();
    }
    setState(() {
      _messages.clear();
      // Step 40: no messages left to reference the document — see the
      // matching reset in `_switchConversation`.
      _activeDocument = null;
      _activeDocumentQaTurns = const [];
      _smartErrorIndex = null;
      _smartRetryAction = null;
      _recordState = _VoiceRecordState.idle;
    });
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

    // Step 38: Scan Text (OCR) and Handwriting aren't chat attachments —
    // they launch their own picker → recognition → result flow and, at
    // most, fill the composer at the end. Handled separately, before the
    // pending-attachment logic below, which stays untouched for the
    // original four types.
    //
    // Step 40 — Chat-Native Intelligence UX Refactor (Part 1/9): these two
    // `AttachmentType` values are no longer returned by
    // `showAttachmentSheet` (its option buttons were removed), so this
    // branch is unreachable via the UI now. Left in place, unmodified, per
    // the instruction not to delete underlying capability code — the
    // standalone flow itself (`_startTextScan`, `TextScanResultScreen`)
    // still works correctly if ever reached again.
    if (type == AttachmentType.ocr || type == AttachmentType.handwriting) {
      await _startTextScan(type);
      return;
    }

    // Step 39: Document AI (Advanced Document Intelligence) follows the
    // same pattern as OCR/Handwriting above — it isn't a chat attachment,
    // it launches its own picker → analysis → result flow, and only fills
    // the composer (via "Use in Chat") at the end. Handled here, before the
    // pending-attachment logic below, which stays untouched for the
    // original four types.
    //
    // Step 40: same note as above — unreachable via the sheet's UI now,
    // left intact.
    if (type == AttachmentType.documentIntel) {
      await _startDocumentIntelligence();
      return;
    }

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
        case AttachmentType.ocr:
        case AttachmentType.handwriting:
        case AttachmentType.documentIntel:
          // Unreachable — already handled and returned above. Present here
          // only so this switch stays exhaustive over `AttachmentType`.
          return;
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

  /// Step 38 — Scan Text (OCR) / Handwriting entry point, launched from the
  /// attachment sheet. Asks for an image source (Camera/Gallery only, via
  /// [showImageSourceSheet]), picks a single image, then pushes
  /// [TextScanResultScreen] to run recognition and show the result.
  ///
  /// Only fills the composer — via [_applySuggestion], the same
  /// fill-without-sending helper used by suggestion chips — if the person
  /// taps "Use in Chat" there. Nothing is ever sent automatically, and
  /// nothing here touches [_pendingAttachments] or the normal attachment
  /// pipeline.
  Future<void> _startTextScan(AttachmentType scanType) async {
    final isOcr = scanType == AttachmentType.ocr;
    final source = await showImageSourceSheet(
      context,
      title: isOcr ? 'Scan Text' : 'Handwriting',
    );
    if (source == null || !mounted) return;

    AttachmentResult? picked;
    try {
      picked = source == AttachmentType.camera
          ? await AttachmentService.pickFromCamera()
          : await AttachmentService.pickFromGallery();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not access that source. Check app permissions.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (picked == null || !mounted) return;

    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => TextScanResultScreen(
          image: picked!,
          source: source,
          mode: isOcr ? TextScanMode.ocr : TextScanMode.handwriting,
        ),
      ),
    );
    if (text != null && text.trim().isNotEmpty && mounted) {
      _applySuggestion(text);
    }
  }

  /// Step 39 — Document AI (Advanced Document Intelligence) entry point,
  /// launched from the attachment sheet. Asks for a source (Camera/
  /// Gallery/PDF, via [showDocumentSourceSheet]), picks a single
  /// image/document, then pushes [DocumentIntelligenceScreen] to run
  /// analysis and show the result.
  ///
  /// Only fills the composer — via [_applySuggestion] — if the person taps
  /// "Use in Chat" there. Nothing is ever sent automatically, and nothing
  /// here touches [_pendingAttachments] or the normal attachment pipeline.
  Future<void> _startDocumentIntelligence() async {
    final source = await showDocumentSourceSheet(context);
    if (source == null || !mounted) return;

    AttachmentResult? picked;
    try {
      switch (source) {
        case AttachmentType.camera:
          picked = await AttachmentService.pickFromCamera();
          break;
        case AttachmentType.gallery:
          picked = await AttachmentService.pickFromGallery();
          break;
        case AttachmentType.document:
          picked = await AttachmentService.pickDocument();
          break;
        default:
          picked = null;
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not access that source. Check app permissions.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    // The person cancelled the picker (backed out of camera/gallery/file
    // browser) — nothing to do, no error to show.
    if (picked == null || !mounted) return;

    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => DocumentIntelligenceScreen(
          file: picked!,
          source: source,
        ),
      ),
    );
    if (text != null && text.trim().isNotEmpty && mounted) {
      _applySuggestion(text);
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
  }

  /// Opens the AI Modes sheet and applies the chosen mode, if any, to the
  /// *next* message sent — see [AiModeX.systemPrompt].
  Future<void> _pickMode() async {
    HapticFeedback.selectionClick();
    final chosen = await showAiModeSheet(context, _mode);
    if (chosen == null || !mounted || chosen == _mode) return;
    setState(() => _mode = chosen);
  }

  /// Starts a new recording: idle → recording. Checks/prompts for the mic
  /// permission first (only right when tapped, never on screen load), and
  /// never loops the OS prompt — a denial just shows a friendly message
  /// once (Part 11).
  Future<void> _startRecording() async {
    if (_recordState != _VoiceRecordState.idle || _isSending) return;

    HapticFeedback.selectionClick();
    final status = await _voiceRecorder.ensureReady();
    if (!mounted) return;

    switch (status) {
      case VoiceRecorderReadyStatus.permissionDenied:
        _showVoiceSnack(
          'Microphone access is required to record a voice message. '
          'Please allow it in your device settings.',
        );
        return;
      case VoiceRecorderReadyStatus.unavailable:
        _showVoiceSnack('Recording isn\'t available on this device.');
        return;
      case VoiceRecorderReadyStatus.ready:
        break;
    }

    final started = await _voiceRecorder.start();
    if (!mounted) return;
    if (!started) {
      _showVoiceSnack('Could not start recording. Please try again.');
      return;
    }

    setState(() {
      _recordState = _VoiceRecordState.recording;
      _recordElapsed = Duration.zero;
    });
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _recordElapsed += const Duration(seconds: 1));
    });
  }

  /// Stops the in-progress recording and keeps the file — the "✓ Done"
  /// tap: recording → preview. The composer's text field stays untouched
  /// (and empty) throughout; nothing here ever writes to
  /// `_inputController`.
  Future<void> _stopRecordingToPreview() async {
    if (_recordState != _VoiceRecordState.recording) return;
    HapticFeedback.selectionClick();
    _recordTimer?.cancel();
    final elapsed = _recordElapsed;
    final path = await _voiceRecorder.stop();
    if (!mounted) return;

    if (path == null) {
      setState(() => _recordState = _VoiceRecordState.idle);
      _showVoiceSnack('Recording failed. Please try again.');
      return;
    }

    setState(() {
      _recordedPath = path;
      _recordedDuration = elapsed;
      _recordState = _VoiceRecordState.preview;
    });
  }

  /// Discards the current recording — whether still in progress or
  /// already stopped and sitting in preview — and returns to the normal
  /// composer. Used by the recording bar's "Cancel", the preview bar's
  /// delete button, and every conversation-safety call site above.
  Future<void> _cancelRecording() async {
    _recordTimer?.cancel();
    await VoicePlaybackManager.instance
        .stopIfActive(_recordedPath ?? _voiceRecorder.currentPath ?? '');
    await _voiceRecorder.cancel();
    if (_recordedPath != null) {
      await VoiceRecorderService.deleteFile(_recordedPath);
    }
    if (!mounted) return;
    setState(() {
      _recordState = _VoiceRecordState.idle;
      _recordElapsed = Duration.zero;
      _recordedPath = null;
      _recordedDuration = Duration.zero;
    });
  }

  /// Sends the recorded voice message as a normal chat bubble — preview →
  /// sending → idle — then (Step 46) hands the same recorded audio file to
  /// Gemini so the AI actually replies to what was said. The audio bubble
  /// itself is never touched by this: it's appended first, exactly as
  /// before, and stays a real playable voice message either way. Only the
  /// AI-reply request (below, via [_requestVoiceAiReply]) is new.
  Future<void> _sendVoiceMessage() async {
    final path = _recordedPath;
    if (_recordState != _VoiceRecordState.preview || path == null) return;

    setState(() => _recordState = _VoiceRecordState.sending);
    await VoicePlaybackManager.instance.stopIfActive(path);

    int sizeBytes = 0;
    try {
      sizeBytes = await File(path).length();
    } catch (_) {
      // Best-effort — a missing/unreadable size just shows blank, same
      // fallback `AttachmentPreview._sizeLabel` already handles.
    }

    final attachment = ChatAttachment(
      name: 'Voice message',
      mimeType: 'audio/m4a',
      sizeBytes: sizeBytes,
      kind: ChatAttachmentKind.audio,
      path: path,
      durationMs: _recordedDuration.inMilliseconds,
    );

    if (!mounted) return;
    setState(() {
      _messages.add(ChatMessage(
        text: '',
        isUser: true,
        attachments: [attachment],
      ));
      _recordState = _VoiceRecordState.idle;
      _recordedPath = null;
      _recordedDuration = Duration.zero;
      // Step 40: a fresh attachment starts a fresh document context, same
      // as any other new attachment sent via `_sendMessage`.
      _activeDocument = null;
      _activeDocumentQaTurns = const [];
      _smartErrorIndex = null;
      _smartRetryAction = null;
    });
    _scrollToBottom(force: true);
    unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));

    await _requestVoiceAiReply(path);
  }

  /// Step 46 — sends the just-recorded audio file at [audioPath] to Gemini
  /// as an inline attachment (the same `GeminiInlinePart`/`sendMessage`
  /// mechanism `AttachmentProcessorService` already uses for images and
  /// generic files — `audio/m4a` is one of Gemini's documented supported
  /// audio mime types) and appends the resulting reply as a normal AI chat
  /// bubble.
  ///
  /// Deliberately does NOT go through `AttachmentProcessorService`: audio
  /// is not one of its handled kinds (Step 45 made that explicit — see the
  /// `ChatAttachmentKind.audio` case in `AttachmentProcessorService
  /// .process()`, which throws rather than routing audio through
  /// image/PDF/generic-file handling), and this method never calls it.
  /// The already-sent audio `ChatMessage`/`ChatAttachment` from
  /// [_sendVoiceMessage] is never modified here — only a new AI-reply
  /// message is appended (or, on retry, an old error bubble replaced by a
  /// fresh attempt).
  ///
  /// Uses the same `_isSending` flag as every other send path, so — with
  /// no extra plumbing needed — `_switchConversation`/`_startNewChat`
  /// (which both already bail out early while `_isSending` is true) can't
  /// let the eventual reply land in the wrong conversation.
  ///
  /// On failure, the voice message stays exactly as sent; a friendly error
  /// bubble is appended (see [_appendVoiceReplyError]) with Retry wired to
  /// remove that bubble and re-run this same method against the same
  /// [audioPath] (via [_retryVoiceAiReply] and the existing
  /// `_smartErrorIndex`/`_smartRetryAction` mechanism `_runSmartCapability`
  /// already uses) — never the generic `_retryLastMessage`, which only
  /// knows how to re-ask a plain text prompt and has no audio file to
  /// attach.
  Future<void> _requestVoiceAiReply(String audioPath) async {
    if (_isSending) return;

    setState(() {
      _isSending = true;
      _sendingHasImages = false;
      _sendStage = null;
      _sendBatchCurrent = 0;
      _sendBatchTotal = 0;
    });

    try {
      final file = File(audioPath);
      if (!await file.exists()) {
        throw AttachmentException(
          'That voice message could no longer be found on this device.',
        );
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw AttachmentException('That voice message is empty.');
      }

      final audioPart = GeminiInlinePart(
        mimeType: 'audio/m4a',
        base64Data: base64Encode(bytes),
      );

      // Same history shape `_sendMessage` builds: every prior turn as
      // plain text, with the turn just sent (the voice message itself,
      // whose bubble text is deliberately empty) dropped — it's sent as
      // the request's audio attachment instead, not as a text prompt.
      final history = _messages
          .where((m) => !m.isError)
          .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
          .toList();
      if (history.isNotEmpty) history.removeLast();

      final reply = await GeminiService.sendMessage(
        'The user just sent a voice message instead of typing. Listen to '
        'the attached audio and reply naturally and helpfully to what '
        'they said, exactly as you would for a typed message.',
        history: history,
        attachments: [audioPart],
        modeInstruction: _mode.systemPrompt,
      );

      if (!mounted) return;
      final aiMessage = ChatMessage(text: reply, isUser: false);
      setState(() {
        _messages.add(aiMessage);
        _streamingMessage = aiMessage;
        if (!_followBottom) _newContentWhilePaused = true;
        _smartErrorIndex = null;
        _smartRetryAction = null;
      });
    } on GeminiException catch (e) {
      _appendVoiceReplyError(e.message, audioPath);
    } on AttachmentException catch (e) {
      _appendVoiceReplyError(e.message, audioPath);
    } catch (_) {
      _appendVoiceReplyError(
        'Could not get a reply to that voice message. Please try again.',
        audioPath,
      );
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

  /// Appends a friendly error bubble after a failed voice-message AI
  /// request and wires its Retry action to [_retryVoiceAiReply] — the same
  /// `_smartErrorIndex`/`_smartRetryAction` pattern `_replaceWithSmartError`
  /// uses, except nothing is replaced in place here (there is no loading
  /// placeholder bubble for this flow; the bottom `_LiveStatus` row is the
  /// loading state instead — see `_requestVoiceAiReply`), so the error is
  /// simply appended. The voice message that was already sent is never
  /// touched.
  void _appendVoiceReplyError(String message, String audioPath) {
    if (!mounted) return;
    setState(() {
      final errorMessage = ChatMessage(text: message, isUser: false, isError: true);
      _messages.add(errorMessage);
      final errorIndex = _messages.length - 1;
      _smartErrorIndex = errorIndex;
      _smartRetryAction = () =>
          unawaited(_retryVoiceAiReply(errorIndex, audioPath));
    });
  }

  /// Retry action for a failed voice-message AI reply (wired by
  /// [_appendVoiceReplyError]): removes the stale error bubble at
  /// [errorIndex] — same as [_retryLastMessage] does for a plain-text
  /// retry — then re-runs [_requestVoiceAiReply] against the same
  /// [audioPath]. Never reopens the recording UI and never touches the
  /// already-sent voice message itself.
  Future<void> _retryVoiceAiReply(int errorIndex, String audioPath) async {
    if (_isSending) return;
    if (errorIndex < 0 || errorIndex >= _messages.length) {
      await _requestVoiceAiReply(audioPath);
      return;
    }
    setState(() => _messages.removeAt(errorIndex));
    await _requestVoiceAiReply(audioPath);
  }

  /// A friendly, floating SnackBar for voice-message problems (permission
  /// denied, recording/playback failure, etc.) — never a crash, always a
  /// clear next step.
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

    // Step 27B: drives the Home top-bar variant (logo wordmark + profile
    // avatar) vs. the normal in-conversation bar (title + new-chat/clear).
    final isHomeState = !_isLoadingHistory && _messages.isEmpty;

    return Theme(
      data: theme,
      child: Scaffold(
        drawer: ConversationDrawer(
          currentId: _conversationId,
          onSelect: _switchConversation,
          onNewChat: _startNewChat,
        ),
        appBar: AppBar(
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
          // Step 28: the "Pak AI" wordmark is now permanent branding in the
          // AppBar — shown identically on Home AND on every chat screen. It
          // never gets swapped for the conversation title anymore (that was
          // the Step 27 bug where sending a message replaced "Pak AI" with
          // e.g. "hi"). Conversation titles still live in the drawer/history
          // list — they're just never shown in the AppBar. Left-aligned
          // (not centered) right after the menu icon, in a bold serif
          // (Playfair Display) for a premium logo feel.
          centerTitle: false,
          title: Text(
            'Pak AI',
            style: GoogleFonts.playfairDisplay(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: _PakHome.emerald,
            ),
          ),
          actions: isHomeState
              ? const [ProfileAvatarButton()]
              : [
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
        ),
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
                          // Step 28: wrapped in SizedBox.expand so this pane
                          // always fills the full available width/height —
                          // guarantees the heading and quick-action pills
                          // render flush against the left edge (24dp
                          // padding) instead of the whole block ever being
                          // able to size-to-content and end up looking
                          // centered on the screen.
                          ? SizedBox.expand(
                              child: _EmptyState(
                                key: ValueKey('empty-$_conversationId'),
                                theme: theme,
                                onSuggestionTap: _applySuggestion,
                              ),
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
                              //
                              // Step 40 (Part 6): a smart-routed capability
                              // run (`_isSmartProcessing`) also already has
                              // its own placeholder bubble in `_messages`
                              // (with its own in-bubble loading dot, see
                              // `isSmartLoading` below) — excluded here for
                              // the same reason, so the two loading
                              // indicators never show at once.
                              itemCount: _messages.length +
                                  (_isSending && !_isStreaming && !_isSmartProcessing
                                      ? 1
                                      : 0),
                              itemBuilder: (context, index) {
                                if (index == _messages.length) {
                                  // Step 23 / Step 31: a single premium
                                  // "live status" line (small pulsing green
                                  // dot + short label) replaces both the
                                  // old gray typing-dots bubble and the old
                                  // image-analysis status row — the label
                                  // just reflects whichever real generation
                                  // stage is active.
                                  return _LiveStatus(
                                    hasImages: _sendingHasImages,
                                    stage: _sendStage,
                                    currentBatch: _sendBatchCurrent,
                                    totalBatches: _sendBatchTotal,
                                  );
                                }
                                final message = _messages[index];
                                final isAiReply =
                                    !message.isUser && !message.isError;
                                final isLast = index == _messages.length - 1;
                                final isLive = _isStreaming &&
                                    _liveStreamIndex == index;
                                // Step 40 (Part 6): this exact message is
                                // the one currently being filled in by a
                                // smart-routed capability — reuses the same
                                // in-bubble loading dot as live streaming
                                // (see `ChatBubble.liveLabel`), just with a
                                // status specific to what's running.
                                final isSmartLoading = _isSmartProcessing &&
                                    _smartProcessingIndex == index;
                                // Step 40 (Part 10): resolved once, with an
                                // explicit type, rather than inline in the
                                // ChatBubble constructor below — avoids any
                                // ambiguity inferring a shared type between
                                // `_smartRetryAction` (`VoidCallback?`) and
                                // `() => _retryLastMessage(index)` (whose
                                // body returns a `Future<void>`, allowed in
                                // a `VoidCallback` slot but easiest to keep
                                // unambiguous as its own statement).
                                final VoidCallback? onRetryAction =
                                    !(message.isError && isLast && !_isSending)
                                        ? null
                                        : (_smartErrorIndex == index &&
                                                _smartRetryAction != null)
                                            ? _smartRetryAction
                                            : () => _retryLastMessage(index);
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
                                          // Step 40 (Part 10): a smart
                                          // capability's own error bubble
                                          // reruns that same capability
                                          // (`_smartRetryAction`) instead of
                                          // the generic `_retryLastMessage`,
                                          // which only knows how to re-ask
                                          // Gemini a plain text prompt with
                                          // no attachment. See
                                          // `onRetryAction` above.
                                          onRetry: onRetryAction,
                                          isSpeaking: _speakingIndex == index,
                                          animate: identical(
                                              message, _streamingMessage),
                                          isLive: isLive || isSmartLoading,
                                          liveLabel: isSmartLoading
                                              ? _smartProcessingLabel
                                              : 'Writing...',
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
            // Step 43: while a recording is in progress or sitting in
            // preview, the normal composer row (attachment/text/mic/send)
            // is swapped out entirely for the compact recording/preview
            // bar — never a second screen, never text typed into
            // `_inputController` (Parts 3/4/12).
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                  sizeFactor: animation,
                  axisAlignment: -1,
                  child: child,
                ),
              ),
              child: switch (_recordState) {
                _VoiceRecordState.idle => _ChatInputBar(
                    key: const ValueKey('composer'),
                    controller: _inputController,
                    isSending: _isSending,
                    isStreaming: _isStreaming,
                    onSend: _sendMessage,
                    onStop: _stopGenerating,
                    onAttachment: _openAttachmentSheet,
                    onVoice: _startRecording,
                  ),
                _VoiceRecordState.recording => _VoiceRecordingBar(
                    key: const ValueKey('recording'),
                    elapsed: _recordElapsed,
                    onCancel: _cancelRecording,
                    onDone: _stopRecordingToPreview,
                  ),
                _VoiceRecordState.preview ||
                _VoiceRecordState.sending =>
                  _VoiceMessagePreviewBar(
                    key: const ValueKey('preview'),
                    path: _recordedPath ?? '',
                    duration: _recordedDuration,
                    isSending: _recordState == _VoiceRecordState.sending,
                    onDelete: _cancelRecording,
                    onSend: _sendVoiceMessage,
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 43 — Proper Voice Message System (Part 3): the compact bar shown
/// in place of the normal composer while a recording is in progress —
/// "🎙️ Recording 00:08 · Cancel · ✓ Done". Lives inside the same rounded
/// pill footprint the normal `_ChatInputBar` uses, so the composer area
/// never visibly jumps in height when recording starts/stops.
class _VoiceRecordingBar extends StatelessWidget {
  final Duration elapsed;
  final VoidCallback onCancel;
  final VoidCallback onDone;

  const _VoiceRecordingBar({
    super.key,
    required this.elapsed,
    required this.onCancel,
    required this.onDone,
  });

  String get _label {
    final totalSeconds = elapsed.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.surfaceContainerHigh,
                theme.colorScheme.surfaceContainerHigh.withOpacity(0.96),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withOpacity(isDark ? 0.06 : 0.08),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              _VoiceEqualizer(color: theme.colorScheme.error),
              const SizedBox(width: 10),
              Text(
                'Recording $_label',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  onCancel();
                },
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 4),
              Material(
                color: theme.colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    onDone();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(9),
                    child: Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: theme.colorScheme.onPrimary,
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

/// Step 43 — Proper Voice Message System (Part 4): the compact bar shown
/// in place of the normal composer once a recording has been stopped —
/// "🎙️ Voice message ▶ 0:08 · Send", with a delete button to discard it
/// instead. Reuses `AttachmentPreview`'s audio-chip rendering (via a
/// throwaway in-memory `ChatAttachment`) so the preview looks and behaves
/// exactly like the same message will once it's sent — same play button,
/// same progress bar, same `VoicePlaybackManager`.
class _VoiceMessagePreviewBar extends StatelessWidget {
  final String path;
  final Duration duration;
  final bool isSending;
  final VoidCallback onDelete;
  final VoidCallback onSend;

  const _VoiceMessagePreviewBar({
    super.key,
    required this.path,
    required this.duration,
    required this.isSending,
    required this.onDelete,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.surfaceContainerHigh,
                theme.colorScheme.surfaceContainerHigh.withOpacity(0.96),
              ],
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withOpacity(isDark ? 0.06 : 0.08),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: AttachmentPreview(
                  attachment: ChatAttachment(
                    name: 'Voice message',
                    mimeType: 'audio/m4a',
                    sizeBytes: 0,
                    kind: ChatAttachmentKind.audio,
                    path: path,
                    durationMs: duration.inMilliseconds,
                  ),
                  locked: isSending,
                  onRemove: isSending
                      ? null
                      : () {
                          HapticFeedback.selectionClick();
                          onDelete();
                        },
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: theme.colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: isSending
                      ? null
                      : () {
                          HapticFeedback.mediumImpact();
                          onSend();
                        },
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: isSending
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : Icon(
                            Icons.arrow_upward_rounded,
                            size: 18,
                            color: theme.colorScheme.onPrimary,
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

/// Step 23/24/31: shown in the message list while a send is in flight and
/// no stream has started yet — replaces the old gray "typing dots" bubble
/// (and the separate image-analysis status row) with a single premium,
/// bubble-free live status: a small pulsing green dot beside a short label
/// that reflects whichever real generation stage is active. There's no
/// hidden "searching" stage in the current pipeline (only upload/analyze/
/// generate for image sends, plus the plain wait for a text-only send), so
/// only real states are ever shown — nothing is fabricated.
///
/// Step 24's per-batch tracking is unchanged: as a large image set moves
/// through uploading → analyzing (one or more batches) → generating the
/// merged final answer, the label keeps pace — see
/// `GeminiService.sendMessageWithImages`'s `onProgress` callback, which is
/// what drives these values.
class _LiveStatus extends StatefulWidget {
  final bool hasImages;
  final GeminiBatchStage? stage;
  final int currentBatch;
  final int totalBatches;

  const _LiveStatus({
    this.hasImages = false,
    this.stage,
    this.currentBatch = 0,
    this.totalBatches = 0,
  });

  @override
  State<_LiveStatus> createState() => _LiveStatusState();
}

class _LiveStatusState extends State<_LiveStatus>
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

  String get _label {
    if (!widget.hasImages) return 'Thinking...';
    switch (widget.stage) {
      case GeminiBatchStage.uploading:
        return 'Reading image...';
      case GeminiBatchStage.analyzing:
        return widget.totalBatches > 1
            ? 'Analyzing (Batch ${widget.currentBatch} of ${widget.totalBatches})...'
            : 'Analyzing...';
      case GeminiBatchStage.generating:
        return 'Writing...';
      case null:
        return 'Reading image...';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No bubble, no background, no border, no shadow — just the dot and
    // the label, sitting directly in the conversation flow at the same
    // spot the old typing indicator occupied.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
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
            _label,
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

/// The AI Modes entry point, now placed above the message input bar
/// (ChatGPT-style) instead of the app bar. Shows the active mode's emoji
/// plus the static "Select Model" label, tapped to open [showAiModeSheet].
/// Purely presentational — [ChatScreen._pickMode] owns the actual sheet
/// call and state update; the underlying AI Modes are unchanged.
///
/// Step 27C: restyled from a solid primary-tinted pill to a light,
/// quiet neutral chip (light-gray fill, thin light-gray border, dark
/// text) — the heavy solid-green look read as too loud for a settings-
/// style control. Tap target, emoji, label, and behavior are unchanged.
class _ModePill extends StatefulWidget {
  final AiMode mode;
  final VoidCallback onTap;

  const _ModePill({required this.mode, required this.onTap});

  @override
  State<_ModePill> createState() => _ModePillState();
}

class _ModePillState extends State<_ModePill> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        // Step 28 polish: same soft/diffused manual shadow treatment as the
        // quick-action pills (instead of Material's harsher directional
        // elevation shadow) for a consistent, premium feel across the Home
        // controls. Same tap target, emoji, label, and behavior.
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.07),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Material(
            color: _PakHome.border.withOpacity(0.65),
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: widget.onTap,
              child: Container(
                constraints: const BoxConstraints(minHeight: 44, maxHeight: 46),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.mode.emoji, style: const TextStyle(fontSize: 16)),
                    const SizedBox(width: 8),
                    Text(
                      'Select Model',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _PakHome.text,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: _PakHome.secondaryText,
                    ),
                  ],
                ),
              ),
            ),
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

/// Step 27D: restyled to a small, premium rounded card (soft emerald-tinted
/// background, thin border, tighter padding) instead of the old edge-to-edge
/// solid-color strip — appearance only. It still shows/hides on exactly the
/// same `_hasApiKey` condition and `onSetUp` still opens Settings unchanged.
class _ApiKeyBanner extends StatelessWidget {
  final VoidCallback onSetUp;
  const _ApiKeyBanner({required this.onSetUp});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _PakHome.emerald.withOpacity(0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _PakHome.emerald.withOpacity(0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.key_rounded, size: 16, color: _PakHome.emerald),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Add your Gemini API key to start chatting.',
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: _PakHome.text,
                ),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                foregroundColor: _PakHome.emerald,
              ),
              onPressed: onSetUp,
              child: Text(
                'Set up',
                style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Step 29 (data), Step 37 (presentation): the six Home quick-action
/// entries, in the exact order shown in the mockup — Ask a question /
/// Brainstorm ideas / Write a script / Summarize a file / Translate text /
/// Explain an image — each just filling the existing composer via
/// [_applySuggestion]; sending itself still goes through the normal,
/// unmodified input bar.
///
/// Step 37: the `description` field was removed — the new pill layout is
/// icon + title only, so a separate description string no longer has
/// anywhere to render.
class _HomeQuickAction {
  final IconData icon;
  final String label;
  final String prompt;
  const _HomeQuickAction({
    required this.icon,
    required this.label,
    required this.prompt,
  });
}

const _HomeQuickAction _kActionAsk = _HomeQuickAction(
  icon: Icons.chat_bubble_outline_rounded,
  label: 'Ask a question',
  prompt: 'Ask a question',
);
const _HomeQuickAction _kActionBrainstorm = _HomeQuickAction(
  icon: Icons.lightbulb_outline_rounded,
  label: 'Brainstorm ideas',
  prompt: 'Brainstorm ideas',
);
const _HomeQuickAction _kActionScript = _HomeQuickAction(
  icon: Icons.edit_outlined,
  label: 'Write a script',
  prompt: 'Write a script',
);
const _HomeQuickAction _kActionSummarize = _HomeQuickAction(
  icon: Icons.description_outlined,
  label: 'Summarize a file',
  prompt: 'Summarize a file',
);
const _HomeQuickAction _kActionTranslate = _HomeQuickAction(
  icon: Icons.public,
  label: 'Translate text',
  prompt: 'Translate text',
);
const _HomeQuickAction _kActionExplainImage = _HomeQuickAction(
  icon: Icons.image_outlined,
  label: 'Explain an image',
  prompt: 'Explain an image',
);

/// Step 37: the ordered list of all six quick actions, used to build the
/// pill `Wrap` in [_EmptyState].
const List<_HomeQuickAction> _kHomeQuickActions = [
  _kActionAsk,
  _kActionBrainstorm,
  _kActionScript,
  _kActionSummarize,
  _kActionTranslate,
  _kActionExplainImage,
];

/// A clean, minimal "empty chat" home screen matching the approved mockup
/// pixel-for-pixel: a light decorative Pakistan-outline backdrop, a
/// left-aligned bold serif "How can I help you today?" heading, and
/// the six quick-action cards (icon, bold title, short description) laid
/// out as a 2-column x 3-row grid.
class _EmptyState extends StatelessWidget {
  final ThemeData theme;

  /// Invoked with a suggestion's prompt text when its card is tapped.
  /// Only fills the composer — sending still goes through the normal
  /// input bar, so this stays a pure UI convenience.
  final ValueChanged<String> onSuggestionTap;

  const _EmptyState({
    Key? key,
    required this.theme,
    required this.onSuggestionTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Step 28 — Final Premium UI Refinement: fixed light palette (see
    // `_PakHome`), a 24/16 spacing rhythm, and everything explicitly
    // left-aligned (width: double.infinity + crossAxisAlignment.start +
    // TextAlign.left) so nothing can ever collapse to content-width and
    // read as centered. Chat bubbles, streaming, attachments, and routing
    // are untouched — this widget only ever mounts on the empty
    // conversation state.
    return DecoratedBox(
      decoration: const BoxDecoration(color: _PakHome.background),
      child: Stack(
        children: [
          // Light decorative map line — very subtle (~2% opacity), drawn
          // behind everything else so it can never interfere with text.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _PakOutlinePainter(
                  color: _PakHome.text.withOpacity(0.02),
                ),
              ),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FadeInUp(
                    duration: const Duration(milliseconds: 420),
                    child: Text(
                      'How can I help you today?',
                      textAlign: TextAlign.left,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                      height: 1.18,
                      letterSpacing: -0.2,
                      color: _PakHome.text,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                // Step 37 — Home Quick Actions Redesign (Pill Style): the
                // old 2-column x 3-row description cards are fully
                // replaced with a compact, icon + title only pill layout.
                // A `Wrap` (rather than a fixed grid) is what makes this
                // responsive on every screen size — pills flow left to
                // right and wrap onto as many rows as the available width
                // needs, so nothing ever overflows horizontally on narrow
                // phones, and wider phones/tablets simply fit more pills
                // per row. Each pill sizes itself to its own content
                // (`mainAxisSize: MainAxisSize.min` inside the pill), so
                // there is no shared-height measurement step to maintain
                // any more.
                FadeInUp(
                  duration: const Duration(milliseconds: 420),
                  delay: const Duration(milliseconds: 100),
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final action in _kHomeQuickActions)
                        _QuickActionPill(
                          action: action,
                          onTap: () => onSuggestionTap(action.prompt),
                        ),
                    ],
                  ),
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

/// Step 37 — Home Quick Actions Redesign (Pill Style). One quick-action
/// pill: a small emerald icon-in-circle followed by the title only — no
/// description text. Fully rounded (`StadiumBorder`) with a soft diffused
/// shadow and a white, faintly translucent "glass" background (a subtle
/// border plus a slight opacity give it a light glassy edge without
/// needing a blur filter). Content is a single `Row` whose default
/// cross-axis alignment is `center`, so the icon and title are always
/// vertically centered inside the pill regardless of its height. Sized to
/// its own content (`MainAxisSize.min`) so it works naturally inside the
/// enclosing `Wrap`, which is what makes the whole layout responsive
/// across phone and tablet widths. Same quiet press-scale + ripple
/// interaction as the card it replaces.
class _QuickActionPill extends StatefulWidget {
  final _HomeQuickAction action;
  final VoidCallback onTap;
  const _QuickActionPill({
    required this.action,
    required this.onTap,
  });

  @override
  State<_QuickActionPill> createState() => _QuickActionPillState();
}

class _QuickActionPillState extends State<_QuickActionPill> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        // A soft, wide, low-opacity manual shadow (instead of Material's
        // default directional elevation shadow) reads as premium/diffused
        // rather than a hard drop-shadow.
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.rectangle,
            borderRadius: const BorderRadius.all(Radius.circular(100)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_pressed ? 0.04 : 0.08),
                blurRadius: _pressed ? 10 : 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Material(
            // "white / glass-like": a near-opaque white fill plus a
            // hairline white-ish border reads as a soft glass pill against
            // the app's light background, while staying fully legible.
            color: _PakHome.card.withOpacity(0.94),
            shape: StadiumBorder(
              side: BorderSide(
                color: Colors.white.withOpacity(0.6),
                width: 1,
              ),
            ),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _PakHome.emerald.withOpacity(0.10),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        widget.action.icon,
                        size: 16,
                        color: _PakHome.emerald,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        widget.action.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.poppins(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.1,
                          color: _PakHome.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A deliberately simplified, stylized silhouette evoking Pakistan's
/// borders — decorative texture, not a surveying-grade map. Drawn as a
/// fraction-of-canvas polygon so it scales cleanly to any screen size,
/// with no overflow at any width.
class _PakOutlinePainter extends CustomPainter {
  final Color color;
  const _PakOutlinePainter({required this.color});

  static const List<Offset> _points = [
    Offset(0.62, 0.06),
    Offset(0.70, 0.10),
    Offset(0.78, 0.09),
    Offset(0.86, 0.15),
    Offset(0.90, 0.24),
    Offset(0.84, 0.30),
    Offset(0.88, 0.38),
    Offset(0.80, 0.46),
    Offset(0.83, 0.55),
    Offset(0.74, 0.64),
    Offset(0.76, 0.74),
    Offset(0.64, 0.84),
    Offset(0.58, 0.92),
    Offset(0.46, 0.90),
    Offset(0.38, 0.80),
    Offset(0.24, 0.78),
    Offset(0.10, 0.70),
    Offset(0.06, 0.60),
    Offset(0.16, 0.54),
    Offset(0.14, 0.44),
    Offset(0.26, 0.40),
    Offset(0.22, 0.30),
    Offset(0.32, 0.24),
    Offset(0.30, 0.14),
    Offset(0.42, 0.10),
    Offset(0.50, 0.14),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    for (var i = 0; i < _points.length; i++) {
      final p = Offset(_points[i].dx * size.width, _points[i].dy * size.height);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();

    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;
    final fillPaint = Paint()
      ..color = color.withOpacity(color.opacity * 0.4)
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _PakOutlinePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Modern, rounded message bar in the style of ChatGPT/Gemini: a circular
/// attachment ("+") button, a pill-shaped text field with an inline mic
/// button, and a circular send button.
class _ChatInputBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isSending;
  // Step 26: true while a reply is actively streaming in — swaps the
  // Send button for a Stop button (tapping it keeps whatever text has
  // already arrived, exactly like ChatGPT's stop-generating button).
  final bool isStreaming;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttachment;
  final VoidCallback onVoice;

  const _ChatInputBar({
    super.key,
    required this.controller,
    required this.isSending,
    required this.isStreaming,
    required this.onSend,
    required this.onStop,
    required this.onAttachment,
    required this.onVoice,
  });

  @override
  State<_ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<_ChatInputBar> {
  // Step 12.2: drives a subtle border/glow animation so the input pill
  // visibly "wakes up" on focus, matching ChatGPT/Meta AI's composer.
  final FocusNode _focusNode = FocusNode();
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
    _focusNode.dispose();
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
          // Step 27B: a faint top-to-bottom emerald-tinted gradient (was a
          // flat fill) plus a slightly deeper, softer shadow — the
          // "floating premium pill" look — while every focus/typing
          // behavior underneath stays exactly as it was.
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.colorScheme.surfaceContainerHigh,
                theme.colorScheme.surfaceContainerHigh.withOpacity(0.96),
              ],
            ),
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
                    .withOpacity(isDark ? 0.06 : (_focused ? 0.14 : 0.08)),
                blurRadius: _focused ? 22 : 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.only(left: 4, right: 4),
          // Step 48: the send button is now pinned to the row's bottom
          // edge with the same `Padding(bottom: 2)` treatment as the "+"
          // and mic buttons, instead of being vertically centered against
          // the full (IntrinsicHeight) row height. With `crossAxisAlignment:
          // end`, every icon button in this row — attach, mic, send — now
          // anchors to the bottom-right/bottom-left corners identically,
          // so growing the text field to multiple lines only ever grows
          // the row upward from a fixed bottom edge; it can never push the
          // send button up toward the middle the way center-alignment did.
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
                  message: 'Record a voice message',
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      // Step 43: a single tap always starts a new
                      // recording — the toggle/listening states this
                      // button used to have (continuous speech-to-text)
                      // are gone; once recording starts, this whole
                      // composer is swapped out for `_VoiceRecordingBar`
                      // (see the parent screen's build method), so this
                      // button is never shown again until idle.
                      onTap: () {
                        HapticFeedback.selectionClick();
                        onVoice();
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(11),
                        child: Icon(
                          Icons.mic_none_rounded,
                          size: 21,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Step 48: pinned to the row's bottom edge (matching the "+"
              // and mic buttons above) instead of vertically centering
              // against the full row height — see the Step 48 note by the
              // Row above. Size, icon, color, shape, animation, and
              // behavior below are all unchanged.
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Padding(
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
                        // Step 31 — Send Button Polish: padding trimmed from
                        // 11 to 8 (paired with the smaller icon/spinner/stop
                        // sizes below) shrinks the button's overall diameter
                        // from 42dp to 34dp — a 19% reduction — while
                        // keeping the same color, icon, animation, and
                        // behavior untouched.
                        padding: const EdgeInsets.all(8),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: isStreaming
                              ? Container(
                                  key: const ValueKey('stop'),
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onPrimary,
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                )
                              : isSending
                                  ? SizedBox(
                                      key: const ValueKey('sending'),
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    )
                                  : Icon(
                                      Icons.arrow_upward_rounded,
                                      key: const ValueKey('send'),
                                      color: theme.colorScheme.onPrimary,
                                      size: 18,
                                    ),
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
