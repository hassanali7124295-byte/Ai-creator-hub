import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/services/pdf_export_service.dart';

/// STEP 56 — renders inside an assistant `ChatBubble` in place of the
/// normal Markdown body whenever `ChatMessage.pdfExportResult` is set.
///
/// Deliberately small and self-contained (matches the "minimal, consistent
/// with existing Pak AI UI" requirement) — a single icon-and-status row
/// plus one primary action. No new screen, no change to the surrounding
/// bubble/action-row chrome.
class PdfExportResultCard extends StatefulWidget {
  final PdfExportResult result;

  const PdfExportResultCard({super.key, required this.result});

  @override
  State<PdfExportResultCard> createState() => _PdfExportResultCardState();
}

class _PdfExportResultCardState extends State<PdfExportResultCard> {
  bool _busy = false;

  Future<void> _openOrShare() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final file = File(widget.result.filePath);
      if (!await file.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "This PDF is no longer available on your device — "
              'ask me to create it again.',
            ),
          ),
        );
        return;
      }
      // Step 56: there's no file-opening/MediaStore-save plugin already in
      // the project, and public-Downloads writes are unreliable under
      // modern Android scoped storage — so the existing `share_plus`
      // dependency (already used for the AI-reply "Share" action) is
      // reused here too. The system share sheet it opens lets the person
      // save the PDF anywhere they like (Files, Drive, a PDF viewer's own
      // "Save a copy", etc.) or hand it straight to a PDF-viewing app —
      // covering both "Download" and "Share" from the spec with one
      // reliable, already-available action.
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/pdf')],
        text: 'Pak AI — ${widget.result.fileName}',
      );
    } catch (e, stackTrace) {
      // Step 59: log the real share_plus failure instead of discarding it —
      // this action already worked reliably for the existing "Share on AI
      // reply" flow, so a failure here during PDF export is worth being
      // able to see in Logcat rather than guessing.
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
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _openOrShare,
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
        ],
      ),
    );
  }
}
