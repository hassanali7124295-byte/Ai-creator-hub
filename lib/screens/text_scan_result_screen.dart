import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/attachment_service.dart';
import '../core/services/text_recognition_service.dart';
import '../core/theme/chat_palette.dart';
import '../widgets/attachment_sheet.dart' show AttachmentType;

/// Step 38 — result screen shared by both OCR ("Scan Text") and Handwriting
/// Recognition. Only the prompt sent to Gemini (see
/// [TextRecognitionService]) and a couple of labels differ between the two
/// modes; the screen itself — loading, result, and error states — is
/// identical, so one screen covers both rather than two near-duplicates.
///
/// Returns the recognized text via `Navigator.pop` when the user taps
/// "Use in Chat" — the caller (`ChatScreen`) puts it into the composer.
/// Nothing is ever sent automatically from here.
class TextScanResultScreen extends StatefulWidget {
  final AttachmentResult image;
  final AttachmentType source;
  final TextScanMode mode;

  const TextScanResultScreen({
    super.key,
    required this.image,
    required this.source,
    required this.mode,
  });

  @override
  State<TextScanResultScreen> createState() => _TextScanResultScreenState();
}

enum _ScanStatus { loading, success, error }

class _TextScanResultScreenState extends State<TextScanResultScreen> {
  _ScanStatus _status = _ScanStatus.loading;
  TextRecognitionResult? _result;
  String? _errorMessage;

  bool get _isOcr => widget.mode == TextScanMode.ocr;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _status = _ScanStatus.loading;
      _errorMessage = null;
    });
    try {
      final result = await TextRecognitionService.recognize(
        image: widget.image,
        mode: widget.mode,
        source: widget.source,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _status = _ScanStatus.success;
      });
    } on TextRecognitionException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _status = _ScanStatus.error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Something went wrong while reading this image. Please try again.';
        _status = _ScanStatus.error;
      });
    }
  }

  void _copy() {
    final text = _result?.text;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: const Text('Copied to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _useInChat() {
    final text = _result?.text;
    if (text == null || text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ChatPalette.themeFor(context);
    final scheme = theme.colorScheme;

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          leadingWidth: 56,
          scrolledUnderElevation: 0,
          leading: Center(
            child: _RoundedIconButton(
              scheme: scheme,
              icon: Icons.arrow_back_rounded,
              tooltip: 'Back',
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          title: Text(_isOcr ? 'Scan Text' : 'Handwriting'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Builder(
              builder: (_) {
                switch (_status) {
                  case _ScanStatus.loading:
                    return _LoadingView(
                      scheme: scheme,
                      isOcr: _isOcr,
                      imagePath: widget.image.path,
                    );
                  case _ScanStatus.error:
                    return _ErrorView(
                      scheme: scheme,
                      message: _errorMessage ?? 'Something went wrong.',
                      onRetry: _run,
                    );
                  case _ScanStatus.success:
                    return _ResultView(
                      scheme: scheme,
                      result: _result!,
                      onCopy: _copy,
                      onUseInChat: _useInChat,
                    );
                }
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Same rounded, translucent icon-button look used elsewhere (e.g.
/// Settings' back button), reused here for the AppBar back action.
class _RoundedIconButton extends StatelessWidget {
  final ColorScheme scheme;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _RoundedIconButton({
    required this.scheme,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: scheme.surfaceContainerHigh.withOpacity(0.7),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Icon(icon, size: 21, color: scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  final ColorScheme scheme;
  final bool isOcr;
  final String imagePath;

  const _LoadingView({
    required this.scheme,
    required this.isOcr,
    required this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.file(
              File(imagePath),
              height: 200,
              fit: BoxFit.cover,
              // A picked image path failing to decode here shouldn't ever
              // crash the loading state — just drop the preview.
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 28),
          CircularProgressIndicator(color: scheme.primary),
          const SizedBox(height: 18),
          Text(
            isOcr ? 'Reading text from image…' : 'Reading handwriting…',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final ColorScheme scheme;
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({
    required this.scheme,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 40, color: scheme.error),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  final ColorScheme scheme;
  final TextRecognitionResult result;
  final VoidCallback onCopy;
  final VoidCallback onUseInChat;

  const _ResultView({
    required this.scheme,
    required this.result,
    required this.onCopy,
    required this.onUseInChat,
  });

  @override
  Widget build(BuildContext context) {
    final showLowConfidenceNotice = result.mode == TextScanMode.handwriting &&
        (result.confidence == ScanConfidence.low ||
            result.confidence == ScanConfidence.medium);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLowConfidenceNotice) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.errorContainer.withOpacity(0.35),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 20, color: scheme.error),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result.confidence == ScanConfidence.low
                        ? 'This handwriting was hard to read — the result may contain mistakes. Please double-check it.'
                        : 'Some words in this handwriting were unclear — please double-check the result.',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: scheme.outlineVariant.withOpacity(0.25),
              ),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                result.text,
                style: Theme.of(context)
                    .textTheme
                    .bodyLarge
                    ?.copyWith(height: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onCopy,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.primary,
                  side: BorderSide(color: scheme.outlineVariant),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: onUseInChat,
                icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18),
                label: const Text('Use in Chat'),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary,
                  foregroundColor: scheme.onPrimary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
