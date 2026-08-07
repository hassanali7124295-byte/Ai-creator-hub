# CHANGE REPORT — Step 33.2: Quick Action Cards Fix (Single Issue Only)

## Scope

Exactly one issue, exactly one file:

- **Problem:** on some devices/screen widths, a Quick Action card's
  description text could still get clipped (`TextOverflow.ellipsis` after
  3 lines) or, in principle, run past its card if a description ever
  needed a 4th line.
- **File touched:** `lib/screens/chat_screen.dart` — nothing else.

No other screen, widget, service, or provider was opened for editing.
`lib/widgets/pak_home_widgets.dart` (a different, unrelated
"quick action chips" component used elsewhere) was inspected but is
**not** part of the Home Screen's 6-card grid and was **not** modified.

## Root Cause

Each card's description `Text` was capped with:

```dart
maxLines: 3,
overflow: TextOverflow.ellipsis,
```

`IntrinsicHeight` only matched a card's height to its **row-mate** (the
other card beside it), not to the other two rows. Combined with a hard
3-line cap, a long description on a narrow device could still need a
4th line — which was silently truncated with `…` instead of ever
overflowing visibly, but it violated the "no ellipsis / always fully
visible" requirement. It also meant the three rows were free to end up
at different heights from each other (only pairs within a row were
forced equal).

## Fix

No redesign. Grid, spacing, shadows, colors, border radius, icon sizes,
and title typography are all untouched. Only the description slot's
sizing logic changed:

1. Added a small measurement helper
   (`_measureMaxDescriptionHeight` + `_quickActionDescriptionStyle`)
   that uses a `TextPainter` to measure, at the card's *actual* text
   width for the current screen (and the user's system text-scale
   factor, for accessibility), how tall the **longest** of all six
   descriptions needs to be to render in full with no truncation.
2. `_EmptyState` now wraps the grid in a `LayoutBuilder`, computes that
   one shared height once per build (from the real available width —
   responsive to any screen size), and passes it to every
   `_QuickActionPill` as `descriptionHeight`.
3. `_QuickActionPill` renders its description inside
   `SizedBox(height: descriptionHeight, child: Text(...))` instead of
   `maxLines: 3` / `TextOverflow.ellipsis`. Because the height is
   derived from the actual longest description at the actual card
   width, the text can never need more space than it's given — so it
   never clips, never overflows, and never needs an ellipsis.

### Why this also satisfies "equal height for all six cards"

Icon size, spacing, and title style are identical across all six cards
and unchanged. Since every card now also gets the *same* fixed
description-slot height (the one shared, measured value), all six
cards resolve to the exact same total height — not just the two cards
within a row, but all three rows against each other. This holds at any
screen width or system font size because the shared height is
recomputed from live layout constraints, not a hardcoded guess.

## What Was Deliberately Left Alone

- Chat screen, input bar, send button, Jump to Latest, AI bubbles,
  typing indicator — untouched.
- Gemini service, providers, history, drawer, settings, theme —
  untouched.
- Pakistan background, hero heading, API banner, Select Model pill,
  routing — untouched.
- Card visuals: radius (18), shadow, background color, border,
  padding (14), icon size (22), title font/size/weight — all
  unchanged.
- Grid layout: 2-column × 3-row structure, 12px row/column gaps,
  `IntrinsicHeight` + stretched row children — all unchanged (kept as
  a belt-and-suspenders match within each row; the new shared height
  is what makes all three rows match each other too).

## Verification

- All six cards render with their full description text, on narrow
  and wide screen widths alike — no line is ever cut off and no `…`
  ever appears.
- No `RenderFlex overflow` — the description's `SizedBox` height is
  always ≥ the text's actual required height at that width (measured
  directly from the same style/width used at render time, plus a
  2px rounding buffer).
- All six cards are the same height, on any screen size.
- No other screen's UI, spacing, or behavior changed — confirmed by
  isolating every edit to `lib/screens/chat_screen.dart`, and by
  checking no other file references the modified symbols.

## Modified Files

- `lib/screens/chat_screen.dart` (only)

## Note

No changes outside the Quick Action Cards widgets were required — the
fix was fully containable within `_EmptyState` and `_QuickActionPill`
in `chat_screen.dart`.
