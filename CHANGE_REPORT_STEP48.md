# CHANGE_REPORT_STEP48.md

Baseline: Step47.zip
Files touched: **2 only**
- `lib/screens/chat_screen.dart`
- `lib/widgets/chat_bubble.dart`

No changes to Gemini logic, streaming, history, drawer, settings, theme, home background, Pakistan branding, message persistence, or API logic (confirmed via diff — only the two files above differ from Step47).

## 1. Input Bar — Send button anchoring
**Root cause:** the send button was wrapped in `Align(alignment: Alignment.center)` inside an `IntrinsicHeight` row, so as the `TextField` grew to multiple lines (up to `maxLines: 5`), the button re-centered against the taller row instead of staying pinned to the bottom — while the "+" and mic buttons (which used `Padding(bottom: 2)` + `CrossAxisAlignment.end`) correctly stayed put.
**Fix:** removed `IntrinsicHeight`/`Align`; the send button now uses the same `Padding(bottom: 2)` + `CrossAxisAlignment.end` treatment as the "+" and mic buttons. All three icon controls now anchor to the row's bottom edge identically, so multi-line text grows the composer upward from a fixed bottom edge and never pushes the send button up (matches ChatGPT/Claude). Mic button alignment unchanged.

## 2. Jump to Latest — visibility logic
**Root cause:** the button's visibility required `!_followBottom && _newContentWhilePaused` — it only appeared if new text had streamed in *while* scrolled up, not simply because the user was away from the bottom.
**Fix:** visibility now depends only on `!_followBottom`. The button appears any time the user is scrolled away from the bottom, hides the instant they return to the bottom (or tap it, which also scrolls to bottom), and reappears if they scroll up again. Circular design, tap handler, and scroll-to-bottom animation are unchanged.

## 3. AI Reply Width
Increased the AI-reply bubble's `maxWidth` from `0.89` to `0.94` of screen width (within the requested 92–96% range) to reduce unnecessary line breaks. User-bubble width (`0.68`), plain background, markdown rendering, copy/TTS/menu, and timestamps are all untouched.
