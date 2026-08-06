# Step 29 — Final Premium UI, Approved-Mockup Match — Change Report

This revision replaces the first Step 29 attempt, which was **not approved**.
The first attempt reused the old compact icon+label pill from Step 27/28 and
only reordered/regrouped it — it did not actually match the approved
mockup image, which shows a richer card (icon + bold title + description)
in a plain, uniformly-rounded 2×3 grid. This revision was built by
measuring the approved mockup image directly (pixel-sampling card edges,
padding, icon size, and row heights) and rendering an offline proportion
check against those measurements before writing the final Flutter code —
see "Verification method" below.

## File modified
**Only** `lib/screens/chat_screen.dart` was touched — verified with a full
recursive diff against the original project; every other file is
byte-identical. No new widgets or files were created. No Gemini/streaming/
provider/service/routing/profile/settings/drawer/history/theme code was
touched.

## What was wrong with the first attempt
- Quick-action cards showed only an icon + one-line label — the mockup's
  cards each also carry a short gray description line (e.g. "Get clear
  answers to anything you want to know.").
- Cards used the old asymmetric "speech-bubble" corner radius (small
  top-left corner) — the mockup's cards have plain, uniformly rounded
  corners on all four sides.
- Cards had a visible thin border — the mockup's cards have no border, just
  a soft shadow lifting them off the background.
- Cards were fixed at a thin 58dp pill height — the mockup's cards are
  taller, sized to fit icon + title + description comfortably.

## What changed in this revision

### 1. `_HomeQuickAction` gained a `description` field
Each of the six entries now carries the exact description text shown in
the mockup:
- **Ask a question** — "Get clear answers to anything you want to know."
- **Brainstorm ideas** — "Generate creative ideas and solutions."
- **Summarize a file** — "Upload a file and get key points instantly."
- **Write a script** — "Create scripts for videos, ads, stories and more."
- **Translate text** — "Translate into any language instantly."
- **Explain an image** — "Upload an image and get detailed explanation."

Icon choices were also matched to the mockup's glyphs: "Write a script"
now uses a plain pen/edit icon (`Icons.edit_outlined`, was a note+pencil
icon) and "Translate text" now uses a globe icon (`Icons.public`, was a
translate "A文" icon) — both to match the icon shapes actually drawn in
the mockup's icon key.

### 2. Quick-action cards rebuilt to match the mockup's card design
`_QuickActionPill` (kept the same class name to avoid creating a new
widget/file) now renders, top to bottom inside 14dp padding:
- a bare emerald outline icon (22dp),
- the bold dark title,
- the gray description (wraps to 2–3 lines as needed).

Visual treatment changes to match the mockup exactly:
- Corner radius is now uniform on all four corners (18dp) — no more
  asymmetric "speech bubble" notch.
- The visible border was removed — the card is now defined purely by its
  soft shadow (7% black, 16px blur, matching the mockup's gentle lift),
  same as a plain elevated white card.
- The card is no longer a fixed height — it sizes to its own content
  (icon + title + wrapped description).

### 3. Grid layout: 2 columns × 3 rows, in the mockup's exact order
Row 1: Ask a question · Brainstorm ideas
Row 2: Summarize a file · Write a script
Row 3: Translate text · Explain an image

Each row is wrapped in `IntrinsicHeight` with `CrossAxisAlignment.stretch`
so the two cards in a row always match each other's height (whichever has
the longer description) — matching the mockup, where every row's pair of
cards lines up evenly — while different rows are free to have different
heights based on their own content, rather than forcing all six cards to
one arbitrary fixed height. Column gutter is 12dp, row spacing is 12dp,
both measured off the mockup image.

### 4. Heading-to-grid spacing tightened
The gap between the "What can I help you with today?" heading (text
unchanged, exactly as approved) and the first card row was adjusted from
28dp to 32dp to match the proportion measured in the mockup image.

### 5. Color correction (carried over, unchanged from the prior revision)
`_PakHome.text` is `#111827`, matching the mockup's color spec exactly.

## Verification method
Since this sandbox has no Flutter/Android toolchain or emulator, a true
on-device screenshot isn't possible here. Verification was done in two
passes:

1. **Measurement pass** — the approved mockup image was measured directly
   (card edges, icon size, padding, and row heights located via
   pixel-brightness sampling with Python/Pillow) and those measurements
   drove the Flutter constants written into `_QuickActionPill` and
   `_EmptyState` (24dp outer padding, 12dp column/row gutters, 14dp card
   padding, 22dp icons, 18dp corner radius, 14.5/12sp title/description).
2. **Render-and-compare pass** — a full offline proxy of the resulting
   Home Screen (header, heading, all six cards with real copy, input bar)
   was rendered at the mockup's exact scale using those same values and
   compared side-by-side against the approved mockup. Grid proportions,
   text wrapping, row heights, and spacing matched closely. Two things in
   that proxy render are stand-ins only, not representative of the real
   app: the heading is drawn in Poppins Bold because Playfair Display
   isn't installed in this sandbox (the actual code still calls
   `GoogleFonts.playfairDisplay`, confirmed by inspecting the source), and
   the six icons are hand-drawn approximations of their shapes (the actual
   code still uses the real Material glyphs — `chat_bubble_outline_rounded`,
   `lightbulb_outline_rounded`, `description_outlined`, `edit_outlined`,
   `public`, `image_outlined`).

This is the closest verification achievable without a device/emulator in
this environment. A final look on an actual device/simulator is still
worthwhile once built.

## Explicitly NOT changed
- Heading text — exactly as approved: "What can I help you with today?"
- The Pak AI wordmark, AppBar behavior (always shows "Pak AI", never a
  conversation title), Select Model pill, and input bar — all unchanged
  from the prior approved state; none of this revision's complaints
  concerned them.
- Message bubble rendering (`lib/widgets/chat_bubble.dart`) and the chat
  theme (`lib/core/theme/chat_palette.dart`) — not modified, per the rule
  that only `chat_screen.dart` may change.
- All Gemini/streaming/provider/service/routing/profile/settings/drawer/
  history logic — untouched, same files, same behavior. Quick-action taps
  still only fill the composer via `_applySuggestion`; sending still goes
  through the same unmodified pipeline.

## Confirmation
Only `lib/screens/chat_screen.dart` was modified. Verified via a recursive
diff against the original project — every other file is byte-for-byte
identical.
