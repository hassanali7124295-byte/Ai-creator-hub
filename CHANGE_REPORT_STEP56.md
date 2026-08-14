# CHANGE_REPORT_STEP56.md — Pak AI Professional Credits & Monetization System

## Files changed

**New files (4):**
- `lib/core/services/credit_service.dart` — centralized `CreditService` (ChangeNotifier)
- `lib/widgets/credit_card.dart` — Profile "Pak AI Credits" card
- `lib/widgets/credit_limit_sheet.dart` — bottom sheet shown when credits run out
- `lib/screens/upgrade_plan_screen.dart` — Upgrade Plan UI (no payment processing)

**Existing files modified (3, minimal edits each):**
- `lib/main.dart` — added one `ChangeNotifierProvider(create: (_) => CreditService())` to the existing `MultiProvider` list + one import. Nothing else touched.
- `lib/screens/profile_screen.dart` — one import + one `CreditCard(scheme: scheme)` inserted between the header card and the "Account" section. Nothing else touched.
- `lib/screens/chat_screen.dart` — two imports + one `checkAndConsume(...)` block inserted at the very top of `_sendMessage()`, before attachment processing/UI locking. No other line in this 4000+ line file was touched (verified by diff).

No PDF, voice-note, AI-mode, chat composer, header/logo, or Gemini-API-key files were changed. Confirmed via `diff -rq` against the Step55 baseline — exactly these 3 existing files differ, plus the 4 new ones.

## Architecture

`CreditService` (in `lib/core/services/credit_service.dart`) is the single centralized service — no credit logic is duplicated in `ChatScreen` or `ProfileScreen`. Responsibilities:
- current `remaining` credits, `dailyTotal` (90), `resetsAt` / `timeUntilReset`
- `calculateCost({text, attachmentCount})` — deterministic usage-based tiering
- `checkAndConsume({text, attachmentCount})` — the one entry point `ChatScreen` calls
- `grantRewardedAdCredits()` — rewarded-ad grant path, capped at 3/period
- automatic 24h reset, persisted via the project's existing `shared_preferences` (same pattern as `ThemeProvider`)

Wired into the app the same way `ThemeProvider`/`ConversationProvider` already are: one `ChangeNotifierProvider` in `main.dart`.

## Daily credit amount

**90 credits / 24-hour period**, per spec. Stored as a persisted period-start timestamp (`SharedPreferences`), not a fixed clock time — the period only rolls over once 24 real hours have elapsed since that timestamp, so closing/reopening the app never resets it early.

## Usage-based cost calculation

`CreditService.calculateCost()` tiers by trimmed prompt character length, plus a flat per-attachment surcharge:

| Length (chars)   | Cost |
|-------------------|------|
| ≤ 4 ("Hi", "Ok")   | 1    |
| ≤ 20 (short)       | 2    |
| ≤ 60 (normal)      | 4    |
| ≤ 150              | 6    |
| ≤ 400 (long)       | 9    |
| ≤ 800 (very long)  | 12   |
| > 800              | 16   |

`+3` per attachment. This is a simple, predictable local heuristic — **not** a claim of real Gemini token accounting (the app has no reliable access to that), as required by the spec. A message can never consume more than the remaining balance: `checkAndConsume` blocks (deducts nothing) if the calculated cost exceeds what's left.

## Rewarded ad behavior

`pubspec.yaml` has **no AdMob dependency** (`google_mobile_ads` is not present — confirmed by inspection). Per spec, no fake ad integration or fake credits were added. What was built instead:
- `CreditService.grantRewardedAdCredits()` — the real grant method, ready to be called from a future `RewardedAd.onUserEarnedReward` callback. Enforces the 3-per-period cap and +18 credits.
- The credit-limit sheet's "Watch Ad" tile shows live "`N` rewards remaining today" state from `CreditService.rewardedClaimsRemaining`, disables itself at 0, but currently only shows a "coming soon" message on tap — it does **not** call `grantRewardedAdCredits()`, since there is no real ad completion callback to gate it on.

