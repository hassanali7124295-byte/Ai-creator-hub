# CHANGE REPORT — STEP 39: Advanced Document Intelligence

## Summary

Adds a new "Document AI" feature to Pak AI: the user attaches a photo of a
document/page or an existing PDF and gets back a structured breakdown —
document type, a generated summary, extracted key points, headings, dates,
names, numbers, key facts, and reconstructed tables — plus a grounded Q&A
panel to ask follow-up questions about that same document.

The feature is entirely additive. It reuses the existing attachment
pipeline, Gemini integration, and app theme; it does not modify Step 37's
Quick Action pills, chat bubble behavior, the input bar/send button, or
Step 38's OCR/Handwriting feature.

## Architecture

No second Gemini/image/document pipeline was introduced. The new feature is
built entirely on infrastructure that already existed before this step:

- **File reading, image compression, PDF text extraction** — reused as-is
  from `AttachmentProcessorService.process()`, the exact function already
  used by chat attachments and by Step 38's OCR/Handwriting. Images are
  downscaled/re-encoded the same way; PDFs have their text extracted
  on-device (off the UI isolate) the same way.
- **Gemini calls** — reused as-is from `GeminiService.sendMessage()`, the
  exact function already used everywhere else in the app. Only the prompts
  and response parsing are new. No new endpoint, no new request shape.
- **Theme** — reused as-is from `ChatPalette.themeFor()` (the emerald
  theme), the exact helper Step 38's `TextScanResultScreen` uses.
- **UI pattern** — the new result screen mirrors the loading → success/error
  → Copy/"Use in Chat" structure Step 38 established in
  `TextScanResultScreen`, extended with additional structured sections.

New pieces added on top of that:

1. **`DocumentIntelligenceService`** (new service) — a thin orchestration
   layer with three responsibilities:
   - `prepare()`: calls the existing `AttachmentProcessorService.process()`
     once and caches the result (an image `GeminiInlinePart`, or extracted
     PDF text) in a `PreparedDocument`, so the source file is only ever
     read/compressed/extracted a single time per pick — reused for both the
     initial analysis and every Q&A follow-up.
   - `analyze()`: sends one dedicated prompt asking Gemini for strict JSON
     covering document type, summary, key points, headings, dates, names,
     numbers, key facts, and tables (with `"[unclear]"` for ambiguous table
     cells). Parses that JSON defensively — if it can't be parsed at all,
     the raw reply is still shown to the user via `rawFallbackText` rather
     than surfacing a hard error.
   - `askQuestion()`: sends the document (image or extracted text) plus the
     question and prior Q&A turns (for short-follow-up context), instructed
     to answer only from the document or say plainly it isn't there.

2. **`DocumentIntelligenceScreen`** (new screen) — the result UI: quick
   action chips, a generated-summary card, extracted-content cards
   (key points / headings / tables / dates / names / numbers / key facts),
   and a Q&A panel, plus Copy and "Use in Chat" actions.

3. **`showDocumentSourceSheet`** (new widget) — a Camera / Gallery / PDF
   picker sheet, visually matching the existing attachment/OCR sheets.
   Kept as a separate file from Step 38's `showImageSourceSheet` (which
   only offers Camera/Gallery, for OCR/Handwriting) so that file is
   untouched.

4. **`AttachmentType.documentIntel`** — one new enum value plus one new
   button ("Document AI") appended to the existing attachment sheet, and
   two small integration points in `ChatScreen` (`_openAttachmentSheet`,
   `_startDocumentIntelligence`) that follow the exact pattern Step 38 used
   for OCR/Handwriting.

## Files Added

- `lib/core/services/document_intelligence_service.dart`
- `lib/screens/document_intelligence_screen.dart`
- `lib/widgets/document_source_sheet.dart`
- `CHANGE_REPORT_STEP39.md` (this file)

## Files Modified

- `lib/widgets/attachment_sheet.dart` — added the `documentIntel` enum
  value and one new option button ("Document AI"). Purely additive; the
  original six options are unchanged in order, icon, and label.
- `lib/screens/chat_screen.dart` — added three imports, one new branch in
  `_openAttachmentSheet()` (mirroring the existing OCR/Handwriting branch),
  one new `case` in that method's exhaustive switch (so the switch still
  compiles over the widened enum), and one new method
  `_startDocumentIntelligence()` (mirroring `_startTextScan()`). No
  existing line was changed or removed.

## Dependencies

