import 'dart:convert';

import '../../models/chat_attachment.dart';
import '../../widgets/attachment_sheet.dart' show AttachmentType;
import 'attachment_processor_service.dart';
import 'attachment_service.dart';
import 'gemini_service.dart';

/// Step 39 — Advanced Document Intelligence.
///
/// Thrown when a document can't be prepared, analyzed, or queried. The
/// message is always safe to show to the user as-is (mirrors the pattern
/// used by [AttachmentException] / [TextRecognitionException]).
class DocumentIntelligenceException implements Exception {
  final String message;
  DocumentIntelligenceException(this.message);

  @override
  String toString() => message;
}

/// A single reconstructed table found in the document.
///
/// [headers] may be empty if the document's table has no clear header row.
/// Every row in [rows] is padded/truncated by the caller-facing UI to the
/// header width defensively — Gemini is asked to keep rows rectangular, but
/// nothing here assumes it always will.
class DocumentTable {
  final String? caption;
  final List<String> headers;
  final List<List<String>> rows;

  const DocumentTable({
    this.caption,
    required this.headers,
    required this.rows,
  });
}

/// The structured outcome of a successful [DocumentIntelligenceService.analyze]
/// call.
///
/// Every list field is extracted/verbatim content the model found *in* the
/// document — never invented. [summary] is the one clearly-generated field
/// (a short, model-written overview), kept visually distinct from the
/// extracted fields in the UI. If Gemini's reply couldn't be parsed as the
/// requested JSON shape at all, [rawFallbackText] holds the raw reply so the
/// user still sees something useful instead of an error.
class DocumentIntelligenceResult {
  final String? documentType;
  final String summary;
  final List<String> keyPoints;
  final List<String> headings;
  final List<String> dates;
  final List<String> names;
  final List<String> numbers;
  final List<String> keyFacts;
  final List<DocumentTable> tables;
  final String? rawFallbackText;

  const DocumentIntelligenceResult({
    this.documentType,
    required this.summary,
    this.keyPoints = const [],
    this.headings = const [],
    this.dates = const [],
    this.names = const [],
    this.numbers = const [],
    this.keyFacts = const [],
    this.tables = const [],
    this.rawFallbackText,
  });

  bool get isFallback => rawFallbackText != null;

  bool get hasAnyExtractedContent =>
      keyPoints.isNotEmpty ||
      headings.isNotEmpty ||
      dates.isNotEmpty ||
      names.isNotEmpty ||
      numbers.isNotEmpty ||
      keyFacts.isNotEmpty ||
      tables.isNotEmpty;
}

/// A document the user has picked and prepared for analysis — holds
/// whichever of [imagePart] / [extractedText] applies, computed once via
/// [DocumentIntelligenceService.prepare] and then reused for both the
/// initial [DocumentIntelligenceService.analyze] call and every follow-up
/// [DocumentIntelligenceService.askQuestion] call, so the source file is
/// only ever read/compressed/extracted a single time per pick.
class PreparedDocument {
  final String name;
  final ChatAttachmentKind kind;
  final GeminiInlinePart? imagePart;
  final String? extractedText;

  const PreparedDocument({
    required this.name,
    required this.kind,
    this.imagePart,
    this.extractedText,
  });
}

/// One grounded question/answer turn shown in the document Q&A panel.
class DocumentQaTurn {
  final String question;
  final String answer;

  /// True if the answer looks like Gemini's "not found in this document"
  /// sentinel reply — used only to render that turn with a slightly muted
  /// style; the full answer text is still shown either way.
  final bool foundInDocument;

  const DocumentQaTurn({
    required this.question,
    required this.answer,
    required this.foundInDocument,
  });
}

/// Extracts structured understanding from a document/image and answers
/// grounded follow-up questions about it.
///
/// This deliberately does NOT introduce a second image/document pipeline:
/// attachments are prepared via the same [AttachmentProcessorService] used
/// for chat attachments and Step 38's OCR/Handwriting (downscale/
/// compress/validate for images; on-device text extraction for PDFs), and
/// all reasoning is just [GeminiService.sendMessage] calls with dedicated
/// prompts — the same Gemini infrastructure already used everywhere else
/// in the app. Only the prompts and response parsing are new.
class DocumentIntelligenceService {
  DocumentIntelligenceService._();

  static const String _notFoundSentinel =
      "I couldn't find that information in this document.";

