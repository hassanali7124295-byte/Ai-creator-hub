# CHANGE REPORT — STEP 38: OCR + Handwriting Recognition

## Summary

Added two new features to Pak AI, entered through the existing attachment
sheet: **Scan Text (OCR)** for printed text and **Handwriting Recognition**
for handwritten notes. Both reuse the app's existing image-attachment
pipeline (`AttachmentProcessorService`) and existing Gemini vision call
(`GeminiService.sendMessage`) — no new image pipeline, no new dependency,
no new permissions, and no changes to Home, chat bubbles, the input bar,
the AppBar, or the Step 37 Quick Action pills.

## Architecture investigation (performed before writing any code)

- **Image attachment flow**: `AttachmentService` (image_picker/file_picker
  wrapper) → `AttachmentProcessorService.process()` (validate, downscale,
  re-encode as JPEG, produce a `GeminiInlinePart`) → `GeminiService`.
- **Image-understanding service**: `GeminiService.sendMessage()` /
  `sendMessageWithImages()` already sends inline image data to Gemini and
  parses the text reply — this is the one and only vision call in the app.
- **Chat composer**: `ChatScreen._inputController`, already filled
  non-destructively (without sending) by `_applySuggestion()`.
- **Attachment sheet**: `showAttachmentSheet()` in `attachment_sheet.dart`,
  a single `AttachmentType` enum + bottom sheet of circular icon buttons.
- **Theme**: `ChatPalette.themeFor(context)` — the shared emerald palette
  every chat-scoped screen (Chat, Settings) wraps itself in via a local
  `Theme(...)` override.
- **Permissions**: camera/gallery access is already handled entirely by
  `image_picker` (no manifest/Info.plist changes exist for it in this
  project) — reused as-is.
- **pubspec.yaml**: reviewed; no OCR/ML package exists or was needed (see
  "Dependencies" below).
- Conclusion: extend the existing pipeline rather than add a second one.

## OCR implementation

- New `TextRecognitionService.recognize(image, mode: TextScanMode.ocr, source)`
  in `lib/core/services/text_recognition_service.dart`.
- The picked image is compressed/validated via the existing
  `AttachmentProcessorService.process()` (same downscale/re-encode/size
  checks every chat image attachment already goes through).
- The resulting `GeminiInlinePart` is sent through the existing
  `GeminiService.sendMessage()` with a dedicated OCR prompt instructing
  Gemini to transcribe printed text verbatim, preserving line/paragraph
  breaks, with no commentary, and to reply with a sentinel string if no
  text is found.
- A sentinel/empty reply is turned into a friendly
  `TextRecognitionException` ("No readable text was found in this image.").

## Handwriting implementation

- Same service, `mode: TextScanMode.handwriting`, same image-preparation
  path, same Gemini call — only the prompt differs.
- The handwriting prompt asks Gemini to transcribe carefully, mark any
  genuinely illegible word as `[illegible]` instead of guessing, and
  return a `CONFIDENCE: HIGH|MEDIUM|LOW` line followed by the transcription.
- The confidence line is parsed (`ScanConfidence` enum); if Gemini deviates
  from the format, the full reply is still shown rather than being lost.
- The result screen shows a visible "may contain mistakes" notice whenever
  confidence comes back `MEDIUM` or `LOW` — never silently presented as a
  perfect transcription.

## New files

| File | Purpose |
|---|---|
| `lib/core/services/text_recognition_service.dart` | OCR/handwriting logic — image prep (reused), Gemini call (reused), prompts, response parsing, exceptions. |
| `lib/widgets/image_source_sheet.dart` | Small Camera/Gallery-only picker sheet used by the scan flow, visually matching the main attachment sheet. |
| `lib/screens/text_scan_result_screen.dart` | Result screen: loading / success / error states, Copy + Use in Chat actions, low-confidence notice for handwriting. |

## Modified files

| File | Change |
|---|---|
| `lib/widgets/attachment_sheet.dart` | Added `ocr` and `handwriting` to `AttachmentType`; added their two option entries; changed the button layout from a single `Row` to a `Wrap` (`WrapAlignment.spaceEvenly`) so the two new buttons flow onto a second line — the original 4 buttons render identically to Step 37, now alongside 2 more. |
| `lib/screens/chat_screen.dart` | Added 3 imports. In `_openAttachmentSheet()`, routes `ocr`/`handwriting` to a new `_startTextScan()` method before the existing pending-attachment switch (which gained two `return`-only cases purely to stay exhaustive over the enum — unreachable in practice). Added `_startTextScan()`: opens `showImageSourceSheet`, picks a single image via the existing `AttachmentService`, pushes `TextScanResultScreen`, and on "Use in Chat" fills the composer via the existing `_applySuggestion()`. Nothing else in the file changed. |