**Zero new dependencies added.** `pubspec.yaml` is untouched. The feature
uses only packages already present: `flutter/material`, `flutter/services`,
`dart:convert` (for JSON parsing), plus the project's existing
`AttachmentProcessorService`, `AttachmentService`, and `GeminiService`.

## UI Changes

- One new button ("Document AI") added to the existing attachment bottom
  sheet, after "Handwriting" — same circular-button style, same entrance
  animation, same sheet chrome.
- One new screen, `DocumentIntelligenceScreen`, styled with the same
  emerald `ChatPalette` theme, rounded cards, and back-button style as
  Step 38's `TextScanResultScreen`:
  - Loading state: file/image preview + spinner + status text.
  - Error state: icon + message + "Try again" button.
  - Success state: quick-action chip row (Summarize / Key points / Read
    tables / Important info / Ask about this — the tables chip only shows
    when tables were found), a "Generated" summary card, several
    "Extracted" cards (key points, headings, tables, dates/names/numbers/
    key facts), and a Q&A panel at the bottom.
  - Tables render in a bordered, horizontally-scrollable grid
    (`SingleChildScrollView(scrollDirection: Axis.horizontal)` wrapping
    fixed-width cells) so wide tables never overflow on narrow phones;
    unclear cells render in muted italic text.
  - Copy and "Use in Chat" buttons pinned to the bottom, matching Step 38.
- Nothing about Home, the Step 37 Quick Action pills, chat bubbles, the
  input bar/send button, AppBar, Drawer, History, Settings, or Step 38's
  OCR/Handwriting screens was touched.

## Error Handling

- **Unreadable/corrupt/empty file**: `AttachmentProcessorService.process()`
  already throws a user-safe `AttachmentException` for this; `prepare()`
  catches it and re-wraps it as `DocumentIntelligenceException`, shown via
  the screen's error state with a "Try again" button.
- **Unexpected exception during prepare**: caught by a generic `catch (_)`
  in `prepare()` and turned into a safe, specific message rather than
  propagating a raw exception.
- **Gemini/API errors**: `GeminiService.sendMessage()`'s existing
  `GeminiException` (covers missing API key, rejected requests, timeouts,
  safety blocks, empty responses) is caught in `DocumentIntelligenceService._ask()`
  and converted to `DocumentIntelligenceException` with the same message.
- **Malformed/unexpected JSON from Gemini**: `_parseAnalysis()` never
  assumes the shape is correct — it strips stray markdown fences
  defensively, uses a type-safe `_asStringOrNull()` helper (returns `null`
  instead of throwing for any unexpected type), and if the reply can't be
  parsed as JSON at all, falls back to showing the raw reply as
  `rawFallbackText` instead of erroring out.
- **Document reports no readable content**: if Gemini's JSON has
  `{"empty": true}` (or no usable summary), this throws
  `DocumentIntelligenceException('No readable content was found in this
  document.')`, shown as the screen's error/empty state.
- **Cancelled picker (camera/gallery/file browser)**: `picked == null` is
  checked and the flow silently returns — no error shown, matching the
  existing OCR/Handwriting cancellation behavior.
- **Q&A failures**: caught locally within the Q&A panel (`_qaError`) so a
  failed question doesn't lose the already-analyzed document or crash the
  screen — the person can just try asking again.
- **Screen-level safety net**: `_run()`'s outer `catch (_)` guarantees that
  even a completely unanticipated exception (e.g. a `TypeError` from a
  pathological Gemini reply) is caught and shown as a generic, safe error
  message rather than crashing the app.

## Verification (Static Only)

**Flutter/Android SDK is not available in this environment, so no
`flutter build` / `flutter analyze` / `flutter test` was run or claimed.**
The following static checks were performed instead:

1. ✅ Enumerated every modified file via `git diff --cached --name-only`
   (5 files: 3 added, 2 modified) — matches the intended scope exactly.
2. ✅ `git diff --check` — clean, no whitespace/conflict-marker errors.
3. ✅ Custom bracket-balance checker (tracks `()`/`[]`/`{}` across strings
   and comments) run against all 5 changed files — all report "balanced."
4. ✅ Manually cross-checked every new call site against the actual source
   of the function/class it calls (`AttachmentProcessorService.process`,
   `ProcessedAttachment` fields, `AttachmentException.message`,
   `GeminiService.sendMessage` signature, `GeminiException.message`,
   `AttachmentService.pickFromCamera/pickFromGallery/pickDocument`,
   `ChatAttachmentKind` enum values, `AttachmentResult` fields).
