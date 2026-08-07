# Step 34 — Final Premium Chat UI Polish

## Scope

Continuing from the approved Step 33 baseline. Only the four listed
issues were touched. Gemini API logic, streaming logic, history storage,
the navigation drawer, settings, theme, the Home background, Pakistan
branding, message persistence, and every other piece of routing/service
code are unchanged.

## Files Changed

- `lib/screens/chat_screen.dart` — Quick Action card padding/description
  wrapping; send button vertical anchoring; "Jump to Latest" visibility
  gap fix.
- `lib/widgets/chat_bubble.dart` — AI reply max width.

No other file was touched.

## Change 1 — Home Quick Action Cards

**File:** `lib/screens/chat_screen.dart` (`_QuickActionPill`)

Two changes, both purely about how much room the card gives its own
content — the grid, gutters, colors, and shadow are all untouched:

1. **Card height increased slightly.** The card's inner `Padding` went
   from `EdgeInsets.all(14)` to `EdgeInsets.fromLTRB(14, 16, 14, 16)` —
   2dp more breathing room top and bottom. Horizontal padding (14) is
   unchanged.
2. **The description text no longer has a line cap at all.** Step 33 had
   already fixed the two-line clip by moving to `maxLines: 3`, but that
   was still a fixed ceiling — on a narrow phone, the longest
   description ("Create scripts for videos, ads, stories and more.")
   could still tip past 3 lines and clip. `maxLines`/`overflow` were
   removed entirely, so the `Text` simply wraps to however many lines it
   needs. Since the card is already sized to its own content
   (`mainAxisSize.min` on its `Column`, with the `IntrinsicHeight`-driven
   row above it — unchanged from Step 33 — stretching both cards in a
   row to match whichever is taller), a longer description on a small
   screen just makes that row a little taller instead of ever being cut
   off. On a wide screen the same text might sit on one line; on a
   narrow one it might wrap to three — either way it's never clipped.

Font size (12.5), line height (1.25), letter spacing (-0.05), title
style, icon size, card corner radius (18), and the card's `boxShadow`
are all exactly as Step 33 left them.

## Change 2 — Input Bar Send Button Anchoring

**File:** `lib/screens/chat_screen.dart` (`_ChatInputBar`)

**The bug:** Step 33.1 had wrapped the composer `Row` in
`IntrinsicHeight` and the send button in `Align(alignment:
Alignment.center)` so the button would sit dead-center in the pill
instead of flush against the bottom — which looked right for a single
line of text. But `Align.center` centers against the row's *whole*
height, and `IntrinsicHeight` makes that height grow every time the text
field wraps to another line. So as someone typed a longer, multi-line
message, the vertical center point crept upward with it — the send
button visibly drifted up the pill instead of staying anchored to the
bottom-right corner, the opposite of ChatGPT/Claude's behavior.

**The fix:** the `IntrinsicHeight` wrapper and the `Align` wrapper around
the send button are both removed. The `Row` goes back to being a plain
`Row` with `crossAxisAlignment: CrossAxisAlignment.end` for every child —
exactly like the "+" and mic buttons already were, and exactly like the
composer was before Step 33.1. The send button's own `Padding` changed
from a symmetric `vertical: 2` to `EdgeInsets.only(left: 2, right: 2,
top: 2, bottom: 5)` — a slightly larger, fixed bottom margin that gives
it the same optically-centered look Step 33.1 was going for in the
common single-line case, but because it's now a fixed offset from the
row's bottom edge (not a fraction of the row's total height), the button
stays pinned to that exact spot no matter how many lines the text field
grows to. Multi-line text now only ever pushes the top of the pill up —
the send button (and the "+"/mic buttons, unchanged) stay put at the
bottom.

Button diameter, color, icon, `AnimatedContainer`/`AnimatedSwitcher`
animations, the Stop-button swap while streaming, and the disabled
spinner while sending are all byte-for-byte unchanged — this was a
vertical-anchoring fix only. Mic button padding/position (`Padding(
bottom: 2)` wrapping its existing 11-all inner padding) was not touched,
so its alignment is exactly as it was.

## Change 3 — Jump to Latest Visibility

**File:** `lib/screens/chat_screen.dart`