## Dependencies added/changed

**None.** OCR and handwriting recognition both run through the existing
`GeminiService` vision call — no OCR/ML package was added to
`pubspec.yaml` (verified identical to Step 37).

## Permissions added/changed

**None.** Camera/gallery access reuses `image_picker`'s existing,
already-configured permission handling — the same calls
(`AttachmentService.pickFromCamera()` / `pickFromGallery()`) already used
elsewhere in the app.

## UI changes

- Attachment sheet: 2 new circular buttons ("Scan Text", "Handwriting"),
  same visual style as the existing 4, now wrapping onto a second row.
- New small Camera/Gallery chooser sheet (white, rounded, matches the main
  attachment sheet) shown after tapping either new option.
- New result screen (uses the existing emerald `ChatPalette` theme,
  rounded surfaces, and button styles matching Settings): image preview +
  spinner while loading; a bordered card with selectable recognized text,
  Copy and Use in Chat buttons on success; a low-confidence notice banner
  for uncertain handwriting; an error state with a "Try again" retry.
- Home, Quick Action pills, chat bubbles, input bar, AppBar, drawer,
  history, settings, theme, and background artwork: **untouched**.

## Error handling / edge cases covered

- No API key configured → existing `GeminiException` message surfaces as-is.
- Corrupted/unsupported/oversized image → caught by the existing
  `AttachmentProcessorService` validation, surfaced as a friendly error.
- No readable text / no discernible handwriting → explicit friendly error,
  never a blank or crashing result.
- Gemini request failure/timeout → existing `GeminiException` messages
  surface as-is (e.g. "Gemini is taking too long…").
- Image source cancelled (picker returns null) → flow quietly stops, no
  error shown.
- Camera/gallery access failure → same snackbar message already used by
  the main attachment flow.
- Any unexpected exception in the result screen → caught and shown as a
  generic friendly error rather than crashing.
- "Use in Chat" only fills the composer (`_applySuggestion`) — never sends
  automatically, and never starts a new conversation.

## Verification performed

- Bracket balance check (Python, string/comment-stripped) on every new and
  modified file — all balanced (see counts run during implementation).
- Full-project `diff -rq` against the Step 37 baseline: confirms only
  `lib/widgets/attachment_sheet.dart` and `lib/screens/chat_screen.dart`
  were modified, and exactly 3 new files were added — nothing else changed.
- `chat_bubble.dart` diffed byte-for-byte against Step 37 baseline: **unchanged**.
- `pak_home_widgets.dart` (Step 37 Quick Action pills) diffed byte-for-byte
  against Step 37 baseline: **unchanged**.
- `pubspec.yaml` diffed byte-for-byte against Step 37 baseline: **unchanged**.
- Searched for duplicate attachment/image/OCR pipelines: none found — the
  new service exclusively calls `AttachmentProcessorService.process()` and
  `GeminiService.sendMessage()`.
- Verified every new/changed symbol reference (`AttachmentException.message`,
  `GeminiException.message`, `GeminiService.sendMessage` signature,
  `AttachmentProcessorService.process` signature) against the actual
  source, not from memory.
- Checked for unused imports across all new/changed files — none found.
- Checked for tabs/trailing whitespace in new/changed files — none found.
- `AttachmentType` enum: confirmed only one `switch` statement in the
  codebase switches over it (`chat_screen.dart`); it is exhaustive.

## Not testable in this environment

- Flutter/Android SDK is unavailable here (no network access to fetch the
  toolchain), so `flutter analyze`, `flutter test`, and an actual build
  could not be run. Verification above is static/source-level only
  (bracket balance, symbol/signature cross-checks, diff-based scope
  checks). This should still be run in a real Flutter environment before
  release: `flutter analyze`, `flutter test`, and a manual pass through
  both Scan Text and Handwriting on a couple of real photos.
- Actual Gemini API responses (prompt adherence, e.g. whether it reliably
  emits the `CONFIDENCE:`/`TEXT:` format or the `NO_TEXT_FOUND` sentinel)
  could not be exercised live — the parser is defensive (falls back to
  showing the raw reply) specifically because of this.

## Next steps

1. Run `flutter pub get` (no dependency changes, but good practice) and
   `flutter analyze` / `flutter test` in a real Flutter environment.
2. Manually test both flows end-to-end: a printed-text photo, a
   screenshot, a handwritten note (clear and messy, to exercise the
   confidence banner), a no-text image, and a cancelled/denied permission
   case.
3. Confirm "Use in Chat" correctly populates the composer without sending,
   on both Android and iOS.
