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
import '../core/theme/chat_palette.dart';
import '../models/chat_attachment.dart';
import '../models/chat_message.dart';
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
          leading: Builder(
            builder: (context) => IconButton(
              tooltip: 'Menu',
              icon: const Icon(Icons.menu_rounded),
              iconSize: 22,
              splashRadius: 22,
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          titleSpacing: 0,
          title: Text(
            _isLoadingHistory ? 'AI Chat' : conversationTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: 'New chat',
              icon: const Icon(Icons.add_comment_outlined),
              iconSize: 22,
              splashRadius: 22,
              onPressed: _startNewChat,
            ),
            if (_messages.isNotEmpty)
              IconButton(
                tooltip: 'Clear chat',
                icon: const Icon(Icons.delete_outline_rounded),
                iconSize: 22,
                splashRadius: 22,
                onPressed: _clearChat,
              ),
          ],
        ),
        body: Column(
          children: [
            if (!_hasApiKey) _ApiKeyBanner(onSetUp: _openSettings),
            Expanded(
              child: _isLoadingHistory
                  ? const Center(child: CircularProgressIndicator())
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _messages.isEmpty
                          ? _EmptyState(
                              key: ValueKey('empty-$_conversationId'),
                              theme: theme,
                            )
                          : ListView.builder(
                              key: ValueKey('list-$_conversationId'),
                              controller: _scrollController,
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
                                return FadeInUp(
                                  duration: const Duration(milliseconds: 220),
                                  from: 8,
                                  child: GestureDetector(
                                  onLongPress: () => _copyMessage(message.text),
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
                                            ? () => _regenerateResponse(index)
                                            : null,
                                    onReadAloud: isAiReply
                                        ? () => _toggleSpeak(index, message.text)
                                        : null,
                                    isSpeaking: _speakingIndex == index,
                                    animate:
                                        identical(message, _streamingMessage),
                                    onStreamTick: _scrollToBottom,
                                  ),
                                  ),
                                );
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

/// A premium, minimal "empty chat" welcome screen — similar in spirit to
/// ChatGPT/Gemini's landing state: a soft gradient mark, a short intro,
/// and a compact list of what the assistant can help with.
class _EmptyState extends StatelessWidget {
  final ThemeData theme;
  const _EmptyState({super.key, required this.theme});

  static const List<(IconData, String)> _capabilities = [
    (Icons.help_outline_rounded, 'Ask questions'),
    (Icons.image_outlined, 'Generate images'),
    (Icons.description_outlined, 'Write scripts'),
    (Icons.lightbulb_outline_rounded, 'Solve problems'),
    (Icons.auto_awesome_outlined, 'Create content'),
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeIn(
              duration: const Duration(milliseconds: 400),
              child: Container(
                width: 84,
                height: 84,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.primary.withOpacity(0.18),
                    width: 2,
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.primary,
                        theme.colorScheme.primary.withOpacity(0.7),
                      ],
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.primary.withOpacity(0.28),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: theme.colorScheme.onPrimary,
                    size: 32,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            FadeInUp(
              duration: const Duration(milliseconds: 400),
              delay: const Duration(milliseconds: 80),
              child: Text(
                'AI Assistant',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            const SizedBox(height: 6),
            FadeInUp(
              duration: const Duration(milliseconds: 400),
              delay: const Duration(milliseconds: 130),
              child: Text(
                'What can I do for you?',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 28),
            ...List.generate(_capabilities.length, (index) {
              final (icon, label) = _capabilities[index];
              return FadeInUp(
                duration: const Duration(milliseconds: 400),
                delay: Duration(milliseconds: 170 + index * 60),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.shadow.withOpacity(0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            icon,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Text(label, style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
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
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final isSending = widget.isSending;
    final onSend = widget.onSend;
    final onAttachment = widget.onAttachment;
    final onVoice = widget.onVoice;

    final hasText = controller.text.trim().isNotEmpty;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        // Step 12.1: the whole bar is now one rounded, shadowed pill —
        // "+" button, text field, mic, and send all live inside it, like
        // Meta AI — instead of a separate circular "+" button floating
        // outside the field.
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: theme.colorScheme.shadow.withOpacity(0.10),
                blurRadius: 18,
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
                      onTap: onAttachment,
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
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: "Let's chat...",
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
                      onTap: onVoice,
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
                      onTap: isSending ? null : onSend,
                      child: Padding(
                        padding: const EdgeInsets.all(11),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
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
