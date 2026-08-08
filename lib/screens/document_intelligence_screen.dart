import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/services/attachment_service.dart';
import '../core/services/document_intelligence_service.dart';
import '../core/theme/chat_palette.dart';
import '../widgets/attachment_sheet.dart' show AttachmentType;

/// Step 39 — Advanced Document Intelligence result screen.
///
/// Mirrors the structure Step 38's [TextScanResultScreen] established
/// (loading → success/error, Copy + Use in Chat) but for a richer,
/// structured result: summary, key points, headings, dates/names/numbers,
/// key facts, reconstructed tables, and a grounded Q&A panel.
///
/// Returns the summary text via `Navigator.pop` when the user taps
/// "Use in Chat" — the caller (`ChatScreen`) puts it into the composer.
/// Nothing is ever sent automatically from here.
class DocumentIntelligenceScreen extends StatefulWidget {
  final AttachmentResult file;
  final AttachmentType source;

  const DocumentIntelligenceScreen({
    super.key,
    required this.file,
    required this.source,
  });

  @override
  State<DocumentIntelligenceScreen> createState() =>
      _DocumentIntelligenceScreenState();
}

enum _ScreenStatus { loading, success, error }

class _DocumentIntelligenceScreenState
    extends State<DocumentIntelligenceScreen> {
  _ScreenStatus _status = _ScreenStatus.loading;
  DocumentIntelligenceResult? _result;
  PreparedDocument? _preparedDoc;
  String? _errorMessage;

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _summaryKey = GlobalKey();
  final GlobalKey _keyPointsKey = GlobalKey();
  final GlobalKey _tablesKey = GlobalKey();
  final GlobalKey _factsKey = GlobalKey();
  final GlobalKey _qaKey = GlobalKey();

  final TextEditingController _qaController = TextEditingController();
  final FocusNode _qaFocusNode = FocusNode();
  final List<DocumentQaTurn> _qaTurns = [];
  bool _isAsking = false;
  String? _qaError;

  bool get _isImage => widget.source != AttachmentType.document;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _qaController.dispose();
    _qaFocusNode.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    setState(() {
      _status = _ScreenStatus.loading;
      _errorMessage = null;
    });
    try {
      final doc = await DocumentIntelligenceService.prepare(
        file: widget.file,
        source: widget.source,
      );
      final result = await DocumentIntelligenceService.analyze(doc);
      if (!mounted) return;
      setState(() {
        _preparedDoc = doc;
        _result = result;
        _status = _ScreenStatus.success;
      });
    } on DocumentIntelligenceException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
        _status = _ScreenStatus.error;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Something went wrong while analyzing this document. Please try again.';
        _status = _ScreenStatus.error;
      });
    }
  }

  void _copySummary() {
    final text = _result?.summary;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.selectionClick();
    _showSnack('Copied to clipboard');
  }

  void _useInChat() {
    final text = _result?.summary;
    if (text == null || text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _scrollTo(GlobalKey key) {
    final ctx = key.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: 0.05,
    );
  }

  Future<void> _submitQuestion([String? presetQuestion]) async {
    final doc = _preparedDoc;
    if (doc == null || _isAsking) return;

    final question = (presetQuestion ?? _qaController.text).trim();
    if (question.isEmpty) {
      _qaFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isAsking = true;
      _qaError = null;
    });

    try {
      final turn = await DocumentIntelligenceService.askQuestion(
        doc,
        question,
        priorTurns: _qaTurns,
      );
      if (!mounted) return;
      setState(() {
        _qaTurns.add(turn);
        _qaController.clear();
        _isAsking = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_qaKey));
    } on DocumentIntelligenceException catch (e) {
      if (!mounted) return;
      setState(() {
        _qaError = e.message;
        _isAsking = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _qaError = 'Could not get an answer. Please try again.';
        _isAsking = false;
      });
    }
  }

  void _askAboutDocument() {
    _scrollTo(_qaKey);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _qaFocusNode.requestFocus());
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
          title: const Text('Document AI'),
        ),
        body: SafeArea(
          child: Builder(
            builder: (_) {
              switch (_status) {
                case _ScreenStatus.loading:
                  return _LoadingView(
                    scheme: scheme,
                    isImage: _isImage,
                    filePath: widget.file.path,
                    fileName: widget.file.name,
                  );
                case _ScreenStatus.error:
                  return Padding(
                    padding: const EdgeInsets.all(20),
                    child: _ErrorView(
                      scheme: scheme,
                      message: _errorMessage ?? 'Something went wrong.',
                      onRetry: _run,
                    ),
                  );
                case _ScreenStatus.success:
                  return _ResultView(
                    scheme: scheme,
                    result: _result!,
                    scrollController: _scrollController,
                    summaryKey: _summaryKey,
                    keyPointsKey: _keyPointsKey,
                    tablesKey: _tablesKey,
                    factsKey: _factsKey,
                    qaKey: _qaKey,
                    onCopy: _copySummary,
                    onUseInChat: _useInChat,
                    onScrollToSummary: () => _scrollTo(_summaryKey),
                    onScrollToKeyPoints: () => _scrollTo(_keyPointsKey),
                    onScrollToTables: () => _scrollTo(_tablesKey),
                    onScrollToFacts: () => _scrollTo(_factsKey),
                    onAskAboutDocument: _askAboutDocument,
                    qaController: _qaController,
                    qaFocusNode: _qaFocusNode,
                    qaTurns: _qaTurns,
                    isAsking: _isAsking,
                    qaError: _qaError,
                    onSubmitQuestion: _submitQuestion,
                  );
              }
            },
          ),
        ),
      ),
    );
  }
}

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
  final bool isImage;
  final String filePath;
  final String fileName;

  const _LoadingView({
    required this.scheme,
    required this.isImage,
    required this.filePath,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.file(
                  File(filePath),
                  height: 180,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _FileBadge(scheme: scheme),
                ),
              )
            else
              _FileBadge(scheme: scheme, name: fileName),
            const SizedBox(height: 28),
            CircularProgressIndicator(color: scheme.primary),
            const SizedBox(height: 18),
            Text(
              'Analyzing document…',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(
              'Reading content, structure, and tables',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant.withOpacity(0.7),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileBadge extends StatelessWidget {
  final ColorScheme scheme;
  final String? name;
  const _FileBadge({required this.scheme, this.name});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withOpacity(0.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(Icons.picture_as_pdf_rounded, size: 40, color: scheme.primary),
        ),
        if (name != null) ...[
          const SizedBox(height: 10),
          Text(
            name!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
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
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  final ColorScheme scheme;
  final DocumentIntelligenceResult result;
  final ScrollController scrollController;
  final GlobalKey summaryKey;
  final GlobalKey keyPointsKey;
  final GlobalKey tablesKey;
  final GlobalKey factsKey;
  final GlobalKey qaKey;
  final VoidCallback onCopy;
  final VoidCallback onUseInChat;
  final VoidCallback onScrollToSummary;
  final VoidCallback onScrollToKeyPoints;
  final VoidCallback onScrollToTables;
  final VoidCallback onScrollToFacts;
  final VoidCallback onAskAboutDocument;
  final TextEditingController qaController;
  final FocusNode qaFocusNode;
  final List<DocumentQaTurn> qaTurns;
  final bool isAsking;
  final String? qaError;
  final ValueChanged<String> onSubmitQuestion;

  const _ResultView({
    required this.scheme,
    required this.result,
    required this.scrollController,
    required this.summaryKey,
    required this.keyPointsKey,
    required this.tablesKey,
    required this.factsKey,
    required this.qaKey,
    required this.onCopy,
    required this.onUseInChat,
    required this.onScrollToSummary,
    required this.onScrollToKeyPoints,
    required this.onScrollToTables,
    required this.onScrollToFacts,
    required this.onAskAboutDocument,
    required this.qaController,
    required this.qaFocusNode,
    required this.qaTurns,
    required this.isAsking,
    required this.qaError,
    required this.onSubmitQuestion,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            children: [
              _QuickActionsRow(
                scheme: scheme,
                onSummarize: onScrollToSummary,
                onKeyPoints: onScrollToKeyPoints,
                onTables: onScrollToTables,
                onImportant: onScrollToFacts,
                onAsk: onAskAboutDocument,
                hasTables: result.tables.isNotEmpty,
              ),
              const SizedBox(height: 18),
              if (result.isFallback)
                _RawFallbackCard(scheme: scheme, text: result.rawFallbackText!)
              else ...[
                _SectionCard(
                  key: summaryKey,
                  scheme: scheme,
                  title: result.documentType ?? 'Summary',
                  icon: Icons.auto_awesome_rounded,
                  badge: 'Generated',
                  child: Text(
                    result.summary,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(height: 1.5),
                  ),
                ),
                if (result.keyPoints.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SectionCard(
                    key: keyPointsKey,
                    scheme: scheme,
                    title: 'Key Points',
                    icon: Icons.checklist_rounded,
                    badge: 'Extracted',
                    child: _BulletList(items: result.keyPoints),
                  ),
                ],
                if (result.headings.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SectionCard(
                    scheme: scheme,
                    title: 'Headings & Sections',
                    icon: Icons.segment_rounded,
                    badge: 'Extracted',
                    child: _BulletList(items: result.headings),
                  ),
                ],
                if (result.tables.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SectionCard(
                    key: tablesKey,
                    scheme: scheme,
                    title: 'Tables',
                    icon: Icons.table_chart_rounded,
                    badge: 'Extracted',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < result.tables.length; i++) ...[
                          if (i > 0) const SizedBox(height: 16),
                          _TableView(scheme: scheme, table: result.tables[i]),
                        ],
                      ],
                    ),
                  ),
                ],
                if (result.dates.isNotEmpty ||
                    result.names.isNotEmpty ||
                    result.numbers.isNotEmpty ||
                    result.keyFacts.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SectionCard(
                    key: factsKey,
                    scheme: scheme,
                    title: 'Important Information',
                    icon: Icons.fact_check_rounded,
                    badge: 'Extracted',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (result.keyFacts.isNotEmpty)
                          _BulletList(items: result.keyFacts),
                        if (result.dates.isNotEmpty)
                          _ChipGroup(
                              scheme: scheme,
                              label: 'Dates',
                              items: result.dates,
                              icon: Icons.event_rounded),
                        if (result.names.isNotEmpty)
                          _ChipGroup(
                              scheme: scheme,
                              label: 'Names',
                              items: result.names,
                              icon: Icons.person_outline_rounded),
                        if (result.numbers.isNotEmpty)
                          _ChipGroup(
                              scheme: scheme,
                              label: 'Numbers',
                              items: result.numbers,
                              icon: Icons.numbers_rounded),
                      ],
                    ),
                  ),
                ],
                if (!result.hasAnyExtractedContent)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: _EmptyNotice(scheme: scheme),
                  ),
              ],
              const SizedBox(height: 14),
              _QaSection(
                key: qaKey,
                scheme: scheme,
                controller: qaController,
                focusNode: qaFocusNode,
                turns: qaTurns,
                isAsking: isAsking,
                error: qaError,
                onSubmit: onSubmitQuestion,
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Row(
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
          ),
        ),
      ],
    );
  }
}

