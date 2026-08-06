# CHANGE_REPORT.md — Step 27B: Premium Home Screen Redesign

## What changed
Only the **Home (empty-chat) state** of `ChatScreen` was redesigned. Chat
bubbles, streaming, attachments, routing, and the Gemini service are all
untouched — as required.

### New file
- `lib/widgets/pak_home_widgets.dart` — every new presentational widget
  used by the Home screen:
  - `PakSubtleBackground` — a soft emerald radial-gradient wash plus a
    single stylized Pakistan border line, rendered at ~3–5% opacity
    (kept intentionally low so it stays felt, not "read").
  - `PakLogoMark` / `PakHomeAppBarTitle` — the small emerald gradient
    roundel + "Pak AI" wordmark used in the Home top bar.
  - `ProfileAvatarButton` — top-bar right-side avatar. Loads the signed-in
    account's photo via the existing `AuthPrefs` (falls back to a
    monogram/person glyph) and opens the existing `ProfileScreen` on tap
    — no new auth/profile logic was written, this only surfaces what
    already existed one tap earlier.
  - `PakHeroBrand` — the small, elegant "Pak AI / SMART AI ASSISTANT FOR
    PAKISTAN" brand block that replaces the old large "What can I do for
    you?" heading.
  - `QuickActionsRow` / `QuickAction` — the horizontally scrolling pill
    chips: Explain Image, Write Script, Translate, Summarize, Brainstorm.
    Each just fills the existing composer via the same
    `onSuggestionTap` callback the old suggestion chips used — sending
    still goes through the untouched input bar.

### Edited file
- `lib/screens/chat_screen.dart`
  - `AppBar` now branches on `isHomeState` (`true` only while history has
    finished loading and the conversation has zero messages):
    - **Home:** centered `PakHomeAppBarTitle` wordmark, single
      `ProfileAvatarButton` action.
    - **In a conversation:** exactly the original bar (menu, conversation
      title, new-chat, clear-chat) — byte-for-byte the same behavior as
      before.
  - `_EmptyState` rebuilt: subtle background + `PakHeroBrand` +
    `QuickActionsRow`, replacing the old giant heading and vertical
    `Wrap` of 4 suggestion chips. The now-unused `_SuggestionChip` widget
    was removed.
  - `_ChatInputBar`'s decoration only (no logic) got a faint gradient
    fill and a slightly deeper shadow for a more "floating premium pill"
    feel. Every focus/send/stop/attachment/mic handler is unchanged.

## Not touched (per the brief)
Chat bubbles, Gemini routing, attachments, streaming, the API layer, and
all screens other than the Home state of `ChatScreen`.
