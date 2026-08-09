# CHANGE REPORT — STEP 40: Chat-Native Intelligence UX Refactor

## Summary

Pak AI's three specialized capabilities from Steps 38–39 — OCR/Scan Text,
Handwriting Recognition, and Advanced Document Intelligence — are no longer
manually selected from the attachment sheet or shown on separate result
screens. The user now just attaches an image/PDF and describes what they
want in normal language (English or Roman Urdu/Hindi); Pak AI routes that
locally to the right existing capability and shows the result as an
ordinary assistant message inside the conversation, with an immediate
in-chat loading state and grounded follow-up questions that stay in chat.

No new AI capability was added. No new dependency was added. The Gemini API
architecture is untouched. This step is a UX/integration refactor on top of
Steps 38–39's existing services.

## Architecture Changes

**Before:** attachment sheet → (OCR/Handwriting/Document AI as explicit
options) → dedicated picker → standalone result screen
(`TextScanResultScreen` / `DocumentIntelligenceScreen`) → optional "Use in
Chat" to fill the composer.

**After:** attachment sheet → normal Camera/Gallery/Files/PDF only → the
attachment + the user's own typed instruction are processed once
(`AttachmentProcessorService.process`, unchanged) → a **local** keyword
router (`ChatScreen._detectSmartIntent`, no Gemini call) decides whether
this is OCR, Handwriting, Document Intelligence, or the existing generic
image/document understanding flow → the matching existing service
(`TextRecognitionService` / `DocumentIntelligenceService`) runs directly →
the result becomes a normal `ChatMessage` in `_messages`, rendered inline by
`ChatBubble` (plain text for OCR/Handwriting, a new compact
`DocumentResultCard` for Document Intelligence).

Nothing about the Gemini call plumbing changed: every capability still goes
through the exact same `GeminiService.sendMessage()` used everywhere else,
just invoked from `TextRecognitionService`/`DocumentIntelligenceService` as
before. This step only changed **who triggers** each capability (local
heuristic instead of a manual menu pick) and **where the result is shown**
(inline in chat instead of a pushed screen).

Two small, additive refactors avoid doing any file processing twice for the
new flow:

- `TextRecognitionService.recognizeFromPart()` (new) — the same
  ask-Gemini-and-parse logic `recognize()` already had, now runnable
  against an already-processed `GeminiInlinePart` instead of the raw file.
  `recognize()` itself is unchanged and still used by the standalone Scan
  Text/Handwriting flow.
- Chat-native Document Intelligence builds its `PreparedDocument` directly
  from the `ProcessedAttachment` the message-send flow already computed,
  instead of calling `DocumentIntelligenceService.prepare()` (which would
  call `AttachmentProcessorService.process()` a second time on the same
  file). `DocumentIntelligenceService.analyze()`/`askQuestion()` — the
  actual Gemini-calling logic — are called exactly as before, unmodified.

A new `DocumentIntelligenceResult`/`DocumentTable` JSON
(`toJson`/`fromJson`) round-trip was added so a chat-native analysis result
can be saved in conversation history and re-rendered as the same compact
card after an app restart — the analysis/parsing logic itself is untouched.

## Files Added

- `lib/widgets/document_result_card.dart` — compact, expandable chat-native
  card for a `DocumentIntelligenceResult` (Part 4): summary always visible,
  up to 3 key points inline, a "View details"/"Show less" toggle for
  headings, all key points, dates, names, numbers, key facts, and tables.
  Tables render in a bordered, horizontally-scrollable grid (same pattern
  `DocumentIntelligenceScreen._TableView` already used, re-implemented
  compactly and self-contained here rather than shared, so that screen
  stays untouched). Pure rendering widget — no Gemini calls, no navigation.
- `CHANGE_REPORT_STEP40.md` (this file).

## Files Modified

- `lib/widgets/attachment_sheet.dart` (Part 1) — removed the "Scan Text",
  "Handwriting", and "Document AI" option buttons from the visible sheet;
  back to the original Camera/Gallery/Files/PDF, same icons/labels/order/
  spacing. The `AttachmentType` enum values `ocr`/`handwriting`/
  `documentIntel` are kept (not deleted) — updated doc comments explain
  they're now unreachable via this sheet but still valid, in-use code.
- `lib/core/services/text_recognition_service.dart` (Part 7/11) — added
  `recognizeFromPart()` (see Architecture Changes above). `recognize()`,
  `TextRecognitionResult`, `TextRecognitionException`, `ScanConfidence`,
  and `TextScanMode` are all unchanged.
