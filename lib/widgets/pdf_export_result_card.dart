import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/services/pdf_export_service.dart';

/// STEP 56 — renders inside an assistant `ChatBubble` in place of the
/// normal Markdown body whenever `ChatMessage.pdfExportResult` is set.
/// STEP 60 — "Download PDF" now performs a real save into the device's
/// Downloads (via `file_saver`'s MediaStore-backed API) instead of only
/// opening the share sheet; Share is kept as a separate, secondary action.
///
/// Deliberately small and self-contained (matches the "minimal, consistent
/// with existing Pak AI UI" requirement) — a single icon-and-status row
/// plus one primary action and one compact secondary action. No new
/// screen, no change to the surrounding bubble/action-row chrome.
class PdfExportResultCard extends StatefulWidget {
  final PdfExportResult result;

  const PdfExportResultCard({super.key, required this.result});

  @override
  State<PdfExportResultCard> createState() => _PdfExportResultCardState();
}

class _PdfExportResultCardState extends State<PdfExportResultCard> {
  bool _busy = false;

  /// The file name without its `.pdf` extension — `file_saver`'s `name`
  /// parameter takes the base name and `ext` separately.
  String get _baseFileName {
    final name = widget.result.fileName;
    return name.toLowerCase().endsWith('.pdf')
        ? name.substring(0, name.length - 4)
        : name;
  }

  Future<File?> _sourceFileOrWarn() async {
    final file = File(widget.result.filePath);
    if (await file.exists()) return file;
    if (!mounted) return null;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "This PDF is no longer available on your device — "
          'ask me to create it again.',
        ),
      ),
    );
    return null;
  }

  /// "Download PDF" — Part 4/5 of Step 60: an actual local save into the
  /// device's Downloads, distinct from Share. Uses `file_saver`, which
  /// writes through Android's scoped-storage-safe MediaStore Downloads API
  /// on modern Android (no broad storage permission, no deprecated direct
  /// filesystem path into `/storage/emulated/0/Download` needed) and its
  /// own safe equivalent on older Android/iOS. No network, no server.
  Future<void> _downloadPdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    debugPrint('[PdfExport] PDF_DOWNLOAD_START: ${widget.result.filePath}');
    try {
      final file = await _sourceFileOrWarn();
      if (file == null) return;
      final bytes = await file.readAsBytes();

      final savedPath = await FileSaver.instance.saveFile(
        name: _baseFileName,
        bytes: Uint8List.fromList(bytes),
        ext: 'pdf',
        mimeType: MimeType.pdf,
      );

      debugPrint('[PdfExport] PDF_DOWNLOAD_SUCCESS');
      debugPrint('[PdfExport] PDF_DOWNLOAD_PATH: $savedPath');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved to Downloads — ${widget.result.fileName}'),
        ),
      );
    } catch (e, stackTrace) {
      // Never claim success on failure — show the clean message, keep the
      // real cause in the debug log.
      debugPrint('[PdfExport] PDF_DOWNLOAD_EXCEPTION: $e');
      debugPrint('[PdfExport] PDF_DOWNLOAD_STACKTRACE: $stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('PDF download failed. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Share — kept exactly as it worked before Step 60 (opens the system
  /// share sheet), now a secondary action instead of what "Download PDF"
  /// does. Reuses the same `share_plus` dependency already used for the
  /// existing AI-reply "Share" action.
  Future<void> _sharePdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _sourceFileOrWarn();
      if (file == null) return;
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf')],
        text: 'Pak AI — ${widget.result.fileName}',
      );
    } catch (e, stackTrace) {
      debugPrint('[PdfExport] PDF_EXPORT_SHARE_EXCEPTION: $e');
      debugPrint('[PdfExport] PDF_EXPORT_SHARE_STACKTRACE: $stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't open the PDF. Please try again."),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = widget.result;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withOpacity(0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withOpacity(0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.picture_as_pdf_rounded, size: 20, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'PDF Ready',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${result.pairCount} question'
            '${result.pairCount == 1 ? '' : 's'} & answer'
            '${result.pairCount == 1 ? '' : 's'} · ${result.fileName}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _downloadPdf,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download PDF'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: _busy ? null : _sharePdf,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                tooltip: 'Share',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
