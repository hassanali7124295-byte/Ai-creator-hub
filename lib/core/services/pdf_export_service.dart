import 'dart:io';
import 'dart:ui' show Rect, Offset;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// STEP 56 — AI Q&A → PDF Export Feature.
/// STEP 59 — Fixed the generation failure (swallowed exception).
/// STEP 60 — Fixed corrupted Q&A content in the generated PDF.
///
/// Generates a Pak AI–branded PDF entirely on-device from already-available
/// chat text, using the `syncfusion_flutter_pdf` package the project already
/// depends on for the existing PDF *reading*/extraction feature (Step 22A,
/// see `attachment_processor_service.dart`). No new package was added for
/// this — Syncfusion's PDF library can both read and *write* PDFs, so the
/// existing dependency is reused as-is. No network calls, no paid API.
///
/// STEP 60 root cause (Problem 1 — corrupted content): Step 59 added
/// Unicode-text support by reading a font file straight off the device's
/// `/system/fonts/` and handing its raw bytes to `PdfTrueTypeFont`. On real
/// devices, several of those system font files are not a plain single-font
/// `.ttf` — they're either a **TrueType Collection** (`.ttc`, multiple font
/// faces packed behind one shared glyph table, identified by a `ttcf`
/// magic number instead of the plain sfnt version tag) or a **variable
/// font** (a single outline that's algorithmically reshaped for different
/// weights via an `fvar`/`gvar` table, rather than each weight having its
/// own fixed outline). Handing either of those straight to
/// `PdfTrueTypeFont` — which expects one fixed, static, single-face sfnt
/// file — makes it parse the table directory wrong: some low, universal
/// glyph indices (digits, basic punctuation) happen to still land on
/// roughly the right glyph, while the rest of the character-to-glyph
/// mapping is garbage. That is exactly the reported symptom — numbers and
/// punctuation visible, the actual question/answer letters missing. See
/// `_looksLikeUsableSfnt` below for the fix.

/// Which slice of the conversation a PDF export request covers, decided
/// purely from the user's own phrasing (see `_detectPdfExportIntent` in
/// `chat_screen.dart`). Only affects the title line and how many Q&A pairs
/// are gathered before calling [PdfExportService.generate] — the PDF layout
/// itself is identical either way.
enum PdfExportScope { currentQa, allQa, fullConversation }

/// A single Question/Answer pair to render as one block in the PDF.
class PdfQaPair {
  final String question;
  final String answer;

  const PdfQaPair({required this.question, required this.answer});
}

/// Thrown for any failure during PDF export — always carries an already
/// user-friendly message (never a raw exception string), so call sites can
/// show `e.message` directly in a chat bubble. The *real* exception and
/// stack trace are always sent to debug output first (see `_log` below) —
/// this class only controls what the user sees.
class PdfExportException implements Exception {
  final String message;
  const PdfExportException(this.message);

  @override
  String toString() => message;
}

/// The result of a successful export — enough for the chat UI to render a
/// "📄 PDF Ready" card and for `Share.shareXFiles`/a real Downloads save to
/// use the file.
class PdfExportResult {
  final String filePath;
  final String fileName;
  final int pairCount;
  final PdfExportScope scope;

  const PdfExportResult({
    required this.filePath,
    required this.fileName,
    required this.pairCount,
    required this.scope,
  });

  Map<String, dynamic> toJson() => {
        'filePath': filePath,
        'fileName': fileName,
        'pairCount': pairCount,
        'scope': scope.name,
      };

  factory PdfExportResult.fromJson(Map<String, dynamic> json) =>
      PdfExportResult(
        filePath: json['filePath'] as String,
        fileName: json['fileName'] as String,
        pairCount: json['pairCount'] as int? ?? 0,
        scope: PdfExportScope.values.firstWhere(
          (s) => s.name == json['scope'],
          orElse: () => PdfExportScope.currentQa,
        ),
      );
}

class PdfExportService {
  PdfExportService._();

  // Matches ChatPalette.emeraldLight (0xFF10B981) — this file intentionally
  // doesn't import the widget-layer ChatPalette (this is a plain Dart
  // service, no Flutter/material dependency beyond `debugPrint`), so the
  // RGB triplet is duplicated here as a plain constant instead.
  static const int _accentR = 16;
  static const int _accentG = 185;
  static const int _accentB = 129;

