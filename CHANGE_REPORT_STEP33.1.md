# Step 32.1 — Final Chat Polish (Message Alignment + Live Date Fix)

## Scope

Only the two requested fixes were made. Home Screen, hero heading,
quick action cards, API banner, Pak AI logo, background artwork,
AppBar, theme colors, chat bubble spacing/radius/colors, Gemini
streaming architecture, providers, routing, settings, drawer,
history, profile, Markdown rendering, TTS, copy actions, and the
message composer's layout are all unchanged.

## Files Changed

- `lib/screens/chat_screen.dart` — send button vertical alignment only.
- `lib/core/services/gemini_service.dart` — live date/time grounding
  in the system instruction only.

`lib/widgets/chat_bubble.dart` was **not touched** — confirmed
byte-identical to the Step 32 delivery.

No other files were modified.

## Change 1 — Perfect Send Button Alignment

**Problem:** the composer `Row` uses
`crossAxisAlignment: CrossAxisAlignment.end` (needed so the "+" and
mic buttons, and the send button, stay pinned near the bottom as the
text field grows across multiple lines). With a single line of text,
this left the 34dp send button flush against the very bottom of the
52dp-tall pill — all the empty space sat above it, none below, so it
visually read as "sitting lower than center."

**Fix (isolated to the send button only):**

1. The `Row` is now wrapped in `IntrinsicHeight`. This does not
   change the row's height in any way — it was already sizing itself
   to its tallest child (the text field) — it simply gives that
   height a concrete, finite value that a child can center itself
   against.
2. Only the send button's existing `Padding` (the outermost widget of
   that subtree) is wrapped in `Align(alignment: Alignment.center,
   widthFactor: 1.0, ...)`. `widthFactor: 1.0` keeps `Align`
   shrink-wrapped to the button's own width so it claims zero extra
   horizontal space — this is a vertical-only fix.

**Everything inside the send button subtree is byte-for-byte
unchanged:** `AnimatedContainer` decoration/color/shape, `Material`/
`InkWell` tap handling, the inner `Padding(all: 8)`, the
`AnimatedSwitcher` transition, the icon/spinner/stop-square sizes —
none of it was touched. The `Row`'s `crossAxisAlignment: .end` is
also unchanged, so the "+" button, the mic button, and the text
field all keep their exact existing position — only the send button
moved, and only vertically.

**Result:** the send button now sits centered in the pill (matching
ChatGPT/Claude), diameter and every other property unchanged, and
the composer's own padding/margins are untouched, so there's no
layout shift.

## Change 2 — Current Date / Time Bug

**Problem:** the app's system instruction (sent to Gemini on every
request, in `gemini_service.dart`) was a plain `static const String`
with no notion of the real current date. When asked things like "aaj
date kya hai" or "what's today's date," Gemini had nothing to ground
its answer in except its own training data, so it would guess a
stale date (e.g. "19 May 2024") — there was no literal hardcoded date
string anywhere in the app's own code; the bug was the *absence* of
live date grounding.

**Fix:** `_systemInstruction` is now a `static String get` (was
`static const String`) that rebuilds itself, on every single call,
via a new `_currentDateTimeLine()` helper. That helper reads
`DateTime.now()` — the device's live local clock — fresh each time,
formats it (e.g. `"Friday, 07 August 2026, 14:35"`), and folds it
into a new "Current date and time" section appended to the existing
system prompt. That section explicitly instructs the model: whenever
the user asks about today's date, the current day/month/year, or the
current time — in any language/phrasing — answer using that real,
live value, and never fall back to its own training data.

Both request paths (`sendMessage`'s single-shot call and
`sendMessageStream`'s streaming call) already referenced
`_systemInstruction` by name, so converting it to a getter means both
pick up the live value automatically — no other line in either method
needed to change, and `sendMessageWithImages` (which delegates to
`sendMessage` for the no-image case) is covered the same way.

- No hardcoded date remains anywhere in the prompt.
- Nothing is cached — the date/time string is recomputed from
  `DateTime.now()` on every request, so it's correct today and will
  still be correct on any future day without another code change.
- The request/response handling, auth, endpoint URL, model name,
  history handling, attachment handling, and streaming/SSE parsing
  are all completely untouched — only the contents of the system
  prompt string changed.

## Verification

- `lib/widgets/chat_bubble.dart`: 0-byte diff vs. the Step 32
  delivery — untouched.
- `lib/screens/chat_screen.dart`: diff is confined to the
  `IntrinsicHeight` wrapper around the composer `Row` and the `Align`
  wrapper around the send button's existing `Padding` — no other line
  changed.
- `lib/core/services/gemini_service.dart`: diff is confined to
  turning `_systemInstruction` into a getter, appending the new
  "Current date and time" section, and adding the small
  `_currentDateTimeLine()` / weekday / month name helpers — the HTTP
  request building, streaming logic, and every other method are
  unchanged.
- Send button: same 34dp diameter, same icon size/color, same
  circle shape, same `AnimatedContainer`/`AnimatedSwitcher`
  animations, same tap targets for Send/Stop — only recentered
  vertically.
- Input bar's own outer padding (`EdgeInsets.fromLTRB(12, 8, 12,
  12)`) and pill `minHeight: 52` are unchanged — no layout shift.
- "+" button and mic button positions unchanged (still end-aligned,
  as before).
- Date/time answers now always come from `DateTime.now()`, refreshed
  on every request — never a fixed or cached string.
- Existing Gemini conversation flow (history, streaming, image
  batching, mode instructions) preserved exactly.
- No other UI changed: Home Screen, hero heading, quick actions, API
  banner, logo, background, AppBar, theme, bubble spacing/radius/
  colors, drawer, history, profile, Markdown, TTS, and copy actions
  are all untouched.