class _QuickActionsRow extends StatelessWidget {
  final ColorScheme scheme;
  final VoidCallback onSummarize;
  final VoidCallback onKeyPoints;
  final VoidCallback onTables;
  final VoidCallback onImportant;
  final VoidCallback onAsk;
  final bool hasTables;

  const _QuickActionsRow({
    required this.scheme,
    required this.onSummarize,
    required this.onKeyPoints,
    required this.onTables,
    required this.onImportant,
    required this.onAsk,
    required this.hasTables,
  });

  @override
  Widget build(BuildContext context) {
    final chips = <_ActionChipData>[
      _ActionChipData('Summarize', Icons.auto_awesome_rounded, onSummarize),
      _ActionChipData('Key points', Icons.checklist_rounded, onKeyPoints),
      if (hasTables)
        _ActionChipData('Read tables', Icons.table_chart_rounded, onTables),
      _ActionChipData('Important info', Icons.fact_check_rounded, onImportant),
      _ActionChipData('Ask about this', Icons.forum_rounded, onAsk),
    ];

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final chip = chips[index];
          return ActionChip(
            avatar: Icon(chip.icon, size: 16, color: scheme.primary),
            label: Text(chip.label),
            onPressed: chip.onTap,
            backgroundColor: scheme.surfaceContainerHigh,
            side: BorderSide(color: scheme.outlineVariant.withOpacity(0.4)),
            labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          );
        },
      ),
    );
  }
}