  static void _log(String tag, [Object? detail]) {
    // Every stage of the export pipeline logs unconditionally in debug
    // builds via `debugPrint` (a no-op in release builds), so a real
    // failure is always visible in Logcat instead of only showing the
    // user-facing generic message.
    debugPrint(detail == null ? '[PdfExport] $tag' : '[PdfExport] $tag: $detail');
  }

  /// A short, safe-for-logs preview of [text]: length-capped and with
  /// newlines collapsed, so a long AI answer doesn't flood Logcat but its
  /// actual content is still visible for comparison against what's shown
  /// in the chat bubble.
  static String _preview(String text) {
    final flat = text.replaceAll('\n', ' \u23CE ');
    return flat.length <= 160 ? flat : '${flat.substring(0, 160)}…';
  }

  // ---------------------------------------------------------------------
  // STEP 60 — Unicode font support, hardened.
  //
  // `PdfStandardFont` can only encode WinAnsi/Latin-1 text, so Urdu-script
  // answers need a real Unicode (TrueType) font. Step 59 read one straight
  // from the device's `/system/fonts/`, which is what corrupted the
  // output (see the class doc comment above for the exact mechanism).
  // Step 60 keeps the same "no new asset, no network, fully local/free"
  // approach — it just validates a candidate font file before trusting it:
  // reject anything that isn't a plain, static, single-face sfnt file, and
  // reject a font whose measurements come back nonsensical after loading.
  // Nothing here removes Urdu support — every candidate is still tried,
  // and only a file that actually fails validation is skipped in favor of
  // the next one.
  // ---------------------------------------------------------------------
  static const List<String> _systemUnicodeFontPaths = [
    '/system/fonts/NotoNaskhArabic-Regular.ttf',
    '/system/fonts/NotoNaskhArabicUI-Regular.ttf',
    '/system/fonts/NotoSansArabic-Regular.ttf',
    '/system/fonts/NotoSansArabicUI-Regular.ttf',
    '/system/fonts/NotoNastaliqUrdu-Regular.ttf',
    '/system/fonts/NotoNastaliqUrdu.ttf',
    '/system/fonts/NotoSansUrdu-Regular.ttf',
    '/system/fonts/NotoSansSymbols-Regular-Subsetted.ttf',
    '/system/fonts/NotoSansSymbols2-Regular.ttf',
    '/system/fonts/DroidSansFallback.ttf',
    '/system/fonts/DroidNaskh-Regular.ttf',
  ];

  static PdfFont? _cachedUnicodeFont;
  static bool _unicodeFontLookupDone = false;

  /// `ttcf` — the magic number at the start of a **TrueType Collection**
  /// file (several font faces sharing one glyph table). `PdfTrueTypeFont`
  /// expects a single-face sfnt, not a collection, so any file starting
  /// with this must be rejected rather than passed straight through.
  static const List<int> _ttcMagic = [0x74, 0x74, 0x63, 0x66];

  /// The four sfnt "version" tags a plain, single-face TrueType/OpenType
  /// file is allowed to start with.
  static bool _hasPlainSfntVersion(List<int> bytes) {
    if (bytes.length < 4) return false;
    // 0x00010000 — the standard TrueType version tag.
    if (bytes[0] == 0x00 && bytes[1] == 0x01 && bytes[2] == 0x00 && bytes[3] == 0x00) {
      return true;
    }
    // 'true' / 'OTTO' — the Apple-TrueType and OpenType/CFF version tags.
    final tag = String.fromCharCodes(bytes.sublist(0, 4));
    return tag == 'true' || tag == 'OTTO';
  }