**3-ad daily limit:** enforced in `CreditService` via a persisted `rewardedCount`, reset alongside the main credit reset every 24h.

## Profile UI changes

Added `CreditCard` between the existing profile header and the "Account" section — remaining/total, a progress bar, and a live "Resets in Xh Ym" countdown (self-updating every minute). Uses the existing emerald `ChatPalette` scheme passed in from `ProfileScreen`, existing card radius/spacing/shadow conventions, dark/light supported automatically via `ColorScheme`. No existing Profile UI was replaced or reordered otherwise.

## Upgrade Plan UI

New `UpgradePlanScreen` — benefits list (More daily credits / Higher usage limits / Fewer restrictions / Premium AI experience), an "Upgrade to Pro" button that shows a "coming soon" message. **No fake payment success** — no payment gateway exists in this project, so none was invented.

## Confirmations

- ✅ **Chat composer usage preview was NOT added** — grepped `chat_screen.dart` for all credit-related lines; only the two new imports and the `checkAndConsume` block exist. No "≈ N credits" or similar text anywhere near the composer.
- ✅ **PDF functionality untouched** — no PDF-related file appears in the diff.
- ✅ **PK Model / Voice Note untouched** — `_sendVoiceMessage`/`_requestVoiceAiReply` and all AI-mode files are unmodified; the credit check only wraps the main text/attachment `_sendMessage()` path, per the explicit "Do NOT modify voice-note functionality" instruction. (Flagged as a deliberate scope decision below.)
- ✅ Existing Gemini API key handling, `modeInstruction`, streaming, and message rendering are all unchanged — the credit check runs entirely before any of that code executes and returns early on insufficient credits.

## Deliberate scope note

The credit check wraps `_sendMessage()` only (the dominant send path — plain text, attachments, smart-capability routing, and document follow-up all flow through it). It does **not** wrap `_sendVoiceMessage()`/`_requestVoiceAiReply()` (the separate voice-message-to-Gemini path), since the brief explicitly says not to modify voice-note functionality and wrapping it would have required touching that code. This means voice messages currently bypass the credit system — flagging this as a known gap for a future step if voice messages should also consume credits.

## Verification

1. ✅ Free user starts with 90 credits — `CreditService._remaining` initializes to `dailyLimit` (90) on first load.
2. ✅ "Hi" (2 chars) → `calculateCost` returns 1.
3. ✅ A normal message (e.g. 60–150 chars) → 4–6, more than "Hi".
4. ✅ A longer message (400–800+ chars) → 9–16, more than a short message.
5. ✅ Insufficient credits → `checkAndConsume` returns `false` before any Gemini call; `_sendMessage` returns immediately after showing the sheet.
6. ✅ Credits reset after 24h — `_resetIfExpired()` compares `DateTime.now()` against the persisted `resetsAt`, not app-open events.
7. ✅ Rewarded ad grants +18 only via `grantRewardedAdCredits()`, which is not currently called from the UI (no real completion callback exists) — confirmed no path grants credits on tap alone.
8. ✅ Max rewarded claims = 3/period — enforced in `grantRewardedAdCredits()`.
9. ✅ Chat composer has no usage-preview indicator — confirmed via grep above.
10–15: Not independently re-verifiable in this environment (no local Flutter/Android SDK — same limitation as every prior step in this project). Verification here is structural: `diff -rq` against the Step55 baseline (confirms only the 3 listed files changed) and per-file paren/brace balance checks (confirmed balanced on all 7 touched/new files).

## Flutter/Dart analysis

**Not run — Flutter/Dart are unavailable in this environment** (confirmed: `flutter`/`dart` not found on PATH), same as every prior step in this project. `git diff --check`, `flutter analyze`, and `dart format` were not executed; this is reported plainly rather than claimed. Real verification will happen via the project's existing GitHub Actions CI on push, per the established workflow.

## Not done (per instructions)

- Not committed, not pushed, no ZIP created automatically — this report and the working files are left for review first.
