import 'chat_attachment.dart';

/// Simple immutable data model for a single chat message.
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final bool isError;
  final List<ChatAttachment> attachments;

  /// Step 40 — Chat-Native Intelligence UX Refactor: an optional, already-
  /// serialized `DocumentIntelligenceResult` (see
  /// `DocumentIntelligenceResult.toJson`/`.fromJson`) attached to an
  /// assistant message. When present, `ChatBubble` renders a compact,
  /// expandable `DocumentResultCard` instead of the plain Markdown body —
  /// [text] still holds a flat summary (used for copy/share/history/
  /// follow-up context), this is purely additional structured data for
  /// richer, progressive-disclosure rendering. `null` for every other
  /// message, including plain OCR/Handwriting results (those render as
  /// normal text).
  final Map<String, dynamic>? documentResult;

  /// STEP 56 — AI Q&A → PDF Export Feature: an optional, already-serialized
  /// `PdfExportResult` (see `PdfExportResult.toJson`/`.fromJson` in
  /// `pdf_export_service.dart`) attached to an assistant message. When
  /// present, `ChatBubble` renders a compact "📄 PDF Ready" card
  /// (`PdfExportResultCard`) instead of the plain Markdown body — exactly
  /// the same pattern as `documentResult` above. [text] still holds a
  /// short plain-text summary for copy/share/history. `null` for every
  /// other message.
  final Map<String, dynamic>? pdfExportResult;

  ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
    this.isError = false,
    this.attachments = const [],
    this.documentResult,
    this.pdfExportResult,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'text': text,
        'isUser': isUser,
        'timestamp': timestamp.toIso8601String(),
        'isError': isError,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
        if (documentResult != null) 'documentResult': documentResult,
        if (pdfExportResult != null) 'pdfExportResult': pdfExportResult,
      };

  // `attachments` is a new field as of Step 9 — history saved by earlier
  // steps simply won't have the key, so it defaults to an empty list
  // instead of failing to parse. This is what keeps old chat history
  // loading correctly after this update. `documentResult` (Step 40)
  // follows the exact same pattern: absent in any history saved before
  // this step, so it just defaults to `null`.
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
        documentResult: json['documentResult'] as Map<String, dynamic>?,
        pdfExportResult: json['pdfExportResult'] as Map<String, dynamic>?,
      );
}