  /// True if [bytes] starts with the `ttcf` collection magic number —
  /// i.e. this is a multi-face collection file, not a single font.
  static bool _isTrueTypeCollection(List<int> bytes) {
    if (bytes.length < 4) return false;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _ttcMagic[i]) return false;
    }
    return true;
  }

  /// Scans the sfnt table directory for an `fvar` table — the marker of a
  /// **variable font** (one outline reshaped per-weight at render time,
  /// rather than each weight being its own fixed outline). Older/embedded
  /// TrueType parsers — including Syncfusion's — are known to mis-resolve
  /// glyph outlines for these, which is the second class of file that
  /// produces exactly the "scattered digits/punctuation, missing letters"
  /// corruption this step fixes.
  static bool _hasVariableFontTable(List<int> bytes) {
    try {
      if (bytes.length < 12) return false;
      final numTables = (bytes[4] << 8) | bytes[5];
      const recordSize = 16;
      const directoryStart = 12;
      for (var i = 0; i < numTables; i++) {
        final recordStart = directoryStart + i * recordSize;
        if (recordStart + 4 > bytes.length) break;
        final tag = String.fromCharCodes(bytes.sublist(recordStart, recordStart + 4));
        if (tag == 'fvar') return true;
      }
      return false;
    } catch (_) {
      // Malformed enough that we can't even read the table directory —
      // treat as unusable rather than risk it.
      return true;
    }
  }

  /// True if [bytes] is safe to hand to `PdfTrueTypeFont`: a plain,
  /// static, single-face sfnt file. Rejects TrueType Collections and
  /// variable fonts (see the two checks above) — those are what actually
  /// corrupted Step 59's output on real devices.
  static bool _looksLikeUsableSfnt(List<int> bytes) {
    if (_isTrueTypeCollection(bytes)) return false;
    if (!_hasPlainSfntVersion(bytes)) return false;
    if (_hasVariableFontTable(bytes)) return false;
    return true;
  }

  /// Builds a `PdfTrueTypeFont` from [bytes] and sanity-checks it by
  /// measuring a known short string — if the measured width comes back
  /// zero/negative or wildly disproportionate, the font loaded "silently
  /// wrong" (rather than throwing) and must not be trusted. Never throws;
  /// returns `null` on any failure so the caller can try the next
  /// candidate instead of producing corrupted output.
  static PdfFont? _tryBuildAndVerifyFont(List<int> bytes, String path) {
    try {
      final font = PdfTrueTypeFont(bytes, 12);
      const probe = 'Aa0 .,';
      final size = font.measureString(probe);
      if (size.width <= 0 || size.width > 200 || size.height <= 0) {
        _log('PDF_EXPORT_UNICODE_FONT_MEASURE_SUSPICIOUS', '$path -> $size');
        return null;
      }
      _log('PDF_EXPORT_UNICODE_FONT_VERIFIED', path);
      return font;
    } catch (e) {
      _log('PDF_EXPORT_UNICODE_FONT_LOAD_FAILED', '$path -> $e');
      return null;
    }
  }

  /// Finds and validates a Unicode-capable font from the device's own
  /// system fonts, trying every candidate path until one both parses as a
  /// plain sfnt file (see `_looksLikeUsableSfnt`) and measures sane text.
  /// Cached for the lifetime of the isolate.
  static PdfFont? _findSystemUnicodeFont() {
    if (_unicodeFontLookupDone) return _cachedUnicodeFont;
    _unicodeFontLookupDone = true;
    for (final path in _systemUnicodeFontPaths) {
      try {
        final file = File(path);
        if (!file.existsSync()) continue;
        final bytes = file.readAsBytesSync();
        if (!_looksLikeUsableSfnt(bytes)) {
          _log('PDF_EXPORT_UNICODE_FONT_REJECTED', '$path (collection/variable font)');
          continue;
        }
        final font = _tryBuildAndVerifyFont(bytes, path);
        if (font != null) {
          _cachedUnicodeFont = font;
          _log('PDF_EXPORT_UNICODE_FONT_FOUND', path);
          return font;
        }
      } catch (e) {
        _log('PDF_EXPORT_UNICODE_FONT_PATH_FAILED', '$path -> $e');
      }
    }
    _log('PDF_EXPORT_UNICODE_FONT_UNAVAILABLE',
        'no usable on-device Unicode font found — Latin text is unaffected; '
        'non-Latin characters will fall back to the standard font '
        '(may show as missing glyphs, never corrupted/scattered ones).');
    return null;
  }

  /// True if [text] contains any character outside the WinAnsi/Latin-1
  /// range that `PdfStandardFont` can encode — i.e. Urdu/Arabic script or
  /// other non-Latin text that needs a Unicode (TrueType) font instead.
  static bool _needsUnicodeFont(String text) {
    for (final rune in text.runes) {
      if (rune > 0xFF) return true;
    }
    return false;
  }

  /// Picks the right font for [text]: the validated on-device Unicode font
  /// when [text] contains non-Latin characters and one passed validation,
  /// otherwise the existing standard Helvetica font. Never throws.
  static PdfFont _fontFor(String text, PdfFont standardFont) {
    if (!_needsUnicodeFont(text)) return standardFont;
    return _findSystemUnicodeFont() ?? standardFont;
  }

  /// Draws [text] with [font], and — only if that specific draw throws —
  /// retries once with [fallbackFont]. This is a last-resort safety net so
  /// one bad block can't blank out the rest of the document; it never
  /// silently drops the text itself, only ever swaps the font, and always
  /// logs when it happens.
  static PdfLayoutResult _drawTextSafely({
    required String label,
    required String text,
    required PdfFont font,
    required PdfFont fallbackFont,
    required PdfPage page,
    required Rect bounds,
    required PdfLayoutFormat format,
    PdfBrush? brush,
  }) {
    try {
      return PdfTextElement(text: text, font: font, brush: brush).draw(
        page: page,
        bounds: bounds,
        format: format,
      )!;
    } catch (e, stackTrace) {
      _log('PDF_EXPORT_TEXT_DRAW_FAILED', '$label -> $e');
      _log('PDF_EXPORT_TEXT_DRAW_STACKTRACE', stackTrace);
      return PdfTextElement(text: text, font: fallbackFont, brush: brush).draw(
        page: page,
        bounds: bounds,
        format: format,
      )!;
    }
  }

  /// Builds a real, selectable-text PDF from [pairs] and saves it inside the
  /// app's own documents directory (`<app docs>/pak_ai_exports/`) — no
  /// public-Downloads/MediaStore write happens here; that's a separate,
  /// explicit user action (see `PdfExportResultCard`'s "Download PDF").
  ///
  /// Throws [PdfExportException] with an already user-friendly message on
  /// any failure — empty input, a generation error, or a file-system error.
  /// The real exception + stack trace are always logged first.
  static Future<PdfExportResult> generate({
    required List<PdfQaPair> pairs,
    required PdfExportScope scope,
  }) async {
    _log('PDF_EXPORT_START', 'scope=$scope inputPairs=${pairs.length}');

    final cleanPairs = pairs
        .where((p) => p.question.trim().isNotEmpty && p.answer.trim().isNotEmpty)
        .toList(growable: false);
    _log('PDF_EXPORT_QA_COUNT', cleanPairs.length);

    if (cleanPairs.isEmpty) {
      throw const PdfExportException(
        "There's no conversation yet to turn into a PDF — ask me something "
        'first, then try again.',
      );
    }

    // Step 60 — Part 1: log exactly what's about to be written, so a
    // mismatch between "what's in the chat" and "what reaches the PDF
    // service" is visible before it ever gets near the rendering code.
    for (var i = 0; i < cleanPairs.length; i++) {
      final p = cleanPairs[i];
      _log('PDF_EXPORT_Q_INDEX', i);
      _log('PDF_EXPORT_Q_TEXT', _preview(p.question));
      _log('PDF_EXPORT_Q_LENGTH', p.question.length);
      _log('PDF_EXPORT_A_TEXT', _preview(p.answer));
      _log('PDF_EXPORT_A_LENGTH', p.answer.length);
    }

    PdfDocument? document;
    try {
      document = PdfDocument();
      _log('PDF_EXPORT_DOCUMENT_CREATED');
      document.pageSettings.size = PdfPageSize.a4;
      document.pageSettings.margins.all = 40;

      final accent = PdfColor(_accentR, _accentG, _accentB);
      final muted = PdfColor(120, 120, 120);
      final divider = PdfColor(225, 225, 225);

      final titleFont =
          PdfStandardFont(PdfFontFamily.helvetica, 22, style: PdfFontStyle.bold);
      final subtitleFont =
          PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.italic);
      final labelFontStd =
          PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.bold);
      final bodyFontStd = PdfStandardFont(PdfFontFamily.helvetica, 11.5);

      PdfPage page = document.pages.add();
      _log('PDF_EXPORT_PAGE_CREATED');
      final pageWidth = page.getClientSize().width;
      final pageHeight = page.getClientSize().height;
      final format = PdfLayoutFormat(layoutType: PdfLayoutType.paginate);

      PdfLayoutResult result = PdfTextElement(
        text: 'Pak AI',
        font: titleFont,
        brush: PdfSolidBrush(accent),
      ).draw(
        page: page,
        bounds: Rect.fromLTWH(0, 0, pageWidth, pageHeight),
      )!;

      final subtitle = switch (scope) {
        PdfExportScope.fullConversation => 'Complete Conversation Export',
        PdfExportScope.allQa => 'AI Conversation / Q&A',
        PdfExportScope.currentQa => 'AI Conversation / Q&A',
      };
      result = PdfTextElement(
        text: subtitle,
        font: subtitleFont,
        brush: PdfSolidBrush(muted),
      ).draw(
        page: result.page,
        bounds: Rect.fromLTWH(0, result.bounds.bottom + 2, pageWidth, pageHeight),
      )!;

      PdfPage currentPage = result.page;
      double currentY = result.bounds.bottom + 10;
      currentPage.graphics.drawLine(
        PdfPen(divider, width: 0.75),
        Offset(0, currentY),
        Offset(pageWidth, currentY),
      );
      currentY += 16;

      for (var i = 0; i < cleanPairs.length; i++) {
        final pair = cleanPairs[i];
        final question = pair.question.trim();
        final answer = pair.answer.trim();

        // Step 59/60: pick a validated Unicode-safe font per block only
        // when the text actually needs one (Urdu/Arabic script etc.).
        final qLabelFont = _fontFor(question, labelFontStd);
        final qBodyFont = _fontFor(question, bodyFontStd);
        final aLabelFont = _fontFor(answer, labelFontStd);
        final aBodyFont = _fontFor(answer, bodyFontStd);

        final qLabel = _drawTextSafely(
          label: 'Q${i + 1} label',
          text: 'Question ${i + 1}',
          font: qLabelFont,
          fallbackFont: labelFontStd,
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
          brush: PdfSolidBrush(accent),
        );
        currentPage = qLabel.page;
        currentY = qLabel.bounds.bottom + 3;

        final qBody = _drawTextSafely(
          label: 'Q${i + 1} body',
          text: question,
          font: qBodyFont,
          fallbackFont: bodyFontStd,
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        );
        currentPage = qBody.page;
        currentY = qBody.bounds.bottom + 12;

        final aLabel = _drawTextSafely(
          label: 'A${i + 1} label',
          text: 'Answer',
          font: aLabelFont,
          fallbackFont: labelFontStd,
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
          brush: PdfSolidBrush(accent),
        );
        currentPage = aLabel.page;
        currentY = aLabel.bounds.bottom + 3;

        final aBody = _drawTextSafely(
          label: 'A${i + 1} body',
          text: answer,
          font: aBodyFont,
          fallbackFont: bodyFontStd,
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        );
        currentPage = aBody.page;
        currentY = aBody.bounds.bottom + 22;

        if (i != cleanPairs.length - 1) {
          // A fresh page after the last draw leaves currentY near the top —
          // skip the divider in that case so it doesn't sit right under
          // the margin with nothing above it.
          if (currentY < pageHeight - 60) {
            currentPage.graphics.drawLine(
              PdfPen(divider, width: 0.5),
              Offset(0, currentY - 10),
              Offset(pageWidth, currentY - 10),
            );
          }
        }
      }
      _log('PDF_EXPORT_CONTENT_WRITTEN');

      final bytes = await document.save();
      _log('PDF_EXPORT_FILE_SAVED', '${bytes.length} bytes in memory');

      final docsDir = await getApplicationDocumentsDirectory();
      final exportsDir = Directory('${docsDir.path}/pak_ai_exports');
      if (!await exportsDir.exists()) {
        await exportsDir.create(recursive: true);
      }
      final fileName = 'PakAI_QA_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final file = File('${exportsDir.path}/$fileName');
      _log('PDF_EXPORT_FILE_PATH', file.path);
      await file.writeAsBytes(bytes, flush: true);

      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      _log('PDF_EXPORT_FILE_EXISTS', exists);
      _log('PDF_EXPORT_FILE_SIZE', size);

      if (!exists || size <= 0) {
        throw const PdfExportException(
          "Sorry, I couldn't create the PDF. Please try again.",
        );
      }

      return PdfExportResult(
        filePath: file.path,
        fileName: fileName,
        pairCount: cleanPairs.length,
        scope: scope,
      );
    } on PdfExportException {
      rethrow;
    } catch (e, stackTrace) {
      _log('PDF_EXPORT_EXCEPTION', e.toString());
      _log('PDF_EXPORT_STACKTRACE', stackTrace);
      throw const PdfExportException(
        "Sorry, I couldn't create the PDF. Please try again.",
      );
    } finally {
      document?.dispose();
    }
  }
}
