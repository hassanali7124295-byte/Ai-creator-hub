# CHANGE REPORT — STEP 37: Home Quick Actions Redesign (Pill Style)

## Scope

**File modified:** `lib/screens/chat_screen.dart` (only file touched)

No other file was modified. Chat bubble logic, Gemini logic, the input bar,
send button, history, drawer, settings, theme, background artwork, AppBar,
and model selector are all untouched — this step only changed the Home
empty-state's quick-action section.

## What changed

The old 2-column x 3-row **description cards** (icon + bold title + short
description paragraph, each card stretched to match its row-mate's height
via `IntrinsicHeight` + a shared `TextPainter`-measured description slot)
were **fully removed and replaced** with a compact **pill-style** layout:

- Ask a question
- Brainstorm ideas
- Write a script
- Summarize a file
- Translate text
- Explain an image

Each item is now a single rounded pill containing **icon + title only** —
no description text.

## New pill design (`_QuickActionPill`)

- **Shape:** fully rounded `StadiumBorder` (pill), not the old 18px
  rounded-rectangle card.
- **Background:** white / glass-like — `_PakHome.card` (white) at 0.94
  opacity plus a faint semi-transparent white hairline border, giving a
  soft glass edge against the app's light background without needing a
  blur filter.
- **Shadow:** soft, wide, low-opacity manual `BoxShadow` (same diffused
  approach the old cards used), softening further on press.
- **Content:** a small emerald icon in a soft emerald-tinted circle (28px),
  10px gap, then the title in Poppins 13.5/w600. Wrapped in a `Row` whose
  default `CrossAxisAlignment.center` keeps icon + title vertically
  centered inside the pill at any height. Title is `Flexible` +
  `maxLines: 1` + `TextOverflow.ellipsis` as a final safety net against
  overflow — it never actually needs to trigger at these six labels' natural
  lengths in the pill's normal padding.
- **Interaction:** same quiet `AnimatedScale` press effect (0.97) plus the
  Material ink ripple as before — no bounce, no behavior change.

## Layout: grid → `Wrap`

The old fixed 2-column grid (`Row` + `Expanded` pairs, one `IntrinsicHeight`
row per pair, three rows) is replaced with a single `Wrap(spacing: 10,
runSpacing: 10)` over all six pills. Because each pill sizes itself to its
own content (`MainAxisSize.min`) instead of being forced to `Expanded` fill
half the screen, `Wrap` naturally reflows pills left-to-right and onto as
many rows as the available width needs. This is what makes the layout
responsive on every screen size: narrow phones simply wrap onto more rows,
wider phones/tablets fit more pills per row — with no per-breakpoint logic
required and no possibility of horizontal overflow.

## Removed (no longer needed)

- `_HomeQuickAction.description` field (and its value on all six `const`
  action instances) — the pill layout has nowhere to show it.
- `_EmptyState._sharedDescriptionHeight()` — the `TextPainter`-based
  shared-height measurement that kept all six description cards the same
  height. With no description text and self-sizing pills, this
  measurement step no longer applies.
- The three `IntrinsicHeight` + `Row`/`Expanded` pairs that built the old
  2×3 grid — replaced by the `Wrap`.

Everything else in `_HomeQuickAction` (icon, label, prompt) and the
tap-to-fill-composer behavior (`onSuggestionTap` → `_applySuggestion`) is
unchanged, so tapping a pill still just fills the existing composer exactly
as before — sending itself still goes through the normal, untouched input
bar.

## Verification performed

- **Bracket balance:** verified programmatically (Python parenthesis/
  brace/bracket-matching pass substituting for the Dart SDK) — balanced,
  no mismatches.
- **Diff scope:** `diff -rq` against the Step 36 baseline confirms
  `lib/screens/chat_screen.dart` is the only source file that differs.
- **No text overflow / no clipping / no RenderFlex overflow:** pill width
  is content-driven (`MainAxisSize.min` inside a `Wrap`), so pills never
  get force-stretched into a fixed column width the way the old grid cards
  were; the title additionally carries `maxLines: 1` +
  `TextOverflow.ellipsis` as a belt-and-suspenders guard. The `Wrap`
  itself has no fixed width requirement on its children, so it cannot
  produce a `RenderFlex` overflow the way an `Expanded`-in-`Row` layout
  can if content ever grew.
- **Untouched systems check:** confirmed no remaining references to the
  removed `description` field or `_sharedDescriptionHeight`/
  `descriptionHeight` anywhere in the file; confirmed `IntrinsicHeight` is
  still present (used by the unrelated, untouched input-bar send-button
  layout) so removing it from the quick-action grid did not affect that
  other usage.

## Untouched (confirmed)

Chat bubble logic, Gemini chat service, input bar, send button, history,
drawer, settings, theme (`_PakHome` palette itself unchanged — only reused),
background artwork/`_PakOutlinePainter`, AppBar, and the "Select Model" bar
— none of these were modified.
