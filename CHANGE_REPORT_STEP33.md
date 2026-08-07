# Step 33 — Premium UX & Conversation Flow Polish

## Scope

Continuing from the approved Step 32.1 baseline. Only the four requested
UX refinements were made. Gemini API logic, streaming logic, providers
(other than the one startup-selection tweak in Change 4), services, theme,
colors, the Pakistan background, Home screen layout/grid/spacing/shadows,
header, Quick Action card size, composer design, navigation drawer,
settings, profile, routing architecture, history storage, and message
persistence are all unchanged.

## Files Changed

- `lib/widgets/chat_bubble.dart` — AI reply max width; in-bubble live
  status widget.
- `lib/screens/chat_screen.dart` — Quick Action description typography;
  live-status label wording.
- `lib/core/providers/conversation_provider.dart` — cold-start
  conversation selection.
- `lib/widgets/typing_indicator.dart` — **removed**. It was already dead
  code (not imported anywhere — the app had moved to the `_LiveStatus`
  pre-send indicator in an earlier step), and Change 3 explicitly asks
  for the old typing indicator to be removed completely, so the leftover
  file was deleted rather than left to rot.

No other file was touched.

## Change 1 — Premium AI Reply Width

**File:** `lib/widgets/chat_bubble.dart`

The bubble's `BoxConstraints.maxWidth` was `MediaQuery.of(context).size.width * (isUser ? 0.68 : 0.8)`.
Only the AI-reply fraction changed, `0.8 → 0.89` (~89% of available
width, inside the requested 88–90% band). The user-bubble fraction
(`0.68`) is byte-for-byte unchanged.

Nothing else in that `Container` moved: the same `padding`
(`horizontal: 20, vertical: 16` for AI replies), the same
`BorderRadius`, the same (absent) border/shadow for AI replies, the
same `MarkdownStyleSheet` (font sizes, colors, code/table/blockquote
styling), and the same copy/TTS/More-menu action row are all
untouched — this is a width-only change.

## Change 2 — Home Screen Quick Action Typography

**File:** `lib/screens/chat_screen.dart` (`_QuickActionPill`)

The description `Text` under each card's title used `maxLines: 2` at
`fontSize: 13` / `height: 1.2`, which clipped the longer descriptions
(e.g. "Create scripts for videos, ads, stories and more.") with an
ellipsis. Only that `Text`'s typography changed:

- `fontSize: 13 → 12.5`
- `height: 1.2 → 1.25`
- added `letterSpacing: -0.05`
- `maxLines: 2 → 3`

`overflow: TextOverflow.ellipsis` stays in place as a safety net, but
with the extra line and slightly smaller/tighter type every existing
description now renders in full. The card's padding (`all: 14`),
`BorderRadius` (18), `boxShadow`, fill color, the icon, the title
`Text`'s style, the 2-column/3-row grid, the 12px inter-card gutters,
and the `IntrinsicHeight`-driven row-height matching are all
completely unchanged — the card still sizes itself to its own content
exactly as before, it just now has room to show the whole sentence
instead of a clipped one.

## Change 3 — Premium Live Status Indicator

**Files:** `lib/screens/chat_screen.dart`, `lib/widgets/chat_bubble.dart`,
`lib/widgets/typing_indicator.dart` (removed)

The app already had two separate "is the AI busy" indicators left over
from earlier steps:

1. **`_LiveStatus`** in `chat_screen.dart` — shown in the message list
   while a send is in flight and no stream has started yet. This was
   already exactly what Step 33 asks for: a single small green dot
   with a subtle pulse, plain text beside it, no bubble/border/shadow.
   Only its labels were touched, so the "reading an image" stage reads
   as **"Reading image..."** instead of the more generic "Reading...";
   `Thinking...`, `Analyzing...` / `Analyzing (Batch X of Y)...`, and
   `Writing...` were already correct and are unchanged. (There is no
   hidden "Searching" stage anywhere in the current Gemini pipeline, so
   one isn't fabricated — only real generation stages are ever shown.)

2. **The old three-dot typing animation** — this was the piece that
   still didn't match: once a reply started *streaming* but before its
   first chunk of text had arrived, `ChatBubble` rendered a private
   `_LiveTypingDots` widget — three separate pulsing circles in a row,
   the classic "typing bubble" look Step 33 explicitly rules out.

   `_LiveTypingDots` was replaced with a new `_InlineLiveDot` widget
   that mirrors `_LiveStatus` exactly: **one** small circle
   (`Color(0xFF22C55E)`, the same green), a single `AnimationController`
   driving one continuous opacity/scale pulse, and plain text
   (`"Writing..."`) beside it — no `Container` decoration, no
   background, no border, no shadow, no bubble shape. It sits inside
   the existing transparent AI-reply container (which itself has no
   fill/border/shadow), so visually it's just the dot and the label on
   the plain background, exactly like `_LiveStatus` above it in the
   list.

   The now-fully-dead `lib/widgets/typing_indicator.dart` (the
   original three-dot `TypingIndicator` widget, already unused before
   this step) was deleted outright rather than left as unreferenced
   dead code.

**Behavior preserved exactly:** the dot+label still disappears the
instant real content starts arriving — `showLiveTypingDots` is only
true while `widget.isLive && message.text.isEmpty`, so as soon as the
first streamed characters land, the widget swaps straight to the
Markdown-rendered reply. Nothing about *when* the indicator shows or
hides changed, only *what it looks like*.

## Change 4 — Startup Experience

**File:** `lib/core/providers/conversation_provider.dart`

**Before:** `ConversationProvider.init()` loaded all saved
conversations, then looked up the previously-open conversation's id
(`ConversationStorageService.loadLastConversationId()`) and made that
one current — so a cold app launch dropped the user straight back into
whatever chat they'd left, messages and all.

**After:** `init()` no longer reads or restores the last-open
conversation id. Instead:

- If there are no saved conversations at all (first-ever launch),
  behavior is unchanged: a single fresh empty conversation is created.
- Otherwise, it looks at the most recent conversation (newest-first,
  pinned-first — same ordering the drawer/History already use). If
  that conversation is already empty (no messages sent), it's reused
  as the current one — so relaunching twice in a row without sending
  anything doesn't pile up duplicate blank chats. If it has messages,
  a brand-new empty conversation is created and inserted at the top of
  the list and made current.

Because `ChatScreen` already shows its Home screen (`_EmptyState`)
whenever the current conversation has no messages, always starting
`init()` on an empty conversation means a cold launch always lands on
Home.

**What did not change:**
- Every previous conversation stays in `_conversations`, is persisted
  by the same `_persist()` call, and is fully visible and reachable
  from History exactly as before — nothing is deleted, cleared, or
  overwritten.
- `selectConversation`, `saveCurrentMessages`, `clearCurrentMessages`,
  `renameConversation`, `togglePin`, `deleteConversation`, and all of
  `ConversationStorageService` are untouched — history storage and
  message persistence logic is identical to Step 32.1.
- `init()` is still idempotent (`if (_initialized) return;`), so this
  only affects a genuine cold start (new app process). Backgrounding
  and resuming the app, or navigating to History/Settings/Profile and
  back, keeps the same `ConversationProvider` instance alive and does
  **not** re-trigger this selection — the user's in-progress chat
  during a single session is never yanked out from under them.

## Verification

- No `RenderFlex` overflow introduced: the AI-reply width change only
  widens an existing `BoxConstraints.maxWidth`; the Quick Action
  description change only adjusts text size/line-height/line-count
  inside a card that already sizes itself to its content via
  `IntrinsicHeight` + `mainAxisSize.min`.
- Home cards: same size logic, same 2×3 grid, same 12px spacing, same
  shadows, same colors — only the description `Text` style changed.
- AI replies now render at ~89% width; user bubble width (68%) is
  unchanged.
- Live status is a single animated green dot with plain text beside
  it, both before a send resolves (`_LiveStatus`) and during the brief
  pre-first-chunk moment of a live stream (`_InlineLiveDot`) — no
  three-dot animation, no bubble, no background, no border, no shadow,
  anywhere in the app.
- `lib/widgets/typing_indicator.dart` (the old three-dot indicator) is
  deleted.
- Cold launch (fresh app process) always lands on the Home screen.
- All previously saved conversations remain intact and open correctly
  from History.
- Existing chat persistence (send, regenerate, attachment, delete,
  rename, pin) continues to work unchanged — none of that code was
  touched.
- Gemini API logic, streaming/SSE parsing, providers other than the
  startup-selection change above, theme, colors, background, header,
  composer, drawer, settings, profile, and routing are all untouched —
  confirmed via file-level diff against the Step 32.1 baseline: only
  `chat_bubble.dart`, `chat_screen.dart`, and
  `conversation_provider.dart` were modified, and
  `typing_indicator.dart` was removed.
