import 'chat_attachment.dart';

/// Simple immutable data model for a single chat message.
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool isError;
  final List<ChatAttachment> attachments;

  ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.isError = false,
    this.attachments = const [],
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'text': text,
        'isUser': isUser,
        'timestamp': timestamp.toIso8601String(),
        'isError': isError,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
      };

  // `attachments` is a new field as of Step 9 — history saved by earlier
  // steps simply won't have the key, so it defaults to an empty list
  // instead of failing to parse. This is what keeps old chat history
  // loading correctly after this update.
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        text: json['text'] as String,
        isUser: json['isUser'] as bool,
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
        isError: json['isError'] as bool? ?? false,
        attachments: (json['attachments'] as List<dynamic>?)
                ?.map((e) => ChatAttachment.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}
