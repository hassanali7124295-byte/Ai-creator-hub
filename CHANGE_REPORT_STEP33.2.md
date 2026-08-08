# CHANGE REPORT — Step 33.2: Cold-Launch Quick Action Overflow (Root-Cause Fix)

## Root Cause

The Quick Action cards use `GoogleFonts.poppins()` for their description
text. `google_fonts` fetches/loads each font file **asynchronously** the
first time it's used in an app run — the very first `build()` renders with
a fallback system font while the real Poppins font is still being
loaded/registered in the background. Once loading completes, Flutter
automatically swaps the already-painted `Text` widgets over to the real
font — with different metrics (line height / character widths) — **without
requiring any `setState`**.

Step 33.1's fix computes a single **shared description height** once per
build, using a `TextPainter` with that same Poppins `TextStyle`, so all six
cards line up. That measurement is correct — but only for whichever font
was actually available at the moment it ran:

- **Cold launch:** the `LayoutBuilder` in `_EmptyState` runs its
  `TextPainter` measurement *before* Poppins has finished loading, so the
  computed `SizedBox` height is based on **fallback-font metrics**. Moments
  later, Flutter swaps the on-screen `Text` to the real, now-loaded Poppins
  font — which needs *more* vertical space at this size/line-height than
  the fallback font did. The `SizedBox` height was never recomputed (nothing
  re-triggers `_EmptyState`'s `LayoutBuilder` just because a font finished
  loading), so the now-taller real text overflows the too-short box.
- **After returning from Chat:** by then Poppins has long since finished
  loading and is cached in memory. When `_EmptyState` is rebuilt fresh
  (it's reconstructed on every `_ChatScreenState.build()`, including the
  one triggered by navigating back to Home), **both** the `TextPainter`
  measurement **and** the actual `Text` rendering now use the *same*,
  final Poppins metrics — so they agree, and the cards render perfectly.

This is a **font-loading race condition in widget lifecycle / first-frame
timing** — not a card design or typography problem. The card layout code
itself (established in Step 33.1) is correct; it just needs to run its
measurement again once the real font is actually ready, exactly as it
already does, incidentally, on the next natural rebuild.

## Why It Never Reproduces After the First Rebuild

Once a `google_fonts` font is loaded, it stays cached for the lifetime of
the app process — every subsequent `_EmptyState` build (Chat → Home,
switching conversations, opening Settings and coming back, etc.) measures
and renders with the same already-loaded font, so the mismatch can never
recur in that app session. Only the very first build, right after cold
launch, can race the font's async load — matching exactly what was
reported.

## The Fix

Added a **one-time, self-correcting rebuild trigger** to
`_ChatScreenState.initState()` — the screen's existing lifecycle hook,
where a similar fire-and-forget async warm-up (`VoiceManager` init)
already lives:

```dart
WidgetsBinding.instance.addPostFrameCallback((_) {
  unawaited(GoogleFonts.pendingFonts().then((_) {
    if (mounted) setState(() {});
  }));
});
```

- `addPostFrameCallback` waits until *after* the first frame has built —
  so the `GoogleFonts.poppins()`/`playfairDisplay()` calls in this screen's
  `build()` have already run and registered their font loads as "pending."
- `GoogleFonts.pendingFonts()` (the package's own documented API for this
  exact situation) resolves once every font that started loading has
  finished.
- The subsequent `setState(() {})` is a single, harmless, no-op-visually
  rebuild — it doesn't change any state — but it causes `_EmptyState` to
  be reconstructed and its `LayoutBuilder`/`TextPainter` measurement to
  re-run, this time using the now-fully-loaded, final Poppins metrics —
  matching what the real `Text` widgets are already rendering.

If fonts happen to already be cached/loaded by the time this runs (e.g. on
a warm start), `pendingFonts()` resolves immediately and the extra
`setState` is unnoticeable.

## Files Modified

- **`lib/screens/chat_screen.dart`** — only `_ChatScreenState.initState()`
  was touched (23 added lines, all-new; nothing removed). This is the
  *only* file modified.

## Files Explicitly NOT Touched

- `_EmptyState`, `_QuickActionPill`, `_sharedDescriptionHeight` — **zero
  changes** since Step 33.1. Verified with a direct diff against the
  Step 33.1 baseline: the only diff in the entire file is the new
  `initState` block above.
- Typography, fonts, spacing, card size, grid, colors, shadows — untouched.
- `lib/widgets/chat_bubble.dart` — left completely untouched (not part of
  this fix; no changes needed).
- All providers, services (including Gemini), routing, settings, profile,
  history, theme, AppBar, drawer, input bar, Pak AI logo, background
  artwork — untouched.
- `pubspec.yaml` — no new dependency needed; `google_fonts` (already a
  dependency) already exposes `pendingFonts()`.

## Verification Performed

- [x] Diffed the modified `chat_screen.dart` against the Step 33.1
      baseline: confirmed the **only** change is the added block inside
      `initState()` — `_EmptyState`/`_QuickActionPill`/card code is
      byte-for-byte identical to Step 33.1.
- [x] Diffed the full project folder against the Step 33.1 baseline:
      confirmed **no file other than `chat_screen.dart`** differs.
- [x] Brace/paren balance check on the full file: 213/213 braces,
      1160/1160 parens — balanced.
- [x] Confirmed `unawaited` (from `dart:async`, already imported) and
      `WidgetsBinding` (from `flutter/material.dart`, already imported)
      require no new imports.
- [x] Traced the fix's behavior for both cold-launch (font not yet
      cached — `pendingFonts()` awaits the real load, then forces the
      exact re-measurement that was previously only happening on
      navigation) and warm-launch (font already cached —
      `pendingFonts()` resolves immediately, extra rebuild is a no-op)
      cases.

Note: as before, no Flutter/Dart SDK or network access is available in
this sandbox, so this could not be verified with a live `flutter run` /
physical cold-launch test. A local test on a real device/emulator with the
app's cache cleared (true cold launch) is recommended to confirm, but the
fix directly targets the documented, verifiable root cause.

## Baseline

This returned ZIP is the new baseline for the next step.
