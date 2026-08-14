import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/services/credit_service.dart';
import '../core/theme/chat_palette.dart';
import '../screens/upgrade_plan_screen.dart';

/// Step 56 — shown from [ChatScreen] whenever a message's calculated
/// credit cost would exceed the user's remaining balance. Deliberately a
/// calm, contained bottom sheet — never a full-screen interstitial — per
/// spec ("Do NOT use an aggressive full-screen advertisement").
Future<void> showCreditLimitSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => const _CreditLimitSheetContent(),
  );
}

class _CreditLimitSheetContent extends StatelessWidget {
  const _CreditLimitSheetContent();

  @override
  Widget build(BuildContext context) {
    final theme = ChatPalette.themeFor(context);
    final scheme = theme.colorScheme;

    return Theme(
      data: theme,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Text(
                'Your free credits are used up',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Credits reset automatically',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _WatchAdTile(scheme: scheme, theme: theme),
              const SizedBox(height: 12),
              _UpgradePlanTile(scheme: scheme, theme: theme),
            ],
          ),
        ),
      ),
    );
  }
}

class _WatchAdTile extends StatelessWidget {
  final ColorScheme scheme;
  final ThemeData theme;
  const _WatchAdTile({required this.scheme, required this.theme});

  @override
  Widget build(BuildContext context) {
    final credits = context.watch<CreditService>();
    final claimsLeft = credits.rewardedClaimsRemaining;
    final exhausted = claimsLeft <= 0;

    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: exhausted ? null : () => _handleWatchAd(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.14),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text('🎬', style: const TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Watch Ad',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      exhausted
                          ? 'No rewards left today'
                          : '$claimsLeft reward${claimsLeft == 1 ? '' : 's'} remaining today',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '+${CreditService.rewardedAdBonus}',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: exhausted
                      ? scheme.onSurfaceVariant.withOpacity(0.5)
                      : scheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleWatchAd(BuildContext context) {
    // Step 56: this project has no AdMob dependency configured yet (see
    // pubspec.yaml — no google_mobile_ads). Per spec, no fake ad flow or
    // fake credits are invented here. The state/UI architecture
    // (CreditService.grantRewardedAdCredits, the claims-remaining tile
    // above) is ready to wire to a real RewardedAd's `onUserEarnedReward`
    // callback the moment AdMob is added — that call should be the only
    // thing this handler needs to change to. Until then, tapping this
    // tile clearly communicates that ad integration is pending rather
    // than silently doing nothing or granting credits it didn't earn.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Rewarded ads are coming soon.'),
      ),
    );
  }
}

class _UpgradePlanTile extends StatelessWidget {
  final ColorScheme scheme;
  final ThemeData theme;
  const _UpgradePlanTile({required this.scheme, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: scheme.primary.withOpacity(0.10),
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const UpgradePlanScreen()),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.primary.withOpacity(0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.workspace_premium_rounded,
                  size: 20,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  'Upgrade Plan',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