- `lib/core/services/document_intelligence_service.dart` (Part 8) — added
  `toJson()`/`fromJson()` to `DocumentIntelligenceResult` and
  `DocumentTable` (see Architecture Changes above). `prepare()`,
  `analyze()`, `askQuestion()`, `PreparedDocument`, `DocumentQaTurn`, and
  the defensive JSON parsing are all unchanged.
- `lib/models/chat_message.dart` — added an optional `documentResult`
  (`Map<String, dynamic>?`) field, serialized/deserialized the same
  backward-compatible way the existing `attachments` field already is
  (absent in old saved history simply defaults to `null`).
- `lib/widgets/chat_bubble.dart` — added a `liveLabel` param (defaults to
  the existing `'Writing...'`, so ordinary streaming replies are visually
  unchanged) used by the in-bubble loading dot; added one conditional
  branch that renders `DocumentResultCard` instead of the plain Markdown
  body when `message.documentResult != null`. Chat bubble visual identity,
  markdown rendering, attachment previews, and the action row are
  otherwise untouched.
- `lib/screens/chat_screen.dart` (the bulk of this step) — see UX/
  Performance sections below for what these additions actually do:
  - `_SmartIntent` enum + `_detectSmartIntent()` (Part 2).
  - `_looksLikeDocumentFollowUp()` (Part 5).
  - `_labelFor()`, `_runSmartCapability()`, `_runDocumentFollowUp()`,
    `_replaceWithSmartError()`, `_buildScanResultMessage()` (Parts 3/4/6/
    7/8/10).
  - New state: `_isSmartProcessing`, `_smartProcessingIndex`,
    `_smartProcessingLabel`, `_smartErrorIndex`, `_smartRetryAction`,
    `_activeDocument`, `_activeDocumentQaTurns`.
  - `_sendMessage()`: captures the single attachment's already-processed
    data, computes local intent, and branches to the smart-capability/
    document-follow-up paths before the existing normal flows — the
    existing plain-text streaming path and the existing multi-image/
    generic-file Gemini path are otherwise byte-for-byte unchanged below
    those new branch points.
  - `_switchConversation()`/`_startNewChat()`/`_clearChat()`: reset the new
    in-memory smart-routing state (it's conversation-specific and never
    persisted, unlike `_messages`).
  - The message `ListView`'s `itemCount` now also excludes the old
    trailing `_LiveStatus` row while `_isSmartProcessing` (its own
    placeholder bubble already shows a loading dot), and the `ChatBubble`
    construction now passes `isLive: isLive || isSmartLoading`,
    `liveLabel: ...`, and resolves `onRetry` through
    `_smartErrorIndex`/`_smartRetryAction` when applicable.
  - Imports broadened: `text_recognition_service.dart` from `show
    TextScanMode` to a full import (needed `TextRecognitionService`,
    `TextRecognitionException`, `TextRecognitionResult`,
    `ScanConfidence`), and `document_intelligence_service.dart` newly
    imported.
  - `_openAttachmentSheet()`'s existing OCR/Handwriting/Document AI
    branches and `_startTextScan()`/`_startDocumentIntelligence()` are
    unmodified in behavior — only documented as now UI-unreachable (Part
    9), since the sheet never returns those `AttachmentType` values
    anymore.

## Files Intentionally Untouched

Per Part 9 (avoid unnecessary deletion) and confirmed still referenced/
reachable (Verification, item 4 below):

- `lib/screens/text_scan_result_screen.dart`
- `lib/widgets/image_source_sheet.dart`
- `lib/screens/document_intelligence_screen.dart`
- `lib/widgets/document_source_sheet.dart`

Also confirmed untouched: `lib/widgets/pak_home_widgets.dart` (Step 37
Quick Action pills), the Home screen, AppBar, Drawer, `pubspec.yaml`, and
all chat bubble visual styling / the input bar / send button beyond the one
additive `liveLabel` param described above.

## UX Changes

- Attachment sheet: back to 4 options (Camera/Gallery/Files/PDF) — the 3
  specialized options are gone from the UI (Part 1).
