# STEP 36 — Root-Cause Debug: Cold-Launch Quick Action Overflow

## Investigation

The Step 33.2/35 fix called `GoogleFonts.pendingFonts()` from a
`WidgetsBinding.instance.addPostFrameCallback` registered inside
`_ChatScreenState.initState()`. Tracing the actual widget lifecycle
showed why that never fixed anything:

- `initState()` calls `_loadHistory()`, which is `async` and does not
  block the first frame. It only flips `_isLoadingHistory` to `false`
  (via its own later `setState`) *after* `await provider.init()`
  resolves.
- `build()` renders `CircularProgressIndicator()` while
  `_isLoadingHistory` is `true` (`chat_screen.dart:1374`), so on cold
  launch the **first frame never builds `_EmptyState` at all**.
- `_EmptyState` — and therefore `_sharedDescriptionHeight()`'s
  `TextPainter`, which measures the Quick Action card descriptions
  using `GoogleFonts.poppins(...)` (`chat_screen.dart:2141`) — is only
  ever constructed for the first time once `_isLoadingHistory` becomes
  `false`.
- The only font requested on that very first frame is **Playfair
  Display**, from the permanent AppBar title (`chat_screen.dart:1326-1328`),
  which uses `GoogleFonts.playfairDisplay(...)` unconditionally. Poppins
  is not requested anywhere yet.

So the Step 33.2 `pendingFonts()` call — firing one frame after
`initState`, i.e. before `_loadHistory()` has resolved — only ever had
Playfair Display "in flight" to await. **Poppins was never in the
pending set it awaited**, because nothing had asked for Poppins yet.
That `pendingFonts()` future resolved (based on Playfair alone) well
before Poppins was even requested, so its corrective `setState()` fired
too early to help.

The *actual* first request for Poppins happens later, inside
`_EmptyState.build()` (and its `_sharedDescriptionHeight` TextPainter),
once `_isLoadingHistory` flips to `false`. At that exact synchronous
moment, Poppins has not finished downloading/registering with the
engine yet, so:
- The TextPainter measurement in `_sharedDescriptionHeight` runs against
  **fallback-font metrics** (shorter than real Poppins), producing a
  `descriptionHeight` that is too small.
- The visible `Text` widgets briefly use the same fallback font too, but
  nothing re-triggers a rebuild once the real Poppins font finishes
  loading a moment later — so the too-small measured height sticks,
  and the now-real-font description text overflows it.

When the person opens Chat and returns Home, `_EmptyState` rebuilds
again (new conversation state / `AnimatedSwitcher` child swap). By then
Poppins has long since finished loading and is cached in GoogleFonts'
loaded-font registry, so this later `_sharedDescriptionHeight()` call
measures against the real font from the start — correct height, no
overflow. A full app restart resets that in-memory loaded-font state,
so the same race reproduces every cold launch.

**First value that differs (as requested):** the `descriptionHeight`
returned by `_sharedDescriptionHeight()`'s `TextPainter.layout()` on
the very first `_EmptyState` build — smaller on cold launch (fallback
font metrics) than after returning from Chat (real Poppins metrics).
Screen width, card width, and available description width are
identical in both cases; only the font backing the measurement differs.

## Root Cause

`GoogleFonts.pendingFonts()` was being awaited from the wrong place in
the lifecycle — before the widget that actually requests the Poppins
font (`_EmptyState`) had ever been built, so it tracked the wrong
font's load and resolved too early. This was not a font-loading problem
in general; it was a **mistimed corrective rebuild**.

## Fix

Removed the mistimed `initState()` post-frame `pendingFonts()` call.
Added the corrected version at the end of `_loadHistory()`, right after
the `setState` that flips `_isLoadingHistory` to `false` — i.e. after
the frame in which `_EmptyState` (and its Poppins request) has actually
been built, and only when the conversation is empty (the only case
`_EmptyState`/Quick Actions render at all):

```dart
if (_messages.isEmpty) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(GoogleFonts.pendingFonts().then((_) {
      if (mounted) setState(() {});
    }));
  });
}
```

This now awaits the real, in-flight Poppins load and performs exactly
one corrective `setState()` once it resolves — forcing `_EmptyState` to
rebuild and re-measure `_sharedDescriptionHeight()` with the real font
metrics. This is the same natural recompute that already happens (and
fixes the layout) the first time someone navigates to Chat and back —
just triggered proactively on cold launch instead of waiting for that
navigation.

No font size, `maxLines`, ellipsis, fixed heights, colors, spacing,
radius, shadows, icons, or card layout were touched.

## Files Changed

- `lib/screens/chat_screen.dart` — only file changed:
  - Removed the mistimed `pendingFonts()` post-frame call from
    `initState()`.
  - Added the correctly-timed `pendingFonts()` post-frame call at the
    end of `_loadHistory()`, gated on `_messages.isEmpty`.

No other file was touched. `lib/widgets/chat_bubble.dart` is
byte-identical to the supplied Step35 baseline (confirmed via `diff`).
No provider/service files were modified — the investigation confirmed
they were not the cause.

## Verification (static/manual — no local Flutter/Android SDK available)

- Traced the lifecycle: confirmed `_EmptyState`/Poppins is only ever
  first requested after `_isLoadingHistory` becomes `false`, not in
  `initState`.
- Confirmed the new `pendingFonts()` call is placed after that point,
  so it will actually track the Poppins load in flight.
- Confirmed via `diff -rq` against the Step35 baseline that the only
  file that differs anywhere in the project is
  `lib/screens/chat_screen.dart`.
- Confirmed `lib/widgets/chat_bubble.dart` is byte-identical to the
  Step35 baseline.
- Confirmed brace/paren balance in the edited file (214/214, 1165/1165)
  as a basic structural sanity check.
- All six Quick Action cards, their grid layout, spacing, colors,
  radius, shadows, and icons are untouched — only the timing of the
  corrective rebuild changed.
- Real on-device/CI build verification still requires the GitHub
  Actions pipeline, as with all prior steps (no local Flutter/Android
  SDK in this environment).