class _ActionChipData {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _ActionChipData(this.label, this.icon, this.onTap);
}

class _SectionCard extends StatelessWidget {
  final ColorScheme scheme;
  final String title;
  final IconData icon;
  final String badge;
  final Widget child;

  const _SectionCard({
    super.key,
    required this.scheme,
    required this.title,
    required this.icon,
    required this.badge,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final isGenerated = badge == 'Generated';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (isGenerated ? scheme.secondary : scheme.primary)
                      .withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isGenerated ? scheme.secondary : scheme.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _BulletList extends StatelessWidget {
  final List<String> items;
  const _BulletList({required this.items});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    item,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ChipGroup extends StatelessWidget {
  final ColorScheme scheme;
  final String label;
  final List<String> items;
  final IconData icon;

  const _ChipGroup({
    required this.scheme,
    required this.label,
    required this.items,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in items)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: scheme.outlineVariant.withOpacity(0.4),
                    ),
                  ),
                  child: Text(
                    item,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single reconstructed table, rendered as a horizontally scrollable
/// grid so it never overflows on narrow phones — the outer [_SectionCard]
/// is already full-width and vertically stacked, so only horizontal
/// scrolling is needed here.
class _TableView extends StatelessWidget {
  final ColorScheme scheme;
  final DocumentTable table;

  const _TableView({required this.scheme, required this.table});

  static const double _minColWidth = 96;

  @override
  Widget build(BuildContext context) {
    final columnCount = table.headers.isNotEmpty
        ? table.headers.length
        : (table.rows.isNotEmpty ? table.rows.first.length : 0);

    if (columnCount == 0) {
      return Text(
        'This table could not be reconstructed.',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    Widget cell(String text, {bool header = false}) {
      final isUnclear = text.trim() == '[unclear]';
      return Container(
        width: _minColWidth,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: header ? scheme.primary.withOpacity(0.10) : null,
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant.withOpacity(0.3)),
            right: BorderSide(color: scheme.outlineVariant.withOpacity(0.3)),
          ),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: header ? FontWeight.w700 : FontWeight.w400,
                fontStyle: isUnclear ? FontStyle.italic : FontStyle.normal,
                color: isUnclear
                    ? scheme.onSurfaceVariant.withOpacity(0.7)
                    : scheme.onSurface,
              ),
        ),
      );
    }

    List<String> padRow(List<String> row) {
      if (row.length >= columnCount) return row.sublist(0, columnCount);
      return [...row, ...List.filled(columnCount - row.length, '[unclear]')];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (table.caption != null) ...[
          Text(
            table.caption!,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant.withOpacity(0.3)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (table.headers.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final h in table.headers) cell(h, header: true),
                      ],
                    ),
                  for (final row in table.rows)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final c in padRow(row)) cell(c),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyNotice extends StatelessWidget {
  final ColorScheme scheme;
  const _EmptyNotice({required this.scheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No additional structured details (headings, dates, tables, etc.) were found beyond the summary above.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _RawFallbackCard extends StatelessWidget {
  final ColorScheme scheme;
  final String text;
  const _RawFallbackCard({required this.scheme, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'Analysis',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// The grounded Q&A panel: question input + send, followed by the running
/// list of question/answer turns for this document.
class _QaSection extends StatelessWidget {
  final ColorScheme scheme;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<DocumentQaTurn> turns;
  final bool isAsking;
  final String? error;
  final ValueChanged<String> onSubmit;

  const _QaSection({
    super.key,
    required this.scheme,
    required this.controller,
    required this.focusNode,
    required this.turns,
    required this.isAsking,
    required this.error,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withOpacity(0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.forum_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'Ask about this document',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final turn in turns) _QaTurnView(scheme: scheme, turn: turn),
          if (isAsking)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Thinking…',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: !isAsking,
                  textInputAction: TextInputAction.send,
                  onSubmitted: onSubmit,
                  decoration: InputDecoration(
                    hintText: 'Ask a question about this document…',
                    isDense: true,
                    filled: true,
                    fillColor: scheme.surface,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                          color: scheme.outlineVariant.withOpacity(0.4)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                          color: scheme.outlineVariant.withOpacity(0.4)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Material(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: isAsking ? null : () => onSubmit(controller.text),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(Icons.send_rounded,
                        size: 18, color: scheme.onPrimary),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QaTurnView extends StatelessWidget {
  final ColorScheme scheme;
  final DocumentQaTurn turn;
  const _QaTurnView({required this.scheme, required this.turn});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.person_rounded, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  turn.question,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.auto_awesome_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  turn.answer,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.4,
                        fontStyle: turn.foundInDocument
                            ? FontStyle.normal
                            : FontStyle.italic,
                        color: turn.foundInDocument
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