5. ✅ Confirmed no other exhaustive `switch (AttachmentType ...)` in the
   codebase breaks from the widened enum — `AttachmentProcessorService.classify()`
   uses `if`/`==` checks (not an exhaustive switch), and the two switches in
   `chat_screen.dart` were both updated with the new case.
6. ✅ Grepped every changed file's import list and confirmed every import is
   actually referenced (no unused imports left behind).
7. ✅ Removed an unused-field risk in `_FileBadge` (now actually displays the
   `name` it was passed) and hardened two brittle `as String?` casts into a
   null-safe `_asStringOrNull()` helper, so a Gemini reply with an
   unexpected JSON field type can't throw an uncaught `TypeError`.
8. ✅ Confirmed Step 38's `text_recognition_service.dart`,
   `text_scan_result_screen.dart`, and `image_source_sheet.dart` are byte-
   for-byte untouched (absent from the changed-files list).
9. ✅ Confirmed `pak_home_widgets.dart` (Step 37 Quick Action pills) is
   absent from the changed-files list — untouched.
10. ✅ Confirmed `pubspec.yaml` is absent from the changed-files list — zero
    new dependencies.

## Known Limitations

- **PDF table reconstruction is text-based, not layout-based.** PDFs go
  through the existing `syncfusion_flutter_pdf` `PdfTextExtractor`, which
  extracts linear text without grid/column geometry. Gemini reconstructs
  tables from that linearized text as best it can, marking unclear cells —
  this is generally reliable for simple tables but can struggle with
  complex/nested tables in PDFs. Table reconstruction from an **image** of
  a document (camera/gallery) is more reliable, since Gemini's vision model
  sees the actual table grid.
- **Only images and PDFs are supported as input**, via a dedicated
  Camera/Gallery/PDF picker — matching the scope of Step 38's OCR/
  Handwriting entry point. Generic files (.txt/.csv/.md/etc., available
  elsewhere via the "Files" picker) are not wired into Document AI in this
  step, to keep the picker and prompts focused and avoid scope creep.
- **Q&A re-supplies the whole document on every question** (per the
  existing `GeminiService` per-turn-attachment behavior already documented
  in that file) rather than maintaining a server-side session — consistent
  with how the rest of the app already handles image attachments in
  follow-up turns, but means each question is its own full request.
- **No Flutter build was run** in this environment (SDK unavailable), so
  this verification is static-only, as required. A real
  `flutter analyze` / on-device run is recommended before shipping.

## Manual Testing Checklist

- [ ] Open the attachment sheet from Chat → confirm "Document AI" appears
      as a 7th option after "Handwriting", same visual style.
- [ ] Tap "Document AI" → confirm the Camera/Gallery/PDF sheet appears.
- [ ] Pick a photo of a document with clear paragraphs → confirm summary,
      key points, and headings appear; confirm "Generated" vs "Extracted"
      badges render correctly.
- [ ] Pick a photo of a document containing a table → confirm the table
      renders in a horizontally-scrollable grid with no overflow on a
      narrow-width test, and that any genuinely illegible cell shows
      `[unclear]` in italic.
- [ ] Pick a PDF with a table → confirm best-effort table reconstruction
      still appears (expect lower fidelity than the image case, per Known
      Limitations).
- [ ] Tap each quick-action chip (Summarize, Key points, Read tables,
      Important info, Ask about this) → confirm each scrolls to (or
      focuses) the right section.
- [ ] In the Q&A panel, ask a question whose answer is in the document →
      confirm a grounded answer appears.
- [ ] Ask a question whose answer is NOT in the document → confirm the
      "couldn't find that information" response appears, not a guess.
- [ ] Tap "Copy" → confirm the summary is copied and a snackbar appears.
- [ ] Tap "Use in Chat" → confirm the screen closes and the summary fills
      the chat composer (not sent automatically).
- [ ] Cancel the Camera/Gallery/PDF picker after opening "Document AI" →
      confirm nothing happens (no crash, no error toast).
- [ ] Pick a corrupt/empty/unsupported file → confirm a clear error state
      with "Try again", not a crash.
- [ ] Turn off the internet or clear the Gemini API key → confirm a clear
      Gemini-error message, not a crash.
- [ ] Re-run Step 38's OCR ("Scan Text") and Handwriting flows → confirm
      both work exactly as before, completely unaffected.
- [ ] Re-check the Home screen's Step 37 Quick Action pills → confirm
      unchanged.