The circular button's design, its 44dp size, its fade+slide entrance,
and its scroll-to-bottom tap handler (`_jumpToLatest`) are all unchanged.
Its visibility rule is also unchanged in shape:
`visible = !_followBottom && _newContentWhilePaused` — hidden unless the
person is scrolled away from the bottom *and* something new has actually
landed below the fold.

**The bug:** `_newContentWhilePaused` was only being set to `true` when
a *successful* reply arrived — both the non-streaming (image/attachment)
success path and the streaming `flush()` already did this correctly.
But the two paths that hand back an **error** bubble instead of a normal
reply — a failed non-streaming send (`on GeminiException catch`) and a
failed stream that never received any text (`buffer.isEmpty` inside
`_streamAiReply`'s `catch`) — never set that flag. So if the person had
scrolled up to reread something earlier and the request then failed, the
error bubble was added at the bottom exactly like a normal reply, but
the "Jump to Latest" button never appeared to tell them it was there —
they'd have had to scroll down manually to discover it.

**The fix:** both of those `catch` blocks now also set
`if (!_followBottom) _newContentWhilePaused = true;` inside their
existing `setState`, matching the two success paths exactly. An error
reply now surfaces the button exactly like any other new message.

**Confirmed already-correct (untouched):**
- Tapping the button (`_jumpToLatest`) resets both flags and animates to
  the bottom, hiding it — unchanged.
- Scrolling back to the bottom manually clears `_newContentWhilePaused`
  via `_onScrollChanged` — unchanged.
- If the person scrolls away again while a stream is still delivering
  more text, the very next `flush()` re-sets the flag and the button
  reappears — this was already correct and needed no change.
- Sending a new message, regenerating, or switching conversations all go
  through `_scrollToBottom(force: true)`, which already resets both
  flags — unchanged.

## Change 4 — AI Reply Width

**File:** `lib/widgets/chat_bubble.dart`

The AI-reply `BoxConstraints.maxWidth` fraction moved from `0.89`
(Step 33) to `0.92` — inside the requested 90–92% band. The user-bubble
fraction (`0.68`) is untouched. No other property of the bubble changed
— padding, font sizes, `MarkdownStyleSheet` styling, colors, and the
copy/TTS/More-menu action row are all exactly as they were.

"Reduce unnecessary line breaks" wasn't a separate code change: Markdown
rendering itself was explicitly left untouched (per the Step 34 rules),
and a wider reply column inherently means fewer mid-sentence wraps — the
same paragraph now breaks less often simply because it has more
horizontal room per line, with no change to how the text is generated,
parsed, or styled.

## Verification

- Quick Action descriptions: no `maxLines`/`overflow` cap, so no
  description can ever clip or ellipsize on any screen width; card
  height grows slightly (via the +2/+2 padding change) and via
  `IntrinsicHeight` row-matching when a description needs more lines —
  grid (2×3), gutters (12px), colors, and shadow are all unchanged.
- Input bar: `Row` uses plain `crossAxisAlignment: CrossAxisAlignment.end`
  for all four children again; the send button's fixed
  `bottom: 5` padding keeps it pinned to the same spot near the bottom
  of the pill regardless of how many lines (1–5, the `TextField`'s
  existing `maxLines: 5` is unchanged) the message text wraps to —
  verified by inspection that nothing in the button's position depends
  on the row's total height anymore. Mic button position/behavior
  unchanged.
- Jump to Latest: same circular 44dp design, same fade+slide, same tap
  behavior; the two error paths that previously failed to surface it now
  set the same flag the two success paths already set — verified via
  diff that both `catch` blocks changed in exactly one line each.
- AI replies now use ~92% of available width; user bubble width (68%)
  unchanged. Markdown, copy, TTS, the More menu, and timestamps are
  untouched — confirmed via diff that `chat_bubble.dart`'s only change
  is the `0.89 → 0.92` constant.
- File-level diff against the Step 33 baseline confirms only
  `lib/screens/chat_screen.dart` and `lib/widgets/chat_bubble.dart` were
  modified — no other file changed. Gemini logic, streaming, history,
  drawer, settings, theme, Home background, Pakistan branding, and
  message persistence are all untouched.
