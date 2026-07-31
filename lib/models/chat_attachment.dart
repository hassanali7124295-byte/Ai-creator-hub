/// The broad category of an attachment. Deliberately small and generic —
/// adding a new kind later (e.g. `audio`) only requires a new enum value
/// plus one branch in `AttachmentProcessorService`; nothing else in the
/// model or storage layer needs to change.
enum ChatAttachmentKind { image, pdf, file }

extension ChatAttachmentKindX on ChatAttachmentKind {
  String get wireName => switch (this) {
        ChatAttachmentKind.image => 'image',
        ChatAttachmentKind.pdf => 'pdf',
        ChatAttachmentKind.file => 'file',
      };

  static ChatAttachmentKind fromWireName(String? value) {
    switch (value) {
      case 'image':
        return ChatAttachmentKind.image;
      case 'pdf':
        return ChatAttachmentKind.pdf;
      default:
        return ChatAttachmentKind.file;
    }
  }
}

/// Metadata describing a file the user attached to a chat message.
///
/// This intentionally stores metadata only (name, mime type, size, kind,
/// and a best-effort local [path]) — never the raw bytes. Raw bytes are
/// read, compressed (for images), base64-encoded and sent to Gemini at
/// send-time by `AttachmentProcessorService`, then discarded. That keeps
/// [ChatAttachment] cheap to persist alongside the rest of chat history in
/// `SharedPreferences`.
///
/// Because [path] points at a picker-provided temp/cache file, it may no
/// longer exist after the app restarts — UI code must handle that
/// (`ChatAttachmentPreview` falls back to a generic file chip when the
/// image can't be read).
class ChatAttachment {
  final String name;
  final String mimeType;
  final int sizeBytes;
  final ChatAttachmentKind kind;
  final String? path;

  const ChatAttachment({
    required this.name,
    required this.mimeType,
    required this.sizeBytes,
    required this.kind,
    this.path,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
        'kind': kind.wireName,
        'path': path,
      };

  factory ChatAttachment.fromJson(Map<String, dynamic> json) => ChatAttachment(
        name: json['name'] as String? ?? 'Attachment',
        mimeType: json['mimeType'] as String? ?? 'application/octet-stream',
        sizeBytes: json['sizeBytes'] as int? ?? 0,
        kind: ChatAttachmentKindX.fromWireName(json['kind'] as String?),
        path: json['path'] as String?,
      );
}
