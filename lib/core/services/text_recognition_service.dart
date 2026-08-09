import '../../widgets/attachment_sheet.dart' show AttachmentType;
import 'attachment_processor_service.dart';
import 'attachment_service.dart';
import 'gemini_service.dart';

/// Step 38 — OCR + Handwriting Recognition.
///
/// Which recognition path a picked image should go through. Both paths
/// share the exact same attachment-compression pipeline
/// ([AttachmentProcessorService]) and Gemini vision call ([GeminiService])
/// already used for image chat attachments — nothing new is added to the
/// image pipeline itself, only a different prompt is sent for each mode.
enum TextScanMode { ocr, handwriting }

/// How confident Gemini said it was about a handwriting transcription.
/// Always [unknown] for [TextScanMode.ocr] results — only the handwriting
/// prompt asks for a confidence rating, since plain OCR of printed text
/// isn't expected to be ambiguous the way handwriting can be.
enum ScanConfidence { high, medium, low, unknown }

/// Thrown when an image can't be prepared, or Gemini can't read it, or no
/// text could be found. The message is always safe to show to the user
/// as-is (mirrors the pattern used by [AttachmentException]/
/// [GeminiException]).
class TextRecognitionException implements Exception {
  final String message;
  TextRecognitionException(this.message);

  @override
  String toString() => message;
}

/// The outcome of a successful scan.
class TextRecognitionResult {
  final String text;
  final TextScanMode mode;

  /// Only meaningful when [mode] is [TextScanMode.handwriting].
  final ScanConfidence confidence;

  const TextRecognitionResult({
    required this.text,
    required this.mode,
    this.confidence = ScanConfidence.unknown,
  });
}

/// Extracts printed text (OCR) or transcribes handwriting from a picked
/// image.
///
/// This deliberately does NOT introduce a second image pipeline: the image
/// is prepared via the same [AttachmentProcessorService] used for chat
/// image attachments (downscale/compress/validate), and the recognition
/// itself is just another [GeminiService.sendMessage] call — the existing
/// image-understanding service Pak AI already has. Only the prompt differs
/// between OCR and handwriting.
class TextRecognitionService {
  TextRecognitionService._();

  static const String _noTextSentinel = 'NO_TEXT_FOUND';

  /// Runs recognition on [image] (as picked via [source] — camera or
  /// gallery) according to [mode]. Throws [TextRecognitionException] on any
  /// failure, with a message ready to show directly to the user.
  static Future<TextRecognitionResult> recognize({
    required AttachmentResult image,
    required TextScanMode mode,
    required AttachmentType source,
  }) async {
    final part = await _prepareImage(image, source);
    return recognizeFromPart(part: part, mode: mode);
  }

  /// Step 40 — Chat-Native Intelligence UX Refactor: same recognition as
  /// [recognize], but for an image [part] that's already been processed
  /// elsewhere (chat-native routing already runs every attachment through
  /// [AttachmentProcessorService.process] once to build the sent message's
  /// attachment preview) — skips reading/compressing the file a second
  /// time. [recognize] above is unchanged and still used by the standalone
  /// Scan Text / Handwriting flow, which has no such already-processed
  /// part to reuse.
  static Future<TextRecognitionResult> recognizeFromPart({
    required GeminiInlinePart part,
    required TextScanMode mode,
  }) async {
    final reply = await _askGemini(part, mode);
    return mode == TextScanMode.ocr
        ? _parseOcrReply(reply)
        : _parseHandwritingReply(reply);
  }

  /// Reuses [AttachmentProcessorService.process] — the same
  /// downscale/re-encode/validate path every chat image attachment goes
  /// through — so large/invalid images are handled exactly as they already
  /// are elsewhere in the app, without duplicating that logic here.
  static Future<GeminiInlinePart> _prepareImage(
    AttachmentResult image,
    AttachmentType source,
  ) async {
    try {
      final processed = await AttachmentProcessorService.process(image, source);
      final part = processed.part;
      if (part == null) {
        throw TextRecognitionException(
          'Could not process this image. Please try a different one.',
        );
      }
      return part;
    } on AttachmentException catch (e) {
      throw TextRecognitionException(e.message);
    }
  }

