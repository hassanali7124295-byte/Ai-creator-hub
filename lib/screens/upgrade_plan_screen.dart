import 'package:flutter/material.dart';

import '../core/theme/chat_palette.dart';

/// Step 56 — professional UI/architecture for the future "Pak AI Pro"
/// upgrade path. No payment gateway or subscription processing exists
/// yet, and this screen deliberately never shows a fake purchase
/// success — it's a benefits/placeholder screen ready for a real
/// gateway to be wired into [_UpgradeButton]'s `onTap` in a later step.
class UpgradePlanScreen extends StatelessWidget {
  const UpgradePlanScreen({super.key});

  static const _benefits = [
    ('More daily credits', Icons.bolt_rounded),
    ('Higher usage limits', Icons.speed_rounded),
    ('Fewer restrictions', Icons.lock_open_rounded),
    ('Premium AI experience', Icons.auto_awesome_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = ChatPalette.themeFor(context);
    final scheme = theme.colorScheme;

    return Theme(
      data: theme,
      child: Scaffold(
        backgroundColor: scheme.surface,
        appBar: AppBar(
          scrolledUnderElevation: 0,
          title: Text(
            'Upgrade Plan',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Icon(Icons.workspace_premium_rounded, size: 56, color: scheme.primary),
            const SizedBox(height: 14),
            Text(
              'Upgrade to Pak AI Pro',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'A faster, more capable Pak AI with room to do more every day.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scheme.outlineVariant.withOpacity(0.25)),
              ),
              child: Column(
                children: [
                  for (final b in _benefits)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Icon(b.$2, size: 20, color: scheme.primary),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              b.$1,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _UpgradeButton(scheme: scheme, theme: theme),
            const SizedBox(height: 10),
            Center(
              child: Text(
                'Pricing and payment coming soon',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpgradeButton extends StatelessWidget {
  final ColorScheme scheme;
  final ThemeData theme;
  const _UpgradeButton({required this.scheme, required this.theme});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        // No payment gateway/subscription architecture exists in this
        // project yet — this deliberately does not fake a purchase
        // success. Ready to be wired to a real checkout flow once one
        // exists.
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text('Pak AI Pro is coming soon.'),
            ),
          );
        },
        child: const Text(
          'Upgrade to Pro',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
