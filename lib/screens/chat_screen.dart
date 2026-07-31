import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:animate_do/animate_do.dart';

import '../core/services/attachment_processor_service.dart';
import '../core/services/attachment_service.dart';
import '../core/services/gemini_service.dart';
import '../core/services/chat_storage_service.dart';
import '../models/chat_attachment.dart';
import '../models/chat_message.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/attachment_sheet.dart';
import '../widgets/chat_bubble.dart';
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

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _checkApiKey();
  }

  Future<void> _loadHistory() async {
    final history = await ChatStorageService.loadMessages();
    if (!mounted) return;
    setState(() {
      _messages.addAll(history);
      _isLoadingHistory = false;
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
    unawaited(ChatStorageService.saveMessages(_messages));

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
      setState(() {
        _messages.add(ChatMessage(text: reply, isUser: false));
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
      unawaited(ChatStorageService.saveMessages(_messages));
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

  Future<void> _clearChat() async {
    setState(() => _messages.clear());
    await ChatStorageService.clearMessages();
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Chat'),
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              tooltip: 'Clear chat',
              icon: const Icon(Icons.delete_outline_rounded),
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
                : _messages.isEmpty
                    ? _EmptyState(theme: theme)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length + (_isSending ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _messages.length) {
                            return const TypingIndicator();
                          }
                          final message = _messages[index];
                          return GestureDetector(
                            onLongPress: () => _copyMessage(message.text),
                            child: ChatBubble(message: message),
                          );
                        },
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
  const _EmptyState({required this.theme});

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
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.secondary,
                    ],
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: theme.colorScheme.onPrimary,
                  size: 32,
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
                ),
              ),
            ),
            const SizedBox(height: 6),
            FadeInUp(
              duration: const Duration(milliseconds: 400),
              delay: const Duration(milliseconds: 130),
              child: Text(
                'Your intelligent AI companion.',
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
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Text(label, style: theme.textTheme.bodyMedium),
                    ],
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
class _ChatInputBar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
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
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                constraints: const BoxConstraints(minHeight: 48),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(26),
                ),
                padding: const EdgeInsets.only(left: 18, right: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 5,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => onSend(),
                        decoration: const InputDecoration(
                          hintText: 'Message AI Assistant…',
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          isCollapsed: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Voice input',
                      icon: Icon(
                        Icons.mic_none_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onPressed: onVoice,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: theme.colorScheme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: isSending ? null : onSend,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: isSending
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : Icon(
                          Icons.arrow_upward_rounded,
                          color: theme.colorScheme.onPrimary,
                          size: 20,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
