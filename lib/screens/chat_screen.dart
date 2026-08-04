import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/providers/conversation_provider.dart';
import '../core/services/attachment_processor_service.dart';
import '../core/services/attachment_service.dart';
import '../core/services/gemini_service.dart';
import '../core/services/tts_voice_service.dart';
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

  // Read Aloud (Step 10): on-device TTS for AI replies. `_speakingIndex`
  // tracks which message (if any) is currently being read, so only one
  // bubble shows the "stop" state at a time.
  final FlutterTts _tts = FlutterTts();
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

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _checkApiKey();
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speakingIndex = null);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _speakingIndex = null);
    });
    _tts.setErrorHandler((_) {
      if (mounted) setState(() => _speakingIndex = null);
    });
    // Fire-and-forget: picks the best available male English voice and a
    // natural rate/pitch. Runs once per screen lifetime; if it's still in
    // flight when the person taps "Read aloud" the first time, that first
    // utterance just uses the engine default and every one after sounds
    // right — never blocks or delays the tap itself.
    unawaited(TtsVoiceService.configureNaturalMaleVoice(_tts));
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
      await _tts.stop();
      _speakingIndex = null;
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
      await _tts.stop();
      _speakingIndex = null;
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
    _tts.stop();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    final pendingAttachment = _pendingAttachment;
    if ((text.isEmpty && pendingAttachment == null) || _isSending) return;

    ChatAttachment? attachmentMeta;
    GeminiInlinePart? attachmentPart;

    if (pendingAttachment != null) {
      // Show activity right away — compressing/reading a file can take a
      // moment, and the send button's spinner is the only feedback for it.
      setState(() => _isSending = true);
      try {
        final processed = await AttachmentProcessorService.process(
          pendingAttachment.result,
          pendingAttachment.source,
        );
        attachmentMeta = processed.metadata;
        attachmentPart = processed.part;
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

      final reply = await GeminiService.sendMessage(
        outgoingText,
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
  /// Only one message plays at a time — starting a new one cancels any
  /// reply currently being read.
  Future<void> _toggleSpeak(int index, String text) async {
    if (_speakingIndex == index) {
      await _tts.stop();
      if (mounted) setState(() => _speakingIndex = null);
      return;
    }
    await _tts.stop();
    if (!mounted) return;
    setState(() => _speakingIndex = index);
    await _tts.speak(text);
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
      await _tts.stop();
      _speakingIndex = null;
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
      await _tts.stop();
      _speakingIndex = null;
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

  /// Placeholder for future speech-to-text input.
  void _onVoiceTap() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Voice input coming soon.'),
        duration: Duration(seconds: 2),
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

  const _ChatInputBar({
    required this.controller,
    required this.isSending,
    required this.onSend,
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
                  message: 'Voice input',
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
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
