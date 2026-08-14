import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services/credit_service.dart';

/// Step 56 — the premium "Pak AI Credits" card shown on [ProfileScreen].
///
/// Purely presentational: all state lives in [CreditService], which this
/// widget listens to via `Consumer<CreditService>`. Runs on whatever
/// [ColorScheme] the caller passes in (Profile already threads its
/// emerald [ChatPalette] scheme through every section), so it matches the
/// rest of the screen automatically in both light and dark mode.
class CreditCard extends StatefulWidget {
  final ColorScheme scheme;
  const CreditCard({super.key, required this.scheme});

  @override
  State<CreditCard> createState() => _CreditCardState();
}

class _CreditCardState extends State<CreditCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // The countdown label is derived from a plain DateTime, not something
    // CreditService calls notifyListeners() for every second — a light
    // once-a-minute tick is enough to keep "Resets in Xh Ym" accurate
    // without any wasted rebuilds.
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _formatCountdown(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    if (hours <= 0 && minutes <= 0) return 'Resetting…';
    if (hours <= 0) return 'Resets in ${minutes}m';
    return 'Resets in ${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.scheme;
    final isDark = scheme.brightness == Brightness.dark;

    return Consumer<CreditService>(
      builder: (context, credits, _) {
        if (!credits.isLoaded) return const SizedBox.shrink();

        final remaining = credits.remaining;
        final total = credits.dailyTotal;
        final fraction = total == 0 ? 0.0 : (remaining / total).clamp(0.0, 1.0);

        return Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: scheme.primary.withOpacity(0.18),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: scheme.shadow.withOpacity(isDark ? 0.0 : 0.05),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Pak AI Credits',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.2,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$remaining',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                  ),
                  Text(
                    ' / $total',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                'Credits remaining',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 8,
                  backgroundColor: scheme.outlineVariant.withOpacity(0.25),
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _formatCountdown(credits.timeUntilReset),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
