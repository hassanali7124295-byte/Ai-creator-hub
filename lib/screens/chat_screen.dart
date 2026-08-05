import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
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
import 'settings_screen.dart';

/// Step 18.5: the mic button's three states — idle (normal mic icon),
/// listening (animated equalizer, tap again to stop), and processing (a
/// brief spinner while the final result settles before returning to idle).
enum _MicState { idle, listening, processing }

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
  _PendingAttachment? _pendingAttachment;

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
    _scrollToBottom();
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
    await provider.selectConversation(id);
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(provider.currentMessages);
      _conversationId = id;
      _streamingMessage = null;
      _pendingAttachment = null;
    });
    _scrollToBottom();
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
    final id = await provider.startNewConversation();
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(provider.currentMessages);
      _conversationId = id;
      _streamingMessage = null;
      _pendingAttachment = null;
    });
    _scrollToBottom();
  }

  Future<void> _checkApiKey() async {
    final hasKey = await GeminiService.hasApiKey();
    if (!mounted) return;
    setState(() => _hasApiKey = hasKey);
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    VoiceManager.instance.removeListener(_onVoiceStateChanged);
    unawaited(VoiceManager.instance.stop());
    _voiceInput.cancel();
    super.dispose();
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
    final pendingAttachment = _pendingAttachment;
    if ((text.isEmpty && pendingAttachment == null) || _isSending) return;

    ChatAttachment? attachmentMeta;
    GeminiInlinePart? attachmentPart;
    String? attachmentExtractedText;

    if (pendingAttachment != null) {
      // Show activity right away — compressing/reading a file (or
      // extracting text from a PDF) can take a moment, and the send
      // button's spinner is the only feedback for it.
      setState(() => _isSending = true);
      try {
        final processed = await AttachmentProcessorService.process(
          pendingAttachment.result,
          pendingAttachment.source,
        );
        attachmentMeta = processed.metadata;
        attachmentPart = processed.part;
        attachmentExtractedText = processed.extractedText;
      } on AttachmentException catch (e) {
        _reportAttachmentFailure(e.message);
        return;
      } catch (_) {
        _reportAttachmentFailure('Could not process that attachment.');
        return;
      }
    }

    // Allow sending an attachment on its own with a sensible default
    // prompt, rather than forcing the user to type something first.
    final outgoingText =
        text.isNotEmpty ? text : 'What can you tell me about this attachment?';

    setState(() {
      _messages.add(ChatMessage(
        text: outgoingText,
        isUser: true,
        attachments: attachmentMeta != null ? [attachmentMeta] : const [],
      ));
      _isSending = true;
      _pendingAttachment = null;
    });
    _inputController.clear();
    _scrollToBottom();
    unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));

    try {
      // Build lightweight history from prior turns so Gemini has context.
      final history = _messages
          .where((m) => !m.isError)
          .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
          .toList();
      // Drop the message we just added from history (it's sent as `prompt`).
      if (history.isNotEmpty) history.removeLast();

      // A PDF's extracted text is folded into the outgoing prompt for
      // *this* turn only — the chat bubble still shows just what the user
      // typed (or the default prompt), and `history` above already used
      // that shorter text, so a long document is never re-sent on every
      // follow-up message.
      final geminiPrompt = attachmentExtractedText != null
          ? '$attachmentExtractedText\n\n${outgoingText}'
          : outgoingText;

      final reply = await GeminiService.sendMessage(
        geminiPrompt,
        history: history,
        attachments: attachmentPart != null ? [attachmentPart] : const [],
        modeInstruction: _mode.systemPrompt,
      );

      if (!mounted) return;
      final aiMessage = ChatMessage(text: reply, isUser: false);
      setState(() {
        _messages.add(aiMessage);
        _streamingMessage = aiMessage;
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
      if (mounted) setState(() => _isSending = false);
      _scrollToBottom();
      unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
    }
  }

  /// Surfaces an attachment processing failure as an inline error bubble,
  /// matching how Gemini API errors are already shown. The attachment
  /// stays pending so the user can just remove it or try sending again.
  void _reportAttachmentFailure(String message) {
    if (!mounted) return;
    setState(() {
      _messages.add(ChatMessage(text: message, isUser: false, isError: true));
      _isSending = false;
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
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

    setState(() {
      _messages.removeAt(aiIndex);
      _isSending = true;
    });
    _scrollToBottom();

    try {
      final history = _messages
          .sublist(0, aiIndex - 1)
          .where((m) => !m.isError)
          .map((m) => {'role': m.isUser ? 'user' : 'model', 'text': m.text})
          .toList();

      final reply = await GeminiService.sendMessage(
        userMessage.text,
        history: history,
        modeInstruction: _mode.systemPrompt,
      );

      if (!mounted) return;
      final aiMessage = ChatMessage(text: reply, isUser: false);
      setState(() {
        _messages.insert(aiIndex, aiMessage);
        _streamingMessage = aiMessage;
      });
    } on GeminiException catch (e) {
      if (!mounted) return;
      setState(() {
        _messages.insert(
          aiIndex,
          ChatMessage(text: e.message, isUser: false, isError: true),
        );
      });
      _checkApiKey();
    } finally {
      if (mounted) setState(() => _isSending = false);
      _scrollToBottom();
      unawaited(context.read<ConversationProvider>().saveCurrentMessages(_messages));
    }
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
  /// and — as of Step 9 — holds the result as a pending attachment shown
  /// above the input bar until the message is sent (or removed).
  Future<void> _openAttachmentSheet() async {
    if (_isSending) return;
    final type = await showAttachmentSheet(context);
    if (type == null || !mounted) return;

    try {
      AttachmentResult? result;
      switch (type) {
        case AttachmentType.gallery:
          result = await AttachmentService.pickFromGallery();
          break;
        case AttachmentType.camera:
          result = await AttachmentService.pickFromCamera();
          break;
        case AttachmentType.document:
          result = await AttachmentService.pickDocument();
          break;
        case AttachmentType.file:
          result = await AttachmentService.pickAnyFile();
          break;
      }

      if (!mounted || result == null) return;

      final mimeType = AttachmentProcessorService.detectMimeType(result.path);
      final kind = AttachmentProcessorService.classify(type, mimeType);

      setState(() {
        _pendingAttachment = _PendingAttachment(
          result: result!,
          source: type,
          previewMeta: ChatAttachment(
            name: result.name,
            mimeType: mimeType,
            sizeBytes: result.sizeBytes ?? 0,
            kind: kind,
            path: result.path,
          ),
        );
      });
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

  void _removePendingAttachment() {
    setState(() => _pendingAttachment = null);
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
        ),
        body: Column(
          children: [
            if (!_hasApiKey) _ApiKeyBanner(onSetUp: _openSettings),
            Expanded(
              child: _isLoadingHistory
                  ? const Center(child: CircularProgressIndicator())
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _messages.isEmpty
                          ? _EmptyState(
                              key: ValueKey('empty-$_conversationId'),
                              theme: theme,
                              onSuggestionTap: _applySuggestion,
                            )
                          : ListView.builder(
                              key: ValueKey('list-$_conversationId'),
                              controller: _scrollController,
                              physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                              padding: const EdgeInsets.all(16),
                              itemCount:
                                  _messages.length + (_isSending ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (index == _messages.length) {
                                  return const TypingIndicator();
                                }
                                final message = _messages[index];
                                final isAiReply =
                                    !message.isUser && !message.isError;
                                final isLast = index == _messages.length - 1;
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
                                          isSpeaking: _speakingIndex == index,
                                          animate: identical(
                                              message, _streamingMessage),
                                          onStreamTick: _scrollToBottom,
                                        ),
                                      );
                                return entrance;
                              },
                            ),
                    ),
            ),
            if (_pendingAttachment != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: AttachmentPreview(
                    attachment: _pendingAttachment!.previewMeta,
                    onRemove: _isSending ? null : _removePendingAttachment,
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
              isSending: _isSending,
              onSend: _sendMessage,
              onAttachment: _openAttachmentSheet,
              onVoice: _onVoiceTap,
              micState: _micState,
            ),
          ],
        ),
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

/// A clean, minimal "empty chat" welcome screen in the style of Meta AI:
/// a bold left-aligned heading, generous empty space, and a handful of
/// small outlined suggestion chips — no crowded card list.
class _EmptyState extends StatelessWidget {
  final ThemeData theme;

  /// Invoked with a suggestion's prompt text when its chip is tapped.
  /// Only fills the composer — sending still goes through the normal
  /// input bar, so this stays a pure UI convenience.
  final ValueChanged<String> onSuggestionTap;

  const _EmptyState({super.key, required this.theme, required this.onSuggestionTap});

  // Step 12.3: was 5 large cards ("Ask questions", "Generate images",
  // "Write scripts", "Solve problems", "Create content") — trimmed to 4
  // short prompts that read as quick-tap chips rather than a menu.
  static const List<String> _suggestions = [
    'Ask a question',
    'Brainstorm ideas',
    'Write a script',
    'Summarize a file',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 36, 28, 24),
      // Step 12.3: content is now anchored top-left instead of centered —
      // centering was a big part of why the old screen felt like a
      // crowded, busy "menu" rather than a calm, premium landing state.
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeInUp(
              duration: const Duration(milliseconds: 420),
              child: Text(
                'What can I do\nfor you?',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                  letterSpacing: -0.6,
                ),
                textAlign: TextAlign.left,
              ),
            ),
            // Step 12.3: a much bigger gap under the heading — the old
            // screen had only 28px before the first card; this breathing
            // room is what makes the screen feel spacious rather than
            // packed.
            const SizedBox(height: 40),
            FadeInUp(
              duration: const Duration(milliseconds: 420),
              delay: const Duration(milliseconds: 90),
              child: Wrap(
                alignment: WrapAlignment.start,
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final suggestion in _suggestions)
                    _SuggestionChip(
                      label: suggestion,
                      theme: theme,
                      onTap: () => onSuggestionTap(suggestion),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small, rounded, outlined suggestion chip — Meta AI style: no fill,
/// just a soft border, compact padding, and a quiet press animation.
class _SuggestionChip extends StatefulWidget {
  final String label;
  final ThemeData theme;
  final VoidCallback onTap;

  const _SuggestionChip({
    required this.label,
    required this.theme,
    required this.onTap,
  });

  @override
  State<_SuggestionChip> createState() => _SuggestionChipState();
}

class _SuggestionChipState extends State<_SuggestionChip> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              HapticFeedback.selectionClick();
              widget.onTap();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.7),
                  width: 1.2,
                ),
              ),
              child: Text(
                widget.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
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
  final bool isSending;
  final VoidCallback onSend;
  final VoidCallback onAttachment;
  final VoidCallback onVoice;
  final _MicState micState;

  const _ChatInputBar({
    required this.controller,
    required this.isSending,
    required this.onSend,
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
    final onSend = widget.onSend;
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
                    color: hasText || isSending
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withOpacity(0.35),
                    shape: BoxShape.circle,
                  ),
                  child: Material(
                    color: Colors.transparent,
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
                        padding: const EdgeInsets.all(11),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          transitionBuilder: (child, animation) =>
                              ScaleTransition(scale: animation, child: child),
                          child: isSending
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
