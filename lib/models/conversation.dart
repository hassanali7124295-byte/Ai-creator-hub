import 'dart:math';

import 'chat_message.dart';

/// A single saved chat thread: a title, its messages, and the bookkeeping
/// needed to list, sort, search, and pin it in the conversation drawer.
///
/// Reuses [ChatMessage]'s existing `toJson`/`fromJson` for the message list,
/// so nothing about how individual messages (or their attachments) are
/// persisted has to change — only how they're grouped.
class Conversation {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  bool pinned;

  /// False until the user explicitly renames the conversation, or a first
  /// user message auto-generates a title. Lets [ConversationProvider] know
  /// whether it's still safe to overwrite [title] from the next message.
  bool hasCustomTitle;

  List<ChatMessage> messages;

  Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.pinned = false,
    this.hasCustomTitle = false,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];

  static const String defaultTitle = 'New chat';

  /// Creates a fresh, empty, untitled conversation with a locally-unique id.
  /// No package dependency needed for uniqueness — a microsecond timestamp
  /// plus a random suffix is more than enough entropy for a single device.
  factory Conversation.create() {
    final now = DateTime.now();
    final id =
        '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';
    return Conversation(
      id: id,
      title: defaultTitle,
      createdAt: now,
      updatedAt: now,
    );
  }

  bool get isEmpty => messages.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'pinned': pinned,
        'hasCustomTitle': hasCustomTitle,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return Conversation(
      id: json['id'] as String? ??
          '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? json['title'] as String
          : defaultTitle,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? now,
      pinned: json['pinned'] as bool? ?? false,
      hasCustomTitle: json['hasCustomTitle'] as bool? ?? false,
      messages: (json['messages'] as List<dynamic>?)
              ?.map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }

  /// Derives a short title from a message's text: first line only, trimmed,
  /// capped at 42 characters with an ellipsis. Used to auto-title a
  /// conversation from its first user message, the way ChatGPT/Gemini do.
  static String titleFromText(String text) {
    final firstLine = text.trim().split('\n').first.trim();
    if (firstLine.isEmpty) return defaultTitle;
    if (firstLine.length <= 42) return firstLine;
    return '${firstLine.substring(0, 42).trimRight()}…';
  }
}
