# CHANGE_REPORT_STEP59.md

Step 58 was used as the stable baseline. Only the two files below were
touched; nothing else in the project was modified.

## Files changed

- `lib/screens/chat_screen.dart`
- `lib/widgets/chat_bubble.dart`

No other file was opened for editing. PDF/document intelligence, voice
recording/playback, `CreditService`'s internals, Profile, Upgrade Plan,
monetization/AdMob, the model selector, the Pak AI header/logo, the
attachment sheet, and the composer's overall design are all unchanged.

---

## Bug 1 — Send/Stop button position during streaming

**Root cause:** the circular button has no fixed size of its own — it
sizes itself to whatever child `AnimatedSwitcher` is currently showing
(10×10 for the Stop square, 14×14 for the sending spinner, 18×18 for the
Send arrow icon). Because the composer row uses
`crossAxisAlignment: end` (every button anchored to the row's bottom
edge), a smaller child made the *whole circular button* shrink from the
top down — which is exactly what reads as "the button moves downward"
once streaming starts and the button swaps to the 10×10 Stop square.

**Fix:** every state's child is now wrapped in an identically-sized
18×18 `SizedBox` (centered), matching the largest of the three
(the Send icon). The button's outer diameter — and therefore its
vertical center — now stays fixed across idle, sending, streaming, and
done. Icon, color, animation, and tap behavior are unchanged; only the
sizing wrapper was added.

**Also addressed (explicitly required by this bug's spec):** the
`TextField` had no `keyboardType` set and used
`textInputAction: TextInputAction.send` with an `onSubmitted` that
called `onSend()` directly — i.e. pressing Enter/Return sent the
message immediately, bypassing the Send button entirely. Changed to
`keyboardType: TextInputType.multiline` + `textInputAction:
TextInputAction.newline`, and removed `onSubmitted`. Return now inserts
a newline; the Send/Stop button is the only way to submit.
`minLines`/`maxLines` (multiline growth) are untouched.

## Bug 2 — Code block copy button

**Root cause:** `MarkdownBody` had no custom builder for fenced code
blocks (```` ```...``` ````). They rendered using only
`codeblockDecoration`/`codeblockPadding` from the style sheet — plain
styling, no header, no attached control. The only Copy button in the
whole reply was the AI message's own action row, which sits below the
*entire* message and copies the *entire* reply — which is what reads as
"the copy button is below the code block."

**Fix:** added `_CodeBlockBuilder` (a `MarkdownElementBuilder` for the
`pre` tag) and `_CodeBlockWidget` in `chat_bubble.dart`, registered via
`MarkdownBody(builders: {'pre': _CodeBlockBuilder(...)})`. Each fenced
code block now renders as its own card: a header row (language label,
or "Code" if none was specified, + a Copy button) directly above the
code, both inside one rounded container. Copy uses
`Clipboard.setData` with only that block's own text (extracted from
that specific AST node — never the surrounding message), and briefly
swaps its icon/label to "Copied" for feedback. Since the builder is
invoked once per `pre` node found, multiple code blocks in one reply
each get their own independent widget instance and Copy button.
Inline code (single backticks) and everything else in the style sheet
(tables, headings, blockquotes, etc.) is untouched — only the `pre`
element's rendering was replaced. Horizontal scrolling for long lines
is preserved via `SingleChildScrollView(scrollDirection: Axis.horizontal)`,
and the text stays selectable. The existing AI message action row
(Copy/Like/Dislike/Voice/Share/More) is untouched and unrelated to this
per-block control.

## Bug 3 — User message must not be editable by tapping

**Finding:** this codebase, as provided, has **no tap-to-edit trigger
on user messages at all**. The user bubble's only interaction is a
`GestureDetector(onLongPress: () => _copyMessage(...))` around the
whole `ChatBubble` — no `onTap`, no `TextField`, no controller
re-population anywhere in `chat_bubble.dart` or `chat_screen.dart`
tied to a user bubble tap. So the specific "unwanted behavior"
described (tapping a sent message re-enters it for editing) does not
reproduce against this baseline — there was no such code path to
remove.

That said, the spec's required end state — and its verification
checklist — call for a working ⋮ **More menu → Regenerate** path on
user messages, which also did not exist in this baseline (the existing
`_ActionRow`/More popup was wired up for AI replies only). Added that,
reusing the existing components rather than building anything new:

- `ChatBubble` now shows a small ⋮ (`more_horiz`) icon under the most
  recent user message, but **only** when a regenerate is actually
  available for it (see below) — nothing changes for older user
  messages, and the bubble itself remains fully inert to tap/long-press
  beyond the pre-existing copy-on-long-press.
- Tapping ⋮ opens the exact same `_showMoreMenu`/`_MorePopup` component
  the AI reply row already uses (`_openMoreMenu`, unchanged). Only
  `onRegenerate` is ever passed for a user message, so its Share and
  Delete rows render dimmed/inert in that popup — the same "disabled"
  treatment an older AI reply's Regenerate already gets today. No new
  popup UI was built.
- In `chat_screen.dart`, added `_regenerateFromUserMessage(userIndex)`,
  a thin wrapper that resolves the AI reply following that user message
  and forwards to the existing, unmodified `_regenerateResponse(aiIndex)`
  — all the actual regenerate logic (removing the old reply, rebuilding
  history, re-streaming) is untouched.
- Wired up only for the most recent exchange (the user message
  immediately followed by the conversation's last message, which must
  be an AI reply) and only while nothing is currently sending — the
  same restriction the AI reply's own Regenerate already uses.

No edit feature, composer re-population, or resend-on-tap was added —
`onRegenerate` is the only callback wired to this menu, and it never
touches `_inputController`.

## Bug 4 — Long user messages can hang/freeze chat

Traced the full flow (`_sendMessage()` → credit check → Gemini request →
streaming → `ChatMessage` creation → list rebuild → Markdown/code
rendering → scrolling) rather than adjusting a timeout. Found one real,
reproducible root cause plus one contributing trigger:

**Root cause — duplicate-send race window:** `_sendMessage()`'s
re-entrancy guard (`if (... || _isSending) return;`) only rejects a
second call once `_isSending` is `true` — but `_isSending` was not set
to `true` until *after* `await creditService.checkAndConsume(...)`
completed. Any second call to `_sendMessage()` arriving while that
first `await` was still pending (SharedPreferences I/O) sailed straight
past the guard, since `_isSending` was still `false` at that moment.
That allows two overlapping sends: two credit deductions, two user
bubbles appended, and potentially two concurrent `_streamAiReply` calls
racing to write into the same `_messages` list indices — real
duplicate processing and state contention, which is what surfaces as
the chat "hanging." This is more likely to happen with a long message,
since composing/validating it takes longer, giving a person more
opportunity to tap Send again (or hit Enter) before the first call has
had a chance to flip the guard.

