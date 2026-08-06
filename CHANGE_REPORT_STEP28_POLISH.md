# Step 28 — Polish-Only Follow-up (no structural changes)

## Files modified
**Only** `lib/screens/chat_screen.dart`. No new widgets, no new layout, no
structural changes — verified by diffing against the original project;
only this one file differs.

## What this pass changed (visual refinement only)
The existing Step 28 layout, widget tree, and structure are untouched.
Only these value-level tweaks were made, all within the same widgets:

1. **Quick-action pills** (`_QuickActionPillState`)
   - Replaced `Material`'s default directional elevation shadow with a
     soft, wide, low-opacity manual `BoxShadow` (blur 18 / offset 0,5 at
     rest, blur 10 / offset unchanged when pressed) — reads as a far more
     diffused, premium card shadow.
   - Label weight bumped from `w600` → `w700` with a touch of letter
     spacing (-0.1) for a bolder match to the reference.
   - Icon size nudged from 22 → 21 for slightly better proportion against
     the bolder label.

2. **Select Model pill** (`_ModePillState`)
   - Same soft manual `BoxShadow` treatment (blur 12 / offset 0,3) instead
     of `Material` elevation, for a consistent premium feel across the
     Home controls. Tap target, emoji, label, and behavior unchanged.

3. **API key banner** (`_ApiKeyBanner`)
   - Added the same subtle soft shadow for visual consistency with the
     other Home surfaces. Same condition, same `onSetUp` callback, same
     copy.

## What remained untouched
- Layout structure: header, hero heading, the 1 / 2-side-by-side / 1 pill
  grouping, spacing rhythm (24 horizontal, the existing vertical gaps),
  background map, message input bar — all identical to the prior Step 28
  build.
- Gemini/API/streaming, attachments, chat logic, message sending, routing,
  drawer, history, settings, profile logic, providers, services, theme
  files — none touched.
- No new widget classes were introduced; only decoration/style values on
  the existing private widgets already in this file.

## Verified
- Brace/paren/bracket counts balanced across the whole file.
- Only `lib/screens/chat_screen.dart` differs from the original project.
