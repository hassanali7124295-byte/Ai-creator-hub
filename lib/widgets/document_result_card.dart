import 'package:flutter/material.dart';

import '../core/services/document_intelligence_service.dart';

/// Step 40 — Chat-Native Intelligence UX Refactor (Part 4): renders a
/// [DocumentIntelligenceResult] as a compact card inside a chat bubble,
/// with a "View details"/"Show less" toggle for the rest of the
/// structured analysis (Step 39's key points, headings, dates, names,
/// numbers, key facts, and tables) — instead of forcing navigation to the
/// standalone `DocumentIntelligenceScreen` or flooding the chat with one
/// giant block of text.
///
/// Purely a rendering widget: it takes an already-parsed
/// [DocumentIntelligenceResult] (built via that service's existing,
/// unchanged defensive JSON parsing) and lays it out. No Gemini calls, no
/// navigation, no new pipeline.
class DocumentResultCard extends StatefulWidget {
  final DocumentIntelligenceResult result;

  const DocumentResultCard({super.key, required this.result});

  @override
  State<DocumentResultCard> createState() => _DocumentResultCardState();
}

class _DocumentResultCardState extends State<DocumentResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = widget.result;

    if (result.isFallback) {
      // Defensive-parsing fallback (Step 39): Gemini's reply couldn't be
      // parsed as the expected JSON shape — show the raw text plainly,
      // same as any normal assistant reply, no card chrome.
      return SelectableText(
        result.rawFallbackText!,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurface,
          fontSize: 17.5,
          height: 1.6,
        ),
      );
    }

    final extraKeyPoints =
        result.keyPoints.length > 3 ? result.keyPoints.sublist(0, 3) : result.keyPoints;
    final hasMoreKeyPoints = result.keyPoints.length > 3;
    final hasMoreBeyondSummary = hasMoreKeyPoints ||
        result.headings.isNotEmpty ||
        result.dates.isNotEmpty ||
        result.names.isNotEmpty ||
        result.numbers.isNotEmpty ||
        result.keyFacts.isNotEmpty ||
        result.tables.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (result.documentType != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.description_rounded, size: 15, color: scheme.primary),
                const SizedBox(width: 6),
                Text(
                  result.documentType!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        SelectableText(
          result.summary,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurface,
            fontSize: 17.5,
            height: 1.6,
          ),
        ),
        if (extraKeyPoints.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final point in extraKeyPoints) _CompactBullet(text: point),
          if (hasMoreKeyPoints && !_expanded)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 14),
              child: Text(
                '+${result.keyPoints.length - 3} more key point'
                '${result.keyPoints.length - 3 == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
        ],
        if (hasMoreBeyondSummary) ...[
          const SizedBox(height: 10),
          _ViewDetailsToggle(
            expanded: _expanded,
            onTap: () => setState(() => _expanded = !_expanded),
          ),
        ],
        if (_expanded) ...[
          const SizedBox(height: 12),
          if (hasMoreKeyPoints)
            _DetailSection(
              icon: Icons.checklist_rounded,
              title: 'All key points',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final point in result.keyPoints) _CompactBullet(text: point),
                ],
              ),
            ),
          if (result.headings.isNotEmpty)
            _DetailSection(
              icon: Icons.segment_rounded,
              title: 'Headings & sections',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final h in result.headings) _CompactBullet(text: h),
                ],
              ),
            ),
          if (result.tables.isNotEmpty)
            _DetailSection(
              icon: Icons.table_chart_rounded,
              title: 'Tables',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < result.tables.length; i++) ...[
                    if (i > 0) const SizedBox(height: 14),
                    _CompactTable(scheme: scheme, table: result.tables[i]),
                  ],
                ],
              ),
            ),
          if (result.keyFacts.isNotEmpty)
            _DetailSection(
              icon: Icons.fact_check_rounded,
              title: 'Key facts',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in result.keyFacts) _CompactBullet(text: f),
                ],
              ),
            ),
          if (result.dates.isNotEmpty)
            _DetailSection(
              icon: Icons.event_rounded,
              title: 'Dates',
              child: _CompactChips(items: result.dates),
            ),
          if (result.names.isNotEmpty)
            _DetailSection(
              icon: Icons.person_outline_rounded,
              title: 'Names',
              child: _CompactChips(items: result.names),
            ),
          if (result.numbers.isNotEmpty)
            _DetailSection(
              icon: Icons.numbers_rounded,
              title: 'Numbers',
              child: _CompactChips(items: result.numbers),
            ),
        ],
      ],
    );
  }
}

class _ViewDetailsToggle extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;
  const _ViewDetailsToggle({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: scheme.primary.withOpacity(0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                expanded ? 'Show less' : 'View details',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                size: 18,
                color: scheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _DetailSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                title,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}

class _CompactBullet extends StatelessWidget {
  final String text;
  const _CompactBullet({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactChips extends StatelessWidget {
  final List<String> items;
  const _CompactChips({required this.items});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(item, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}

/// A single table, rendered horizontally-scrollable so it can never cause
/// a RenderFlex overflow inside the chat bubble's constrained width —
/// mirrors the same pattern `DocumentIntelligenceScreen._TableView` uses
/// (that screen is untouched; this is a small, self-contained
/// re-implementation sized for the compact chat card rather than a shared
/// dependency between the two).
class _CompactTable extends StatelessWidget {
  final ColorScheme scheme;
  final DocumentTable table;
  const _CompactTable({required this.scheme, required this.table});

  static const double _minColWidth = 88;

  @override
  Widget build(BuildContext context) {
    final columnCount = table.headers.isNotEmpty
        ? table.headers.length
        : (table.rows.isNotEmpty ? table.rows.first.length : 0);
    if (columnCount == 0) return const SizedBox.shrink();

    Widget cell(String text, {bool header = false}) {
      final isUnclear = text.trim() == '[unclear]';
      return Container(
        width: _minColWidth,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: header ? scheme.primary.withOpacity(0.10) : null,
          border: Border(
            bottom: BorderSide(color: scheme.outlineVariant.withOpacity(0.3)),
            right: BorderSide(color: scheme.outlineVariant.withOpacity(0.3)),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12.5,
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
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
                      children: [for (final h in table.headers) cell(h, header: true)],
                    ),
                  for (final row in table.rows)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [for (final c in padRow(row)) cell(c)],
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
