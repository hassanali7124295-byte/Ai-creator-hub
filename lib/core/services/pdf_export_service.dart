import 'dart:io';
import 'dart:ui' show Rect, Offset;

import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// STEP 56 — AI Q&A → PDF Export Feature.
///
/// Generates a Pak AI–branded PDF entirely on-device from already-available
/// chat text, using the `syncfusion_flutter_pdf` package the project already
/// depends on for the existing PDF *reading*/extraction feature (Step 22A,
/// see `attachment_processor_service.dart`). No new package was added for
/// this — Syncfusion's PDF library can both read and *write* PDFs, so the
/// existing dependency is reused as-is. No network calls, no paid API.

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
/// show `e.message` directly in a chat bubble.
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
  // service, no Flutter/material dependency), so the RGB triplet is
  // duplicated here as a plain constant instead.
  static const int _accentR = 16;
  static const int _accentG = 185;
  static const int _accentB = 129;

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
  static Future<PdfExportResult> generate({
    required List<PdfQaPair> pairs,
    required PdfExportScope scope,
  }) async {
    final cleanPairs = pairs
        .where((p) => p.question.trim().isNotEmpty && p.answer.trim().isNotEmpty)
        .toList(growable: false);

    if (cleanPairs.isEmpty) {
      throw const PdfExportException(
        "There's no conversation yet to turn into a PDF — ask me something "
        'first, then try again.',
      );
    }

    PdfDocument? document;
    try {
      document = PdfDocument();
      document.pageSettings.size = PdfPageSize.a4;
      document.pageSettings.margins.all = 40;

      final accent = PdfColor(_accentR, _accentG, _accentB);
      final muted = PdfColor(120, 120, 120);
      final divider = PdfColor(225, 225, 225);

      final titleFont =
          PdfStandardFont(PdfFontFamily.helvetica, 22, style: PdfFontStyle.bold);
      final subtitleFont =
          PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.italic);
      final labelFont =
          PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.bold);
      final bodyFont = PdfStandardFont(PdfFontFamily.helvetica, 11.5);

      PdfPage page = document.pages.add();
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

        final qLabel = PdfTextElement(
          text: 'Question',
          font: labelFont,
          brush: PdfSolidBrush(accent),
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
        currentPage = qLabel.page;
        currentY = qLabel.bounds.bottom + 3;

        final qBody = PdfTextElement(
          text: pair.question.trim(),
          font: bodyFont,
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
        currentPage = qBody.page;
        currentY = qBody.bounds.bottom + 12;

        final aLabel = PdfTextElement(
          text: 'Answer',
          font: labelFont,
          brush: PdfSolidBrush(accent),
        ).draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, currentY, pageWidth, pageHeight),
          format: format,
        )!;
        currentPage = aLabel.page;
        currentY = aLabel.bounds.bottom + 3;

        final aBody = PdfTextElement(
          text: pair.answer.trim(),
          font: bodyFont,
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

      final bytes = await document.save();

      final docsDir = await getApplicationDocumentsDirectory();
      final exportsDir = Directory('${docsDir.path}/pak_ai_exports');
      if (!await exportsDir.exists()) {
        await exportsDir.create(recursive: true);
      }
      final fileName = 'PakAI_QA_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final file = File('${exportsDir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);

      return PdfExportResult(
        filePath: file.path,
        fileName: fileName,
        pairCount: cleanPairs.length,
        scope: scope,
      );
    } on PdfExportException {
      rethrow;
    } catch (_) {
      throw const PdfExportException(
        "Sorry, I couldn't create the PDF. Please try again.",
      );
    } finally {
      document?.dispose();
    }
  }
}
