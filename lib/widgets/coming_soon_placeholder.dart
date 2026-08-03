import 'package:flutter/material.dart';

/// Temporary placeholder body for screens not fully built out yet.
///
/// As of Step 16, Pak AI's only remaining user of this is the Profile
/// tab — Chat, History, and Settings are all fully implemented, and the
/// old Image/Video/Script/Tools placeholder screens that used to share
/// this widget have been removed along with those features.
class ComingSoonPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String phaseLabel;

  const ComingSoonPlaceholder({
    super.key,
    required this.icon,
    required this.title,
    required this.phaseLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 48, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Coming in $phaseLabel',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
