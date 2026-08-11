import '../../models/chat_message.dart';

/// Step 50 — Local PDF Generator.
///
/// What kind of content a recognized PDF request refers to. Decided purely
/// from which keyword the user's own sentence used — see
/// [PdfIntentService.detect].
enum PdfExportTarget {
  /// "is conversation ko PDF bana do" / "PDF banao is chat ki" — the whole
  /// visible chat transcript.
  conversation,

  /// "is Q/A ko PDF bana do" / "sawal jawab ki pdf" — the most recent
  /// question+answer pair.
  qa,

  /// "is text ko PDF bana do" / "ye text PDF mein" — text the user
  /// themselves typed/pasted (as opposed to an AI answer).
  text,

  /// "ye notes PDF mein bana do" — same handling as [text], kept as a
  /// separate value only so detection/labels can be tuned independently
  /// later if needed.
  notes,

  /// "is answer ko PDF bana do" / "make this a PDF" with no other keyword
  /// — the most recent AI answer. This is also the default fallback for
  /// phrasing that clearly asks for a PDF but names nothing specific.
  answer,
}

/// Local, zero-network, zero-Gemini-call detector for natural-language PDF
/// export requests (English, Roman Urdu, and Urdu script — see the Step 50
/// brief's phrase lists). Deliberately conservative: it only fires when the
/// message combines the word "PDF" with an actual action/verb, so a plain
/// question like "what is a PDF file?" or "photosynthesis kya hai?" is
/// never mistaken for an export request and normal chat is unaffected.
class PdfIntentService {
  PdfIntentService._();

  static final RegExp _pdfWord = RegExp(
    r'pdf|پی\s*ڈی\s*ایف',
    caseSensitive: false,
  );

  // English action verbs from the Step 50 phrase list.
  static final RegExp _englishAction = RegExp(
    r'\b(make|create|convert|save|export|turn|generate|produce)\b',
    caseSensitive: false,
  );

  // Roman Urdu action verbs/phrases (spelling varies a lot in the wild —
  // this is intentionally loose, matching the stem rather than one exact
  // spelling): bana/banao/bnado/bana do/bana dein, tabdeel/convert kar do.
  static final RegExp _romanUrduAction = RegExp(
    r'bana|bnad|bnao|bnaa|tabdeel|tabdil',
    caseSensitive: false,
  );

  // Urdu-script action verbs: بنا (bana-) / تبدیل (tabdeel/convert).
  static final RegExp _urduAction = RegExp('بنا|تبدیل');

  // Natural Roman-Urdu readiness phrases: PDF ready/taiyar karo.
  static final RegExp _readinessAction = RegExp(
    r'\b(ready|taiyar|tayyar)\b.*\bkar(?:o|do|dein|den)\b',
    caseSensitive: false,
  );

  // Remove invisible Unicode formatting marks that can be inserted by
  // mobile keyboards and break Roman-Urdu word matching.
  static String _normalizeForDetection(String value) {
    return value.replaceAll(
      RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]'),
      '',
    );
  }

  static final RegExp _conversationWord = RegExp(
    r'conversation|chat|guftugu|guftago|گفتگو|چیٹ',
    caseSensitive: false,
  );

  static final RegExp _qaWord = RegExp(
    r'q\s*/?\s*a\b|q&a|question.*answer|sawal.*jawab|sawal\s*jawab|'
    r'سوال\s*جواب',
    caseSensitive: false,
  );

  static final RegExp _textOrNotesWord = RegExp(
    r'\bnotes?\b|\btext\b|matn|متن|نوٹس',
    caseSensitive: false,
  );

  static final RegExp _answerWord = RegExp(
    r'\banswer\b|jawab\b|جواب',
    caseSensitive: false,
  );

  /// Returns the export target if [text] reads as a PDF export request,
  /// or `null` if it's an ordinary message that should go through the
  /// normal chat/Gemini flow untouched.
  static PdfExportTarget? detect(String text) {
    final trimmed = _normalizeForDetection(text).trim();
    if (trimmed.isEmpty) return null;
    if (!_pdfWord.hasMatch(trimmed)) return null;

    final hasAction = _englishAction.hasMatch(trimmed) ||
        _romanUrduAction.hasMatch(trimmed) ||
        _urduAction.hasMatch(trimmed) ||
        _readinessAction.hasMatch(trimmed);
    if (!hasAction) return null;

    if (_conversationWord.hasMatch(trimmed)) return PdfExportTarget.conversation;
    if (_qaWord.hasMatch(trimmed)) return PdfExportTarget.qa;
    if (RegExp(r'\bnotes?\b|نوٹس', caseSensitive: false).hasMatch(trimmed)) {
      return PdfExportTarget.notes;
    }
    if (_textOrNotesWord.hasMatch(trimmed)) return PdfExportTarget.text;
    if (_answerWord.hasMatch(trimmed)) return PdfExportTarget.answer;


    // Bare "make this a PDF" / "PDF bana do" with nothing more specific —
    // the common case, and the most reasonable default (Step 50 brief,
    // test case 5).
    return PdfExportTarget.answer;
  }
}

