import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Step 56 — Pak AI Professional Credits & Monetization System.
///
/// Centralized, single source of truth for the free-tier usage-based
/// credit system. Every read/deduct/reset/reward-ad operation for
/// credits goes through this service — [ChatScreen] and [ProfileScreen]
/// only ever call into it, never touch `SharedPreferences` for credits
/// directly. Follows the same `ChangeNotifier` + `SharedPreferences`
/// pattern already used by [ThemeProvider], so it's wired into the app
/// exactly the same way (a `ChangeNotifierProvider` in `main.dart`) and
/// any widget can listen for live updates via `context.watch<CreditService>()`
/// or `Consumer<CreditService>`.
class CreditService extends ChangeNotifier {
  static const _keyRemaining = 'pak_ai_credits_remaining';
  static const _keyPeriodStart = 'pak_ai_credits_period_start_ms';
  static const _keyRewardedCount = 'pak_ai_credits_rewarded_count';

  /// Free daily allowance, per spec.
  static const int dailyLimit = 90;

  /// Credits granted per successfully-completed rewarded ad.
  static const int rewardedAdBonus = 18;

  /// Maximum number of rewarded-ad claims allowed per 24-hour period.
  static const int maxRewardedAdsPerPeriod = 3;

  static const Duration _periodLength = Duration(hours: 24);

  int _remaining = dailyLimit;
  DateTime _periodStart = DateTime.now();
  int _rewardedCount = 0;
  bool _loaded = false;

  int get remaining => _remaining;
  int get dailyTotal => dailyLimit;
  bool get isLoaded => _loaded;

  /// How many rewarded-ad claims are still available this period.
  int get rewardedClaimsRemaining =>
      (maxRewardedAdsPerPeriod - _rewardedCount).clamp(0, maxRewardedAdsPerPeriod);

  /// When the current 24-hour period resets back to [dailyLimit].
  DateTime get resetsAt => _periodStart.add(_periodLength);

  /// Time remaining until the next automatic reset. Never negative — a
  /// caller that reads this right at (or past) the boundary should treat
  /// zero as "about to reset", not schedule around a negative duration.
  Duration get timeUntilReset {
    final diff = resetsAt.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  CreditService() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final storedStartMs = prefs.getInt(_keyPeriodStart);
    _periodStart = storedStartMs != null
        ? DateTime.fromMillisecondsSinceEpoch(storedStartMs)
        : DateTime.now();
    _remaining = prefs.getInt(_keyRemaining) ?? dailyLimit;
    _rewardedCount = prefs.getInt(_keyRewardedCount) ?? 0;

    if (storedStartMs == null) {
      // First-ever launch with this feature — start a fresh period now.
      await _persist(prefs: prefs);
    }

    await _resetIfExpired(prefs: prefs);
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist({SharedPreferences? prefs}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    await p.setInt(_keyRemaining, _remaining);
    await p.setInt(_keyPeriodStart, _periodStart.millisecondsSinceEpoch);
    await p.setInt(_keyRewardedCount, _rewardedCount);
  }

  /// Automatically restores credits to [dailyLimit] and starts a new
  /// 24-hour period once the previous one has expired. Never resets just
  /// because the app was closed/reopened — only on real elapsed time,
  /// since [_periodStart] is itself persisted.
  Future<void> _resetIfExpired({SharedPreferences? prefs}) async {
    if (DateTime.now().isBefore(resetsAt)) return;
    _remaining = dailyLimit;
    _periodStart = DateTime.now();
    _rewardedCount = 0;
    await _persist(prefs: prefs);
  }

  /// Deterministic, usage-based credit cost for a single outgoing
  /// message. Deliberately NOT a fixed per-message cost, and deliberately
  /// NOT a claim of real Gemini token accounting (the app has no reliable
  /// access to that) — just a simple, predictable tiering by the size of
  /// what's actually being sent, using information already available
  /// locally (prompt length, attachment count).
  ///
  /// Kept here — not duplicated in [ChatScreen] — so there is exactly one
  /// place that defines "how much does this message cost".
  int calculateCost({required String text, int attachmentCount = 0}) {
    final length = text.trim().length;

    int cost;
    if (length <= 4) {
      cost = 1; // "Hi", "Ok" — trivial
    } else if (length <= 20) {
      cost = 2; // short question
    } else if (length <= 60) {
      cost = 4; // normal question
    } else if (length <= 150) {
      cost = 6; // normal/longer question
    } else if (length <= 400) {
      cost = 9; // long prompt
    } else if (length <= 800) {
      cost = 12; // very long prompt
    } else {
      cost = 16; // extremely long prompt
    }

    // Each attachment adds a modest, flat surcharge — attachments are
    // real additional work regardless of how little text came with them.
    cost += attachmentCount * 3;

    return cost;
  }

  /// Checks whether [remaining] can currently cover [cost].
  bool canAfford(int cost) => _remaining >= cost;

  /// The single entry point [ChatScreen] calls before every send.
  ///
  /// Applies the automatic 24h reset if due, calculates the cost from
  /// [text]/[attachmentCount], and — only if enough credits remain —
  /// deducts them immediately and returns `true`. A message is never
  /// allowed to consume more credits than the remaining balance: if the
  /// calculated cost exceeds what's left, nothing is deducted and this
  /// returns `false` so the caller can show the credit-limit UI instead
  /// of sending the request.
  Future<bool> checkAndConsume({
    required String text,
    int attachmentCount = 0,
  }) async {
    await _resetIfExpired();
    final cost = calculateCost(text: text, attachmentCount: attachmentCount);
    if (!canAfford(cost)) {
      notifyListeners();
      return false;
    }
    _remaining -= cost;
    await _persist();
    notifyListeners();
    return true;
  }

  /// Grants [rewardedAdBonus] credits after a rewarded ad's completion
  /// callback has actually confirmed the reward — never call this just
  /// because an ad was requested/started. Returns `false` (grants
  /// nothing) once [maxRewardedAdsPerPeriod] has already been claimed for
  /// the current period.
  Future<bool> grantRewardedAdCredits() async {
    await _resetIfExpired();
    if (_rewardedCount >= maxRewardedAdsPerPeriod) return false;
    _remaining += rewardedAdBonus;
    _rewardedCount += 1;
    await _persist();
    notifyListeners();
    return true;
  }
}
