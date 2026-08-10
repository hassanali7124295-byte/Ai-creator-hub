import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Step 50 — Local PDF Generator.
///
/// Generates a Pak-AI-branded PDF entirely on the device: no paid API, no
/// cloud PDF service, no upload of any kind, and — as of this fix — no
/// runtime network request of any kind, including for fonts. The `pdf`
/// package renders the bytes locally and the result is written straight
/// into this app's own document directory.
///
/// --- Urdu / Sindhi / RTL note --------------------------------------
/// Correct Urdu and Sindhi glyph shaping needs a Unicode Arabic-script
/// font. [_loadArabicFont] loads that font from exactly one place: the
/// bundled asset at [_bundledArabicFontAsset] — fully offline, no
/// network call, ever. There is deliberately no `PdfGoogleFonts`
/// network-fetch fallback (an earlier draft of this feature had one;
/// it was removed because "fetch it from Google's servers the first
/// time it's needed" is still a runtime network request, which the
/// brief for this fix explicitly disallows even as a one-time/cached
/// fallback).
///
/// If the asset can't be loaded (e.g. a maintainer hasn't added the
/// real font file yet — see `assets/fonts/README.md`), the PDF is still
/// generated rather than failing outright: English/Roman Urdu content
/// renders normally, and a short printed notice explains that Urdu/
/// Sindhi glyphs could not be shown, instead of silently producing a
/// PDF with mangled or missing text.
class PdfExportService {
  PdfExportService._();

  static const String _bundledArabicFontAsset =
      'assets/fonts/NotoNaskhArabic-Regular.ttf';

  static final RegExp _arabicScriptRange = RegExp(
    r'[\u0600-\u06FF\u0750-\u077F\uFB50-\uFDFF\uFE70-\uFEFF]',
  );

  /// True if [text] contains any Urdu/Sindhi/Arabic-script characters.
  static bool containsUrduOrArabic(String text) =>
      _arabicScriptRange.hasMatch(text);

  /// Loads the bundled Unicode Arabic-script font asset. Fully offline —
  /// this is the *only* font source this feature ever uses; there is no
  /// network fallback of any kind. Returns `null` (never throws) if the
  /// asset is missing or fails to parse, so callers can fall back to a
  /// Latin-only PDF plus an honest on-page notice instead of crashing.
  static Future<pw.Font?> _loadArabicFont() async {
    try {
      // Throws if the asset isn't bundled — caught below.
      await rootBundle.load(_bundledArabicFontAsset);
      return await fontFromAssetBundle(_bundledArabicFontAsset);
    } catch (_) {
      return null;
    }
  }

  /// Builds and saves the PDF, returning the local [File] it was written
  /// to. [question] is only rendered (as a "Q:"/"A:" pair) when non-null
  /// and non-empty — plain text/notes/conversation exports pass `null`.
  static Future<File> generate({
    required String title,
    String? question,
    required String body,
  }) async {
    final needsUrdu = containsUrduOrArabic(body) ||
        containsUrduOrArabic(question ?? '') ||
        containsUrduOrArabic(title);

    final arabicFont = needsUrdu ? await _loadArabicFont() : null;

    final theme = pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
      fontFallback: arabicFont != null ? [arabicFont] : const [],
    );

    final direction =
        needsUrdu && arabicFont != null ? pw.TextDirection.rtl : pw.TextDirection.ltr;
    final textAlign = direction == pw.TextDirection.rtl
        ? pw.TextAlign.right
        : pw.TextAlign.left;

    final now = DateTime.now();
    final dateStr = '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/${now.year}';

    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        theme: theme,
        margin: const pw.EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'Pak AI',
                  style: pw.TextStyle(
                    fontSize: 13,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColor.fromHex('#0B7A57'),
                  ),
                ),
                pw.Text(
                  dateStr,
                  style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
                ),
              ],
            ),
            pw.SizedBox(height: 6),
            pw.Divider(color: PdfColors.grey400, thickness: 0.6),
          ],
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            'Page ${context.pageNumber} of ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.SizedBox(height: 10),
          pw.Text(
            title,
            textDirection: direction,
            textAlign: textAlign,
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 16),
          if (question != null && question.trim().isNotEmpty) ...[
            pw.Text(
              'Q:',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              question.trim(),
              textDirection: direction,
              textAlign: textAlign,
              style: const pw.TextStyle(fontSize: 12.5, lineSpacing: 3),
            ),
            pw.SizedBox(height: 16),
            pw.Text(
              'A:',
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.grey700,
              ),
            ),
            pw.SizedBox(height: 4),
          ],
          pw.Text(
            body.trim(),
            textDirection: direction,
            textAlign: textAlign,
            style: const pw.TextStyle(fontSize: 12.5, lineSpacing: 3),
          ),
          if (needsUrdu && arabicFont == null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 24),
              child: pw.Text(
                'Note: an Urdu/Sindhi-capable font asset was not found in '
                'this build, so some Urdu or Sindhi characters above may '
                'not display correctly. This does not use the network — '
                'see assets/fonts/README.md to add the font file.',
                style: pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.red700,
                  fontStyle: pw.FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );

    final bytes = await doc.save();

    // App-specific document storage — no special Android storage
    // permission needed for this, and it isn't cleared like a temp/cache
    // directory would be.
    final docsDir = await getApplicationDocumentsDirectory();
    final pdfDir = Directory('${docsDir.path}/pak_ai_pdfs');
    if (!await pdfDir.exists()) {
      await pdfDir.create(recursive: true);
    }
    final fileName = 'PakAI_${now.millisecondsSinceEpoch}.pdf';
    final file = File('${pdfDir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Opens [path] using the printing package's built-in preview (which in
  /// turn offers the device's normal "Open with…"/print/share actions) —
  /// entirely local, the bytes never leave the device except through
  /// whichever app the user explicitly picks.
  static Future<void> open(String path) async {
    final bytes = await File(path).readAsBytes();
    await Printing.layoutPdf(
      onLayout: (_) async => bytes,
      name: path.split(Platform.pathSeparator).last,
    );
  }

  /// Shares [path] via Android's normal share sheet.
  static Future<void> share(String path, String fileName) async {
    final bytes = await File(path).readAsBytes();
    await Printing.sharePdf(bytes: bytes, filename: fileName);
  }
}