/// The content resolved for a PDF export request, ready to hand to
/// `PdfExportService.generate`.
class ResolvedPdfContent {
  final String title;
  final String? question;
  final String body;

  const ResolvedPdfContent({
    required this.title,
    this.question,
    required this.body,
  });
}

/// Turns a [PdfExportTarget] into actual text pulled from the existing
/// conversation — never from unrelated older conversations, and never
/// including the export command message itself. Purely local string
/// selection; no network, no AI call.
class PdfContentResolver {
  PdfContentResolver._();

  static bool _isUsable(ChatMessage m) =>
      !m.isError && m.pdfResult == null && m.text.trim().isNotEmpty;

  /// [priorMessages] must be the conversation *excluding* the just-typed
  /// export command. Returns `null` when nothing sensible can be found —
  /// the caller should then ask the user what to export instead of
  /// guessing (Step 50 brief, Step 3/8).
  static ResolvedPdfContent? resolve({
    required List<ChatMessage> priorMessages,
    required PdfExportTarget target,
  }) {
    switch (target) {
      case PdfExportTarget.conversation:
        return _resolveConversation(priorMessages);
      case PdfExportTarget.qa:
        return _resolveQa(priorMessages);
      case PdfExportTarget.text:
      case PdfExportTarget.notes:
        return _resolveUserText(priorMessages) ?? _resolveAnswer(priorMessages);
      case PdfExportTarget.answer:
        return _resolveAnswer(priorMessages);
    }
  }

  static ResolvedPdfContent? _resolveConversation(List<ChatMessage> messages) {
    final usable = messages.where(_isUsable).toList();
    if (usable.isEmpty) return null;
    final buffer = StringBuffer();
    for (final m in usable) {
      buffer.writeln(m.isUser ? 'You:' : 'Pak AI:');
      buffer.writeln(m.text.trim());
      buffer.writeln();
    }
    return ResolvedPdfContent(title: 'Conversation', body: buffer.toString().trim());
  }

  static ResolvedPdfContent? _resolveQa(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (!_isUsable(m) || m.isUser) continue;
      // Found the most recent AI answer — look backwards for the user
      // message that prompted it.
      String? question;
      for (var j = i - 1; j >= 0; j--) {
        final prev = messages[j];
        if (_isUsable(prev) && prev.isUser) {
          question = prev.text.trim();
          break;
        }
      }
      return ResolvedPdfContent(title: 'Q & A', question: question, body: m.text.trim());
    }
    return null;
  }

  static ResolvedPdfContent? _resolveAnswer(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (_isUsable(m) && !m.isUser) {
        return ResolvedPdfContent(title: 'Answer', body: m.text.trim());
      }
    }
    // No AI reply yet at all (e.g. the user only ever pasted text) — the
    // most recent user message is the next best thing rather than giving
    // up outright.
    return _resolveUserText(messages);
  }

  static ResolvedPdfContent? _resolveUserText(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (_isUsable(m) && m.isUser && PdfIntentService.detect(m.text) == null) {
        return ResolvedPdfContent(title: 'Notes', body: m.text.trim());
      }
    }
    return null;
  }
}