  static Future<String> _askGemini(
    GeminiInlinePart image,
    TextScanMode mode,
  ) async {
    final prompt = mode == TextScanMode.ocr ? _ocrPrompt : _handwritingPrompt;
    try {
      final reply = await GeminiService.sendMessage(
        prompt,
        attachments: [image],
      );
      return reply.trim();
    } on GeminiException catch (e) {
      throw TextRecognitionException(e.message);
    }
  }

  static const String _ocrPrompt = '''
Look at the attached image and extract ONLY the readable printed text from it (for example: text from a document, screenshot, sign, label, or book page).

Rules:
- Preserve the original paragraph breaks and line breaks as closely as practical.
- Transcribe the text exactly as written — do not translate, summarize, or correct it.
- Do not add any commentary, headers, explanations, or descriptions of the image.
- Reply with the extracted text and nothing else.
- If the image contains no readable printed text at all, reply with exactly: $_noTextSentinel''';

  static const String _handwritingPrompt = '''
Look at the attached image, which contains handwritten text (notes, a question, or similar). Carefully transcribe the handwriting into clean, editable plain text.

Rules:
- Preserve line breaks where they meaningfully separate ideas.
- Never invent or guess a word you cannot make out with reasonable confidence — if a word or phrase is genuinely illegible, write [illegible] in its place instead of fabricating something plausible-sounding.
- Do not add commentary, headers, or descriptions — only the required format below.
- Reply in exactly this format and nothing else:

CONFIDENCE: HIGH or MEDIUM or LOW
TEXT:
<the transcription here>

- If there is no discernible handwriting anywhere in the image, reply with exactly: $_noTextSentinel''';

  static TextRecognitionResult _parseOcrReply(String reply) {
    if (_looksEmpty(reply)) {
      throw TextRecognitionException(
        'No readable text was found in this image.',
      );
    }
    return TextRecognitionResult(text: reply, mode: TextScanMode.ocr);
  }

  static TextRecognitionResult _parseHandwritingReply(String reply) {
    if (_looksEmpty(reply)) {
      throw TextRecognitionException(
        'No readable handwriting was found in this image.',
      );
    }

    // Expected shape: "CONFIDENCE: <level>\nTEXT:\n<text>" — parsed
    // defensively. If Gemini doesn't follow the format exactly, the whole
    // reply is still shown to the user rather than being lost.
    final confidenceMatch =
        RegExp(r'CONFIDENCE:\s*(HIGH|MEDIUM|LOW)', caseSensitive: false)
            .firstMatch(reply);
    final textMatch =
        RegExp(r'TEXT:\s*([\s\S]*)', caseSensitive: false).firstMatch(reply);

    final confidence = _confidenceFrom(confidenceMatch?.group(1));
    final text = (textMatch?.group(1) ?? reply).trim();

    if (text.isEmpty || text.toUpperCase() == _noTextSentinel) {
      throw TextRecognitionException(
        'No readable handwriting was found in this image.',
      );
    }

    return TextRecognitionResult(
      text: text,
      mode: TextScanMode.handwriting,
      confidence: confidence,
    );
  }

  static bool _looksEmpty(String reply) {
    final normalized = reply.trim();
    return normalized.isEmpty || normalized.toUpperCase() == _noTextSentinel;
  }

  static ScanConfidence _confidenceFrom(String? raw) {
    switch (raw?.toUpperCase()) {
      case 'HIGH':
        return ScanConfidence.high;
      case 'MEDIUM':
        return ScanConfidence.medium;
      case 'LOW':
        return ScanConfidence.low;
      default:
        return ScanConfidence.unknown;
    }
  }
}