  /// Reads and prepares [file] (an image via [source] `.camera`/`.gallery`,
  /// or a PDF via `.document`) exactly once, reusing the existing
  /// attachment pipeline. Throws [DocumentIntelligenceException] with a
  /// message ready to show the user if the file can't be processed at all
  /// (corrupt, empty, unsupported, unreadable).
  static Future<PreparedDocument> prepare({
    required AttachmentResult file,
    required AttachmentType source,
  }) async {
    ProcessedAttachment processed;
    try {
      processed = await AttachmentProcessorService.process(file, source);
    } on AttachmentException catch (e) {
      throw DocumentIntelligenceException(e.message);
    } catch (_) {
      throw DocumentIntelligenceException(
        'Could not read "${file.name}". It may be corrupted or in an '
        'unsupported format.',
      );
    }

    if (processed.part == null && processed.extractedText == null) {
      throw DocumentIntelligenceException(
        'Could not extract any content from "${file.name}".',
      );
    }

    return PreparedDocument(
      name: file.name,
      kind: processed.metadata.kind,
      imagePart: processed.metadata.kind == ChatAttachmentKind.image
          ? processed.part
          : null,
      extractedText: processed.extractedText,
    );
  }

  /// Runs full document understanding + table reading on [doc] and returns
  /// a [DocumentIntelligenceResult]. Throws [DocumentIntelligenceException]
  /// if Gemini can't be reached, rejects the request, or reports the
  /// document has no readable content.
  static Future<DocumentIntelligenceResult> analyze(
    PreparedDocument doc,
  ) async {
    final reply = await _ask(doc, _analysisPrompt);
    return _parseAnalysis(reply);
  }

