import 'dart:io';
import 'dart:ui' show Rect, Offset;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// STEP 56 — AI Q&A → PDF Export Feature.
/// STEP 59 — Fix the actual PDF generation failure.
///
/// Generates a Pak AI–branded PDF entirely on-device from already-available
/// chat text, using the `syncfusion_flutter_pdf` package the project already
/// depends on for the existing PDF *reading*/extraction feature (Step 22A,
/// see `attachment_processor_service.dart`). No new package was added for
/// this — Syncfusion's PDF library can both read and *write* PDFs, so the
/// existing dependency is reused as-is. No network calls, no paid API.
///
/// STEP 59 root cause: `PdfStandardFont` (Helvetica) only encodes the
/// WinAnsi/Latin-1 character range. Pak AI's replies routinely contain
/// Urdu-script text (and other non-Latin characters), and drawing that text
/// with a standard font throws inside Syncfusion's layout engine. That
/// exception was being swallowed by a bare `catch (_)` and replaced with the
/// generic "Sorry, I couldn't create the PDF" message — so the export
/// *always* looked like a mystery failure once any non-Latin text was
/// involved, and the real cause never reached Logcat. See
/// `CHANGE_REPORT_STEP59.md` for the full trace.

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
/// "📄 PDF Ready" card and for `Share.shareXFiles` to open/share the file.
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
    // Step 59: every stage of the export pipeline logs unconditionally in
    // debug builds via `debugPrint` (a no-op in release builds), so a real
    // failure is always visible in Logcat instead of only showing the
    // user-facing generic message.
    debugPrint(detail == null ? '[PdfExport] $tag' : '[PdfExport] $tag: $detail');
  }

  // ---------------------------------------------------------------------
  // STEP 59 — Unicode font support.
  //
  // `PdfStandardFont` can only encode WinAnsi/Latin-1 text. Pak AI's chat
  // replies can contain Urdu-script (or other non-Latin) characters, and
  // handing those to a standard font is exactly the kind of thing that
  // throws deep inside Syncfusion's layout engine. There is no bundled
  // Unicode font already in this project (nothing under `assets/`, no
  // `fonts:` section in `pubspec.yaml`), and this fix intentionally does
  // NOT add a new package/dependency or a network fetch — so instead this
  // reads a Unicode-capable TrueType font that Android already ships
  // on-device for its own Arabic/Urdu system-locale support. This keeps
  // the feature 100% local/free with zero new dependencies. If none of
  // these paths exist on a given device (e.g. some custom ROMs, iOS, or a
  // desktop/debug build), export still proceeds — see `_fontFor` below.
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
  ];

  static List<int>? _cachedUnicodeFontBytes;
  static bool _unicodeFontLookupDone = false;

  /// Returns raw TrueType bytes for a Unicode font found on-device, or
  /// `null` if none of the known system font paths exist/are readable.
  /// Result is cached for the lifetime of the isolate — this only touches
  /// disk once per app run.
  static List<int>? _findSystemUnicodeFontBytes() {
    if (_unicodeFontLookupDone) return _cachedUnicodeFontBytes;
    _unicodeFontLookupDone = true;
    for (final path in _systemUnicodeFontPaths) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          _cachedUnicodeFontBytes = file.readAsBytesSync();
          _log('PDF_EXPORT_UNICODE_FONT_FOUND', path);
          return _cachedUnicodeFontBytes;
        }
      } catch (e) {
        // Unreadable/permission-denied on this path — try the next one.
        _log('PDF_EXPORT_UNICODE_FONT_PATH_FAILED', '$path -> $e');
      }
    }
    _log('PDF_EXPORT_UNICODE_FONT_NOT_FOUND');
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

  /// Picks the right font for [text]: a Unicode TrueType font (from the
  /// device's own system fonts) when [text] contains non-Latin characters
  /// and one is available, otherwise the existing standard Helvetica font.
  /// Never throws — falls back to [standardFont] on any font-loading
  /// failure so a single bad file read can't take down the whole export.
  static PdfFont _fontFor(
    String text, {
    required PdfFont standardFont,
    required double size,
    required bool bold,
  }) {
    if (!_needsUnicodeFont(text)) return standardFont;
    final bytes = _findSystemUnicodeFontBytes();
    if (bytes == null) return standardFont;
    try {
      return PdfTrueTypeFont(
        bytes,
        size,
        style: bold ? PdfFontStyle.bold : PdfFontStyle.regular,
      );
    } catch (e) {
      _log('PDF_EXPORT_UNICODE_FONT_LOAD_FAILED', e);
      return standardFont;
    }
  }

  /// Builds a real, selectable-text PDF from [pairs] and saves it inside the
  /// app's own documents directory (`<app docs>/pak_ai_exports/`) — no
  /// public-Downloads/MediaStore write is attempted, since that's the
  /// unreliable part under modern Android scoped storage; the chat UI's
  /// "Open / Share" action (see `PdfExportResultCard`) hands the saved file
  /// to the OS share sheet instead, which lets the person save it wherever
  /// they like (Drive, Files, a PDF viewer's own "Save a copy", etc.) — the
  /// safest supported flow given the existing project has no MediaStore/
  /// file-picker-save plugin.
  ///
  /// Throws [PdfExportException] with an already user-friendly message on
  /// any failure — empty input, a generation error, or a file-system error.
  /// The real exception + stack trace are always logged first (Step 59).
  static Future<PdfExportResult> generate({
    required List<PdfQaPair> pairs,
    required PdfExportScope scope,
  }) async {
    _log('PDF_EXPORT_START', 'scope=$scope inputPairs=${pairs.length}');

    final cleanPairs = pairs
        .where((p) => p.question.trim().isNotEmpty && p.answer.trim().isNotEmpty)
        .toList(growable: false);
    _log('PDF_EXPORT_MESSAGES_COUNT', cleanPairs.length);

    if (cleanPairs.isEmpty) {
      throw const PdfExportException(
        "There's no conversation yet to turn into a PDF — ask me something "
        'first, then try again.',
      );
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

        // Step 59: pick a Unicode-safe font per block whenever the text
        // actually needs one (Urdu/Arabic script etc.) instead of always
        // using the Latin-only standard font — this is the fix for the
        // real, previously-swallowed exception.
        final qLabelFont =
            _fontFor(question, standardFont: labelFontStd, size: 12, bold: true);
        final qBodyFont =
            _fontFor(question, standardFont: bodyFontStd, size: 11.5, bold: false);
        final aLabelFont =
            _fontFor(answer, standardFont: labelFontStd, size: 12, bold: true);
        final aBodyFont =
            _fontFor(answer, standardFont: bodyFontStd, size: 11.5, bold: false);

        final qLabel = PdfTextElement(
          text: 'Question',
          font: qLabelFont,
          brush: PdfSolidBrush(accent),
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
        currentPage = qLabel.page;
        currentY = qLabel.bounds.bottom + 3;

        final qBody = PdfTextElement(
          text: question,
          font: qBodyFont,
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
        currentPage = qBody.page;
        currentY = qBody.bounds.bottom + 12;

        final aLabel = PdfTextElement(
          text: 'Answer',
          font: aLabelFont,
          brush: PdfSolidBrush(accent),
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
        currentPage = aLabel.page;
        currentY = aLabel.bounds.bottom + 3;

        final aBody = PdfTextElement(
          text: answer,
          font: aBodyFont,
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
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
      _log('PDF_EXPORT_SHARE_READY', file.path);

      return PdfExportResult(
        filePath: file.path,
        fileName: fileName,
        pairCount: cleanPairs.length,
        scope: scope,
      );
    } on PdfExportException {
      rethrow;
    } catch (e, stackTrace) {
      // Step 59: this used to be `catch (_)`, which threw away the real
      // exception entirely. It is now always logged in full — both the
      // exception and its stack trace — before the clean, generic message
      // is shown to the user. This is the single change that makes future
      // failures (of any kind, not just the font issue) diagnosable.
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
