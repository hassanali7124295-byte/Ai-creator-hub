import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/services/pdf_download_service.dart';
import '../core/services/pdf_export_service.dart';

/// STEP 56 — renders inside an assistant `ChatBubble` in place of the
/// normal Markdown body whenever `ChatMessage.pdfExportResult` is set.
/// STEP 60 — split "Download PDF" (real save) from "Share" (system sheet).
/// STEP 61 — "Download PDF" now calls `PdfDownloadService`, a native
/// MediaStore MethodChannel, instead of the `file_saver` package, which
/// could not be confirmed to actually write into Android's Downloads on
/// the real device this was tested on. Card design and the Share action
/// are otherwise unchanged from Step 60.
class PdfExportResultCard extends StatefulWidget {
  final PdfExportResult result;

  const PdfExportResultCard({super.key, required this.result});

  @override
  State<PdfExportResultCard> createState() => _PdfExportResultCardState();
}

class _PdfExportResultCardState extends State<PdfExportResultCard> {
  bool _busy = false;

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

  /// "Download PDF" — a real save into the device's public Downloads,
  /// distinct from Share. Reads the exact bytes `PdfExportService` already
  /// generated and saved to the app's own documents directory (no
  /// regeneration — Step 61 requirement #10) and hands them to
  /// `PdfDownloadService`, which writes them into Android's MediaStore
  /// Downloads via a small native MethodChannel. `_busy` blocks a second
  /// tap while one save is in flight (the service itself guards this too,
  /// as a second layer). Never shows a success message unless the native
  /// save actually reported success.
  Future<void> _downloadPdf() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = await _sourceFileOrWarn();
      if (file == null) return;
      final bytes = await file.readAsBytes();

      final savedPath = await PdfDownloadService.saveToDownloads(
        fileName: widget.result.fileName,
        bytes: bytes,
      );

      debugPrint('[PdfExport] PDF_DOWNLOAD_UI_SUCCESS: $savedPath');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF saved to Downloads')),
      );
    } on PdfDownloadException catch (e) {
      // The service already logged the real exception/stack trace under
      // [PdfDownload] — this is only the clean, already-safe message.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e, stackTrace) {
      debugPrint('[PdfDownload] ERROR (unexpected, UI layer): $e');
      debugPrint('[PdfDownload] STACKTRACE: $stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save PDF. Please try again.")),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Share — unchanged from Step 60: opens the system share sheet via
  /// `share_plus`, independent of the Download action above.
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