  /// Answers [question] about [doc], grounded strictly in its content.
  /// [priorTurns] (most-recent-last) is folded in as plain conversational
  /// context so short follow-ups ("and the total?") still resolve — the
  /// document itself is still re-supplied on every call, per the existing
  /// per-turn-attachment behavior documented on [GeminiService.sendMessage].
  static Future<DocumentQaTurn> askQuestion(
    PreparedDocument doc,
    String question, {
    List<DocumentQaTurn> priorTurns = const [],
  }) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty) {
      throw DocumentIntelligenceException('Please enter a question.');
    }

    final buffer = StringBuffer()..writeln(_qaInstructions);
    if (priorTurns.isNotEmpty) {
      buffer.writeln('\nPrevious questions and answers about this same '
          'document, for context only:');
      for (final turn in priorTurns) {
        buffer
          ..writeln('Q: ${turn.question}')
          ..writeln('A: ${turn.answer}');
      }
    }
    buffer
      ..writeln()
      ..writeln('Question: $trimmed');

    final reply = await _ask(doc, buffer.toString());
    final answer = reply.trim().isEmpty ? _notFoundSentinel : reply.trim();
    final found = !answer.toLowerCase().contains(
          "couldn't find that information",
        );
    return DocumentQaTurn(
      question: trimmed,
      answer: answer,
      foundInDocument: found,
    );
  }

  /// Sends [prompt] to Gemini alongside whichever of [doc]'s image part or
  /// extracted text applies, translating [GeminiException] into
  /// [DocumentIntelligenceException].
  static Future<String> _ask(PreparedDocument doc, String prompt) async {
    final fullPrompt = doc.extractedText != null
        ? '${doc.extractedText}\n\n$prompt'
        : prompt;
    final attachments = doc.imagePart != null ? [doc.imagePart!] : const <GeminiInlinePart>[];

    try {
      final reply = await GeminiService.sendMessage(
        fullPrompt,
        attachments: attachments,
      );
      return reply.trim();
    } on GeminiException catch (e) {
      throw DocumentIntelligenceException(e.message);
    }
  }

  static final String _analysisPrompt = '''
Look at the attached document (an image of a document, or the extracted document text above) and analyze it thoroughly.

Extract ONLY information that is actually present in the document — never invent, assume, or guess content that isn't there.

Reply with STRICT JSON only — no markdown code fences, no commentary before or after — matching exactly this shape:
{
  "documentType": string or null,
  "summary": string,
  "keyPoints": [string],
  "headings": [string],
  "dates": [string],
  "names": [string],
  "numbers": [string],
  "keyFacts": [string],
  "tables": [
    { "caption": string or null, "headers": [string], "rows": [[string]] }
  ]
}

Rules:
- "documentType": a short label if detectable (e.g. "Invoice", "Resume", "Letter", "Report"), otherwise null.
- "summary": a concise, clearly model-generated overview (2-5 sentences) of what the document is about — this is the one field allowed to be a synthesized description rather than verbatim content.
- "keyPoints", "headings", "dates", "names", "numbers", "keyFacts": each must be actual content found in the document (verbatim or a faithful near-verbatim rendering), not inferred or invented. Use an empty array if none are found.
- "tables": detect every table present. Reconstruct each one's rows and columns as accurately as possible, preserving row/column relationships. If a specific cell's content is illegible or ambiguous, use exactly "[unclear]" for that cell instead of guessing. If there are no tables, use an empty array.
- If the document has no discernible readable content at all, reply with exactly this JSON and nothing else: {"empty": true}
- Never wrap the JSON in markdown fences or add any text outside the JSON object.''';

  static const String _qaInstructions = '''
Answer the question below using ONLY the information present in the attached document (the image above, or the extracted document text above). Do not use outside knowledge and do not guess.

If the document does not contain the answer, reply with exactly this sentence and nothing else: "$_notFoundSentinel"

Otherwise, answer directly and concisely, grounded in the document's content.''';

  /// Parses Gemini's JSON reply into a [DocumentIntelligenceResult].
  ///
  /// Defensive by design: strips stray markdown fences some models add
  /// despite instructions, tolerates missing/wrong-typed fields, and — if
  /// the reply can't be parsed as JSON at all — falls back to returning the
  /// raw reply as [DocumentIntelligenceResult.rawFallbackText] rather than
  /// losing the analysis entirely.
  static DocumentIntelligenceResult _parseAnalysis(String reply) {
    final cleaned = _stripJsonFences(reply);

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      json = null;
    }

    if (json == null) {
      if (reply.trim().isEmpty) {
        throw DocumentIntelligenceException(
          'No readable content was found in this document.',
        );
      }
      // Couldn't parse structured JSON — still surface Gemini's raw answer
      // rather than treating this as a hard failure.
      return DocumentIntelligenceResult(
        summary: reply.trim(),
        rawFallbackText: reply.trim(),
      );
    }

    if (json['empty'] == true) {
      throw DocumentIntelligenceException(
        'No readable content was found in this document.',
      );
    }

    final summary = _asStringOrNull(json['summary'])?.trim();
    if (summary == null || summary.isEmpty) {
      throw DocumentIntelligenceException(
        'No readable content was found in this document.',
      );
    }

    final documentType = _asStringOrNull(json['documentType'])?.trim();

    return DocumentIntelligenceResult(
      documentType: (documentType?.isNotEmpty ?? false) ? documentType : null,
      summary: summary,
      keyPoints: _stringList(json['keyPoints']),
      headings: _stringList(json['headings']),
      dates: _stringList(json['dates']),
      names: _stringList(json['names']),
      numbers: _stringList(json['numbers']),
      keyFacts: _stringList(json['keyFacts']),
      tables: _tableList(json['tables']),
    );
  }

  static String _stripJsonFences(String text) {
    var t = text.trim();
    if (t.startsWith('```')) {
      final firstNewline = t.indexOf('\n');
      if (firstNewline != -1) t = t.substring(firstNewline + 1);
      if (t.endsWith('```')) t = t.substring(0, t.length - 3);
    }
    return t.trim();
  }

  /// Safely reads a value expected to be a `String` out of decoded JSON.
  /// Returns `null` for `null`/missing values *and* for any unexpected
  /// type (number, bool, list, map) instead of throwing — a malformed or
  /// unexpected Gemini reply should never crash analysis.
  static String? _asStringOrNull(dynamic value) {
    if (value is String) return value;
    return null;
  }

  static List<String> _stringList(dynamic value) {
    if (value is! List) return const [];
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }

  static List<DocumentTable> _tableList(dynamic value) {
    if (value is! List) return const [];
    final tables = <DocumentTable>[];
    for (final entry in value) {
      if (entry is! Map) continue;
      final caption = _asStringOrNull(entry['caption'])?.trim();
      final headers = _stringList(entry['headers']);
      final rawRows = entry['rows'];
      final rows = <List<String>>[];
      if (rawRows is List) {
        for (final row in rawRows) {
          if (row is! List) continue;
          rows.add(
            row.map((c) => c?.toString().trim().isNotEmpty == true
                ? c.toString().trim()
                : '[unclear]').toList(growable: false),
          );
        }
      }
      if (headers.isEmpty && rows.isEmpty) continue;
      tables.add(DocumentTable(
        caption: (caption?.isNotEmpty ?? false) ? caption : null,
        headers: headers,
        rows: rows,
      ));
    }
    return tables;
  }
}
