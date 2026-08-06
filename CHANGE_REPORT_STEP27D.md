# Step 27D — Final Home Screen (Reference Match)

## File touched
**Only** `lib/screens/chat_screen.dart` was modified. Verified by diffing the
whole project against the original upload — it is the sole file that differs.

Nothing in Gemini/API/streaming, chat bubbles, attachments, auth, routing,
settings, profile logic, theme files, services, or providers was touched.

## What changed (Home UI only)

1. **Header** — "Pak AI" wordmark is now left-aligned right after the menu
   icon (not centered), set in a bold serif (Google Fonts Playfair Display)
   in dark emerald, matching the reference exactly. Menu icon, profile
   avatar, and their navigation are unchanged.

2. **Hero heading** — Replaced the time-of-day greeting ("Good
   Morning/Afternoon/Evening" + subtitle + tagline) with the reference's
   exact left-aligned bold serif heading: **"What can I do for you?"** The
   now-unused greeting helper was removed.

3. **Quick actions** — Rebuilt as pill-shaped buttons matching the
   screenshot precisely:
   - Row 1: **Ask a question** (alone)
   - Row 2: **Brainstorm ideas** + **Write a script** (side by side)
   - Row 3: **Summarize a file** (alone)
   - Content-sized (not stretched full-width), asymmetric "speech-bubble"
     corners (small top-left radius, fully rounded elsewhere), bare emerald
     outline icon + bold label, soft shadow, no trailing chevron.
   - Note: this exact grouping/order matches the attached screenshot, which
     differs slightly from the numbered list in the brief text (that list
     ordered Summarize before Write a script). Per the brief's own
     instruction that "the screenshot is the specification, not
     inspiration," the screenshot was followed.
   - Row 2 uses a `Wrap` (not a `Row`) and each pill's label is wrapped in
     `Flexible` + ellipsis, so nothing can overflow at 320–412dp.

4. **Background map** — Same decorative outline painter, opacity nudged
   from 0.025 → 0.035 for closer visual parity with the reference while
   staying "very light" and never overlapping text.

5. **API key banner** — Restyled only (same `_hasApiKey` condition, same
   `onSetUp` callback): now a small rounded card with a soft emerald tint,
   thin border, and tighter padding instead of the old edge-to-edge strip.

6. **Select Model pill** — Fill darkened slightly and the thin border
   removed for a cleaner, more "premium" solid-chip look closer to the
   reference; same tap target, emoji, label, and behavior.

7. **Message input bar** — Untouched (already matches the reference).

## Colors used
Only the palette specified: background `#F8F8F5`, primary/emerald
`#0B7A57`, white cards, border `#E5E7EB`, text `#1A1A1A`, secondary text
`#6B7280`.

## Fonts
Poppins (already a dependency) for all body/label text; Playfair Display
(also via the existing `google_fonts` package — no pubspec change needed)
for the "Pak AI" wordmark and the hero heading only, matching the
screenshot's serif logo/heading treatment.

## Known intentional deviation
The reference screenshot's top-right header icon is a square
pencil/compose glyph, while the app currently uses the existing round
`ProfileAvatarButton` (defined in `widgets/pak_home_widgets.dart`, outside
the allowed file). Per the brief's explicit instruction to keep "Existing
profile avatar. Existing navigation. Keep functionality unchanged" and to
touch no file other than `chat_screen.dart`, this element was left as-is.

## Verified
- Only `lib/screens/chat_screen.dart` differs from the original zip.
- No RenderFlex-overflow-prone constructs remain (side-by-side pills use
  `Wrap`; all pill labels are `Flexible` + ellipsis).
- No changes to Gemini/streaming/attachments/auth/routing/settings/
  profile/theme/services/providers.