**Contributing trigger:** as noted under Bug 1, the `TextField`'s
`onSubmitted: (_) => onSend()` meant pressing Enter fired a second,
independent call into the exact same unguarded window — e.g. Enter
right after tapping Send. Removing it (Bug 1's fix) removes that
specific trigger.

**Fix:**
- `_isSending` is now set `true` synchronously, immediately after the
  initial validation check, *before* the credit-check `await`. This
  closes the race window: a second call now always hits the existing
  guard and returns immediately, no matter how slow the first call's
  credit check is.
- The credit-blocked path (`!hasCredits`) now explicitly resets
  `_isSending = false` before showing the credit-limit sheet, since the
  guard was set optimistically before the check resolved.
- The later `setState` block (attachment lock / send-stage UI) no
  longer redundantly sets `_isSending = true` — it's already true by
  that point — everything else in that block is unchanged.
- All other existing reset points (`_reportAttachmentFailure`, the
  document-follow-up and smart-capability handoffs, `_streamAiReply`'s
  own `finally` block) were reviewed and already correctly reset
  `_isSending`; none needed changes.

**Investigated and found NOT to be a problem** (no changes made for
these):
- `CreditService.calculateCost` — a fixed-tier length check, O(1), no
  loop or regex over the message text.
- `GeminiService`'s request building — `jsonEncode` of the request body
  is synchronous but proportional to message length, not something
  that scales badly enough on its own to explain a "hang," and it isn't
  re-run per keystroke or per rebuild.
- `_detectSmartIntent` / `_looksLikeDocumentFollowUp` — only reachable
  on attachment-bearing or active-document-follow-up sends; a plain
  long text message with no attachment and no active document skips
  both entirely.
- The streaming flush path in `_streamAiReply` (`Timer.periodic` +
  `StringBuffer`, already throttled to one `setState` per ~75ms
  regardless of chunk rate) — this predates Step 59 and was not
  touched; it governs AI *reply* rendering, not the user message send
  path this bug is about.
- Markdown/code-block rendering (Bug 2's area) — re-renders on each
  streamed AI reply update as before; the new code-block builder does
  no additional parsing beyond what `MarkdownBody` already does.

No credit-system behavior, truncation, or timeout value was changed.
The Gemini streaming architecture is untouched.

---

## Verification performed

Flutter/Dart tooling is **not installed in this environment** (no
`flutter`/`dart` executable, no network access to fetch the SDK or run
`pub get`), so **no compilation or `flutter analyze` was actually run**.
Verification below is static/manual only:

1. **Bracket/brace/parenthesis balance** — checked programmatically for
   both modified files:
   - `lib/screens/chat_screen.dart`: braces 330/330, parens 1700/1700,
     brackets 147/147 — balanced.
   - `lib/widgets/chat_bubble.dart`: braces 68/68, parens 439/439,
     brackets 24/24 — balanced.
2. **Only intended files changed** — confirmed only
   `lib/screens/chat_screen.dart` and `lib/widgets/chat_bubble.dart`
   were edited; no other file in the project was opened for writing.
3. **No raw API/JSON error exposure** — Bug 4's changes touch only
   `_isSending` timing and add a code-render widget; the existing
   friendly error classification/messages in `_streamAiReply` and
   `GeminiService` were not modified.
4. **No tap-to-edit** — confirmed no `onTap` exists anywhere on the
   user bubble or its ancestors; the only interaction remains
   long-press-to-copy plus the new ⋮ (Regenerate-only) menu.
5. **⋮ → Regenerate functional (manual trace)** — `_regenerateFromUserMessage`
   resolves the following AI-reply index and calls the existing,
   unmodified `_regenerateResponse(aiIndex)`; traced its body
   end-to-end (removes the old reply, rebuilds history, re-streams) —
   logic unchanged from Step 58.
6. **Code-block Copy scoping (manual trace)** — `_CodeBlockBuilder.visitElementAfter`
   is invoked once per `pre` AST node by the `markdown` package's
   parser/renderer; `element.textContent` on that node returns only
   that node's own text. Verified no shared/static state exists between
   `_CodeBlockWidget` instances — each has its own `_copied` flag and
   `Timer`.
7. **Multiple code blocks independent (manual trace)** — since
   `builders: {'pre': _CodeBlockBuilder(...)}` is a single builder
   *instance* but `visitElementAfter` receives a distinct `element` per
   call, each fenced block in a message gets its own `_CodeBlockWidget`
   with its own `code`/`language`, hence its own Copy button and its
   own clipboard write.
8. **Send/Stop vertical position (manual trace)** — confirmed all three
   `AnimatedSwitcher` children are now wrapped in the same
   `SizedBox(width: 18, height: 18)`, so the enclosing `Padding(all: 8)`
   + circle decoration now always wraps the same outer box size
   (34×34) regardless of state.
9. **`TextInputType.multiline` present** — confirmed
   (`keyboardType: TextInputType.multiline` added).
10. **`TextInputAction.newline` present** — confirmed (was
    `TextInputAction.send`, now `TextInputAction.newline`).
11. **No `onSubmitted` accidental send** — confirmed the `onSubmitted`
    callback was removed from the `TextField` entirely.
12. **Credit consume/refund logic untouched** — `CreditService` was not
    opened; `checkAndConsume`, `calculateCost`, and
    `_resolvePendingCreditRefund` are unchanged. Only the *timing* of
    the `_isSending` flag around the existing `checkAndConsume` call
    was changed, and a rollback of that flag was added on the
    already-existing credit-blocked branch.
13. **PDF/voice/document features untouched** — no files under
    `document_intelligence_*`, `voice_*`, or their screens/widgets were
    opened.
14. **Long-message flow reviewed** — see the Bug 4 section above for
    the specific race condition found and fixed, and the list of areas
    checked and ruled out.
15. **Flutter/Dart analysis: NOT run** (no toolchain available in this
    environment) — static/manual verification only, as itemized above.

## Confirmation

- Branding, header, composer styling (beyond the two Bug‑1‑required
  `TextField` input properties), credits system internals, PDF/document
  features, voice features, model selector, monetization, Profile,
  and Upgrade Plan were not touched.
- No new edit feature, tap-to-edit, or duplicate send control was
  introduced.
- No hardcoded height calculation based on message/line count was used
  for the Bug 1 fix — the fix is a fixed-size wrapper independent of
  content.

Per your instructions, **Step59.zip has not been created**. Let me know
when you'd like it packaged.
