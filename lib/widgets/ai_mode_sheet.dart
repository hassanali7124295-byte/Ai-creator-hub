import 'dart:ui';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';

import '../core/theme/chat_palette.dart';
import '../models/ai_mode.dart';

/// Shows the AI Modes picker as a glass, rounded-top bottom sheet — a grid
/// of the [AiMode]s, current selection highlighted. Returns the newly
/// picked [AiMode], or `null` if dismissed without a change.
///
/// Purely a chat-scoped overlay (Step 16): there's no separate screen or
/// route behind this, matching every other "everything happens inside one
/// chat" sheet in the app (see `attachment_sheet.dart`).
Future<AiMode?> showAiModeSheet(BuildContext context, AiMode current) {
  final accent = ChatPalette.colorSchemeFor(context);

  return showModalBottomSheet<AiMode>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      return ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  theme.colorScheme.surfaceContainerHigh.withOpacity(0.92),
                  theme.colorScheme.surface.withOpacity(0.97),
                ],
              ),
              border: Border(
                top: BorderSide(
                  color: accent.primary.withOpacity(0.18),
                  width: 1,
                ),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurfaceVariant
                              .withOpacity(0.3),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'AI Modes',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Focus Pak AI for this chat',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 18),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(sheetContext).size.height * 0.55,
                      ),
                      child: GridView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: 2.4,
                        ),
                        itemCount: AiMode.values.length,
                        itemBuilder: (context, index) {
                          final mode = AiMode.values[index];
                          return FadeInUp(
                            duration: const Duration(milliseconds: 260),
                            delay: Duration(milliseconds: 18 * index),
                            from: 14,
                            child: _ModeCard(
                              mode: mode,
                              selected: mode == current,
                              accent: accent,
                              theme: theme,
                              onTap: () =>
                                  Navigator.of(sheetContext).pop(mode),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ModeCard extends StatelessWidget {
  final AiMode mode;
  final bool selected;
  final ColorScheme accent;
  final ThemeData theme;
  final VoidCallback onTap;

  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.accent,
    required this.theme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? accent.primary.withOpacity(0.14)
          : theme.colorScheme.surfaceContainer.withOpacity(0.6),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? accent.primary.withOpacity(0.55)
                  : theme.colorScheme.outlineVariant.withOpacity(0.4),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Text(mode.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mode.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? accent.primary
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                    Text(
                      mode.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle_rounded,
                    size: 18, color: accent.primary),
            ],
          ),
        ),
      ),
    );
  }
}