- Attach an image/PDF + type an instruction in plain language
  ("Is image ka text nikal do", "Is PDF ko summarize karo", "Is
  handwritten note ko read karo", etc.) → Pak AI silently picks the right
  capability and answers inline, with no extra taps (Part 2/3).
- Document Intelligence results render as a compact card: summary + up to
  3 key points + a "View details" toggle for everything else, instead of a
  full-screen dump (Part 4). Tables inside stay horizontally scrollable
  with no RenderFlex overflow.
- OCR results render as plain recognized text; Handwriting results keep
  Step 38's exact confidence-warning text ("This handwriting was hard to
  read…" / "Some words in this handwriting were unclear…"), shown as a
  compact Markdown blockquote callout the bubble already styles distinctly
  (Part 7) — no separate warning UI needed.
- Follow-up questions about the most recently analyzed document ("Is
  document mein total amount kya hai?", "Page 2 ka important point
  batao.") are answered inline, grounded in that same document, without
  reopening any picker or Document AI (Part 5). This only triggers when the
  message text itself references the document (see Known Limitations) —
  everything else keeps behaving as ordinary chat.
- Immediately after sending, a lightweight status ("Reading your
  document…", "Extracting text…", "Reading the handwriting…", "Analyzing
  the document…", "Checking the document…") appears in the same pulsing-dot
  style the app already uses for normal replies — never a blank screen
  (Part 6).
- Failures replace that loading state with a normal error bubble and a
  Retry button that reruns the same capability against the same
  already-processed data — no re-picking, no re-reading the file (Part 10).

## Performance Changes

- **Zero extra Gemini calls for intent classification** — routing is pure
  local string matching (`_detectSmartIntent`/`_looksLikeDocumentFollowUp`),
  as explicitly required.
- **Zero duplicate attachment processing** — the single attachment is run
  through `AttachmentProcessorService.process()` exactly once per send (the
  same call the message-bubble preview already needed); both
  `TextRecognitionService.recognizeFromPart()` and the chat-native
  `PreparedDocument` construction reuse that same result instead of calling
  `recognize()`/`prepare()` (which would each re-process the file).
- **Zero duplicate PDF extraction** — same reasoning; `extractedText` is
  computed once and reused for the whole Document Intelligence + all of its
  Q&A follow-ups via `PreparedDocument`/`_activeDocument`.
- **Zero unnecessary navigation** — results render inline; no
  `Navigator.push` for the routed cases.
- **No extra `ChatScreen` rebuilds beyond what `setState` already causes**
  for a normal sent message — the new state (`_isSmartProcessing`, etc.)
  piggybacks on the same `setState` calls the existing send flow already
  makes.

## Error Handling

All preserved, per Part 10:

- Cancelled picker → silently returns (unchanged `_startTextScan`/
  `_startDocumentIntelligence`, and the normal attachment picker flow is
  untouched).
- Corrupt/unsupported image, empty/no-readable-content, Gemini
  timeout/API-key errors, malformed Document AI JSON (raw fallback) — all
  the exact same exception types (`AttachmentException`,
  `TextRecognitionException`, `DocumentIntelligenceException`,
  `GeminiException`) and messages from Steps 38–39, now caught in
  `_runSmartCapability`/`_runDocumentFollowUp` and shown as a normal chat
  error bubble instead of a screen-level error state.
- Handwriting confidence warning — preserved exactly (see UX Changes).
- Q&A failure — caught locally in `_runDocumentFollowUp`; `_activeDocument`
  is never cleared on failure, so the person can just retry or keep asking.
- A final catch-all (`catch (_)`) in both `_runSmartCapability` and
  `_runDocumentFollowUp` guarantees no unanticipated exception can crash
  the screen — it always degrades to a normal, retryable error bubble.

## Verification Performed

**Flutter/Dart SDK is not available in this environment — no
`flutter analyze`/`test`/`build` was run or claimed.** Static verification
only:

1. `git diff --check` on the full changeset — clean.
2. Bracket-balance check (custom script tracking `()`/`[]`/`{}` across
   strings/comments) re-run after every substantive edit, on all 7 changed
   files — all report "balanced" in the final state.
3. Checked every `AttachmentType` switch statement in the codebase
   (`chat_screen.dart` lines ~1601 and ~1784) — both remain exhaustive/safe
   with the unchanged enum (the first already had `ocr`/`handwriting`/
   `documentIntel` cases from Steps 38–39; the second uses a `default:`
   case). `AttachmentProcessorService.classify()` uses `if`/`==`, not a
   switch — unaffected either way.
4. Searched for references to `TextScanResultScreen`,
   `DocumentIntelligenceScreen`, `showImageSourceSheet`,
   `showDocumentSourceSheet` — all four are still referenced (from
   `_startTextScan`/`_startDocumentIntelligence`, which remain intact and
   reachable code, just no longer wired to the attachment sheet's UI).
5. Confirmed `lib/core/services/text_recognition_service.dart` was edited
   additively only — diffed the full change (added one method, refactored
   `recognize()`'s body into two lines calling it; no other line touched).
6. Confirmed `pubspec.yaml` has zero diff — not in the changed-files list.
7. Confirmed no new dependency was added — no new `import 'package:...'`
   anywhere in the diff; every new import is either `dart:` or this
   project's own `lib/...` files.
8. Confirmed no second Gemini intent-classification call — `_detectSmartIntent`
   and `_looksLikeDocumentFollowUp` are pure local string/enum logic with no
   `await`, no service call, no network access.
9. Confirmed chat bubble visual identity and Step 37 Quick Action pills are
   untouched — `chat_bubble.dart`'s diff is exactly one new optional
   constructor param (default-preserving) plus one new conditional render
   branch; `pak_home_widgets.dart` has zero diff (not in the changed-files
   list).
10. Cross-checked every new/changed call site against the actual source of
    the function/class it calls: `AttachmentProcessorService.process`/
    `ProcessedAttachment` fields, `TextRecognitionService.recognizeFromPart`,
    `TextRecognitionResult`/`ScanConfidence`/`TextScanMode`,
    `DocumentIntelligenceService.analyze`/`askQuestion`, `PreparedDocument`
    constructor, `DocumentQaTurn.answer`, `ChatAttachmentKind` values, and
    `ChatMessage`'s new field/constructor/`toJson`/`fromJson`.

## Known Limitations

- **Local intent routing is heuristic, not perfect.** It's keyword-based
  (English + common Roman Urdu/Hindi phrasing from the spec's own
  examples), so an instruction using none of the matched phrases falls
  through to the existing generic image/document understanding flow rather
  than the specialized capability — this is the explicitly-required
  "ambiguous → normal flow" behavior, not a bug, but it means an unusual
  phrasing of a document-intelligence request might not trigger the
  compact card and will instead get a normal free-form answer.
- **Document follow-up routing also requires an explicit reference**
  (document/table/page/amount/date/etc. — see `_looksLikeDocumentFollowUp`)
  rather than treating every message after any document analysis as being
  about that document. This is a deliberate trade-off to satisfy Part 12
  ("existing normal chat must work exactly as before") — the alternative
  (sticky forever) would silently break ordinary conversation for the rest
  of the chat after a single document was ever analyzed. The trade-off is
  that a follow-up phrased with none of those cues won't be treated as a
  document question and will get a normal answer instead.
- **OCR/Handwriting routing is still image-only** (Step 38's
  `TextRecognitionService` design, unchanged) — a matching phrase on a PDF
  is redirected to Document Intelligence instead, which can still surface
  the text content via its summary/key facts, just not as a literal
  transcription.
- **PDF table reconstruction is still text-based**, per Step 39's existing
  known limitation — unchanged by this step.
- **No Flutter build was run** in this environment (SDK unavailable), so
  this verification is static-only, as required. A real
  `flutter analyze`/on-device run is recommended before shipping.

## Manual Testing Checklist

- [ ] Open the attachment sheet → confirm only Camera/Gallery/Files/PDF
      appear (no Scan Text/Handwriting/Document AI buttons).
- [ ] Attach a photo of printed text, type "Is image ka text nikal do" →
      confirm the recognized text appears as a normal assistant message in
      chat (no navigation).
- [ ] Attach a photo of handwriting, type "Is handwritten note ko read
      karo" → confirm transcription appears inline; if confidence is
      medium/low, confirm the "may contain mistakes" warning shows as a
      distinct callout.
- [ ] Attach a PDF, type "Is PDF ko summarize karo" → confirm a compact
      card appears (summary + up to 3 key points), with a "View details"
      toggle if there's more.
- [ ] Tap "View details" → confirm headings/tables/dates/names/numbers/key
      facts appear; confirm any table scrolls horizontally with no
      overflow on a narrow-width test.
- [ ] After a document result, type "Is document mein total amount kya
      hai?" → confirm a grounded answer appears inline without reopening
      any picker.
- [ ] Ask a second follow-up ("Page 2 ka important point batao.") →
      confirm it's still answered from the same document.
- [ ] After a document result, ask something clearly unrelated with no
      document-referencing words (e.g. "tell me a joke") → confirm it's
      answered as normal chat, not forced through document Q&A.
- [ ] Attach an image/PDF with ambiguous phrasing (e.g. "what is this?")
      → confirm it falls through to the normal existing image/document
      understanding flow, not a specialized card.
- [ ] Force a failure (e.g. disconnect network) while a smart capability is
      running → confirm a friendly error bubble with a working Retry that
      re-runs without re-picking the file.
- [ ] Cancel the picker after tapping Camera/Gallery/PDF → confirm nothing
      happens (no crash, no stray message).
- [ ] Send a normal text-only message with no attachment and no document
      history → confirm it streams exactly as before.
- [ ] Send a normal image/PDF attachment with default/no typed text →
      confirm it still gets the existing generic "what can you tell me
      about this" understanding flow, unchanged.
- [ ] Switch conversations / start a new chat / clear chat → confirm a
      previously "active" document no longer answers follow-ups in the new
      context.
- [ ] Re-check Home screen's Step 37 Quick Action pills, AppBar, Drawer,
      and overall chat bubble look — confirm all unchanged.
