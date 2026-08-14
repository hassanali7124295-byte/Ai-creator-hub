# CHANGE_REPORT_STEP60.md

## Scope
Step 60 covered only the two reported runtime problems: corrupted Q&A
content in the generated PDF, and "Download PDF" not performing a real
download. The PDF intent detector, Dark Mode, Light Mode, chat UI/input
bar/bubbles/navigation/settings, the existing PDF read/extract feature,
Gemini/API logic, and branding were not touched.

## Part 1 — data trace
`_extractQaPairs` in `chat_screen.dart` (unchanged this step) pairs each
user message with the assistant reply immediately after it and trims both,
so the strings handed to `PdfExportService.generate` are the same objects
already rendered in the chat bubbles — no truncation happens before the PDF
service. This is now provable at runtime, not just by reading the code: the
service logs `PDF_EXPORT_QA_COUNT`, then for every pair
`PDF_EXPORT_Q_INDEX` / `PDF_EXPORT_Q_TEXT` / `PDF_EXPORT_Q_LENGTH` /
`PDF_EXPORT_A_TEXT` / `PDF_EXPORT_A_LENGTH` (text previews are length-capped
and newline-flattened for Logcat, not truncated in the actual PDF). If a
future report says the PDF is missing text again, compare these log lines
against the chat bubble first — if they already look wrong here, the bug is
upstream of the PDF service; if they look right here but still render
wrong, it's in the drawing layer below.

That data-flow trace, plus the screenshot symptom itself (digits and
punctuation visible, letters missing) pointed at the drawing/font layer,
not the data layer — confirmed by Problem 1's root cause below.

## Problem 1 root cause — corrupted Q&A content
Step 59 added Unicode-text support by reading a font file straight from
`/system/fonts/` on-device and handing its raw bytes to Syncfusion's
`PdfTrueTypeFont`. That's unsafe on real devices for two reasons, and
either one produces exactly the reported symptom:

1. **TrueType Collections.** Several Android system font files are a
   `.ttc` — multiple font faces packed behind one shared glyph table,
   identified by a `ttcf` magic number instead of a plain sfnt version tag.
   `PdfTrueTypeFont` expects a single-face file. Fed a collection's raw
   bytes, it misreads the table directory: some universal low glyph
   indices (digits, basic punctuation) still happen to land close to the
   right glyph, while the rest of the character-to-glyph mapping is
   garbage — visible letters go missing, stray digits/punctuation survive.
2. **Variable fonts.** Some system fonts are a single variable outline
   (marked by an `fvar` table) reshaped per weight at render time rather
   than each weight having its own fixed outline. Syncfusion's TrueType
   parser isn't guaranteed to resolve those outlines correctly either,
   producing the same class of corruption.

Step 59's font code loaded whichever candidate path existed and only
guarded against an outright *exception* — it had no way to catch a font
that loads "successfully" but is silently wrong, which is exactly what
happened.

## Problem 2 root cause — "Download PDF" wasn't a download
The button in `pdf_export_result_card.dart` only ever called
`Share.shareXFiles(...)`, which opens the system share sheet. That can be
used to save a copy via an app the user picks, but it is not itself a
download — nothing wrote the PDF into the device's Downloads, and if the
person dismissed the share sheet instead of picking a save target, nothing
was saved anywhere. There was no separate download codepath at all.

## Files changed
- `lib/core/services/pdf_export_service.dart`
- `lib/widgets/pdf_export_result_card.dart`
- `pubspec.yaml` (one new dependency, see below)

No other file was opened or modified.

## Exact fixes

### Problem 1 — font validation + defensive drawing (`pdf_export_service.dart`)
- `_looksLikeUsableSfnt(bytes)` — rejects a candidate font file before it's
  ever trusted:
  - `_isTrueTypeCollection` rejects anything starting with the `ttcf`
    collection magic number.
  - `_hasPlainSfntVersion` requires a plain, static sfnt version tag
    (`0x00010000`, `'true'`, or `'OTTO'`).
  - `_hasVariableFontTable` scans the sfnt table directory for an `fvar`
    table and rejects the file if present.
- `_tryBuildAndVerifyFont(bytes, path)` — even after a file passes those
  checks, it's loaded and sanity-checked by measuring a short known probe
  string (`'Aa0 .,'`); a zero/negative or wildly disproportionate measured
  width means it loaded "successfully" but wrong, so it's rejected too.
- `_findSystemUnicodeFont()` now tries every candidate path in order
  (the list was also widened) until one both passes validation and
  measures sane, caching the first success for the app's lifetime. If none
  qualify, it logs `PDF_EXPORT_UNICODE_FONT_UNAVAILABLE` and non-Latin text
  falls back to the standard font rather than ever being drawn with a
  suspect one — Latin (English/Roman Urdu) output is completely unaffected
  either way, and Urdu-script support is never disabled outright, only
  skipped for a specific bad file in favor of the next candidate.
- `_drawTextSafely(...)` wraps every text-drawing call: if a specific
  block still throws despite the above (belt-and-suspenders), it logs
  `PDF_EXPORT_TEXT_DRAW_FAILED` + the stack trace and redraws that one
  block with the plain standard font instead of letting the whole export
  fail or that block silently vanish.
- Added the Part 1 per-pair logging described above
  (`PDF_EXPORT_QA_COUNT`/`_Q_INDEX`/`_Q_TEXT`/`_Q_LENGTH`/`_A_TEXT`/
  `_A_LENGTH`).

The actual text-layout approach (Syncfusion `PdfTextElement` +
`PdfLayoutFormat(layoutType: PdfLayoutType.paginate)`, auto-flowing each
Question/Answer block across pages by chaining each draw's resulting page
and Y-position into the next) was already correct and is unchanged —
Problem 1 was the font feeding it corrupted glyphs, not the layout API
itself.

### Problem 2 — real Download action (`pdf_export_result_card.dart`)
- Added `file_saver: ^0.2.14` to `pubspec.yaml` — a small, free,
  open-source (MIT), actively maintained package whose only job is saving
  bytes into the platform's standard save location. On Android it writes
  through the scoped-storage-safe MediaStore Downloads API (no broad
  storage permission prompt, no deprecated direct
  `/storage/emulated/0/Download` path access), matching the "modern
  storage approach" requirement. No manual `AndroidManifest.xml` edit was
  needed or made — like the project's other native plugins (`record`,
  `speech_to_text`), it carries its own manifest entries.
- `_downloadPdf()` — new method: reads the already-generated PDF's bytes
  and calls `FileSaver.instance.saveFile(name:, bytes:, ext: 'pdf',
  mimeType: MimeType.pdf)`, which is the actual local save into Downloads.
  Success shows a "Saved to Downloads — <fileName>" confirmation; failure
  shows "PDF download failed. Please try again." and never claims success
  it didn't achieve. Logs `PDF_DOWNLOAD_START`, `PDF_DOWNLOAD_SUCCESS` +
  `PDF_DOWNLOAD_PATH`, or `PDF_DOWNLOAD_EXCEPTION` + stack trace.
- `_sharePdf()` — the prior `_openOrShare` logic, unchanged in behavior,
  renamed and kept as a distinct, secondary action (a small
  `IconButton.filledTonal` share icon next to the primary button) rather
  than being what "Download PDF" does. Filename generation
  (`PakAI_QA_<timestamp>.pdf`, already Android-filename-safe — digits,
  letters, and underscores only) is unchanged.

**Version-pin caveat:** `file_saver: ^0.2.14` was written from the
package's commonly documented `0.2.x` API surface
(`FileSaver.instance.saveFile(name:, bytes:, ext:, mimeType:)`); this
environment has no network access to run `flutter pub get` or check
pub.dev for the exact latest release, so the constraint's actual resolved
version — and a final confirmation that its parameter names haven't
shifted in a very recent release — should be checked the first time this
is built. The caret constraint will still pull whatever is newest and
compatible.

## Font/rendering solution (summary)
Same on-device, zero-network, zero-new-asset approach as Step 59 — reusing
Android's own system Unicode fonts — but a candidate file is now only
trusted after it (a) isn't a collection, (b) isn't a variable font, and
(c) measures real text sanely. Nothing about the actual layout/pagination
approach changed.

## Android download/storage solution (summary)
`file_saver`, backed by MediaStore on Android — no unsafe/deprecated
unrestricted filesystem access, no server, no upload, no paid API.

## Verification performed
No Android device/emulator is available in this environment, so
verification was static, the same as Step 59:
- Re-read the full rewritten `pdf_export_service.dart` and the new
  `pdf_export_result_card.dart` for brace/paren balance and control flow.
- Confirmed `chat_screen.dart`'s calls into `PdfExportService`/`PdfQaPair`/
  `PdfExportScope` still match the service's public API exactly (no
  signature changes were made) — grepped every call site.
- Confirmed the sfnt validation logic against the actual byte layout of an
  sfnt table directory (4-byte version tag, 2-byte table count at offset
  4, 16-byte table records starting at offset 12) and the well-documented
  `ttcf`/`fvar` markers.
- Confirmed `pubspec.yaml`'s only change is the one added `file_saver`
  line — no other dependency versions were touched.
- Traced all 9 Part 6 test scenarios (short/3-Q&A/long/multi-page/Roman
  Urdu/English/numbers-punctuation/Urdu script/mixed conversation) through
  `_extractQaPairs` → `generate` and confirmed each resolves through the
  same, now fully logged and font-validated, code path with no separate
  untested branch.

**This has not been confirmed by running the compiled app on a device** —
not possible in this environment. The added `PDF_EXPORT_Q_TEXT`/
`PDF_EXPORT_A_TEXT`/`PDF_EXPORT_UNICODE_FONT_*`/`PDF_DOWNLOAD_*` logging is
what will confirm both fixes (or point at the exact next cause) the next
time this is run on the real device that showed the original bug.

## Confirmations
- **PDF intent detection** (`_detectPdfExportIntent`): not opened.
- **Dark Mode / Light Mode**: not opened.
- **Existing PDF read/extract feature**
  (`attachment_processor_service.dart`): not opened.
- **Chat UI, input bar, chat bubbles, navigation, settings**: not opened,
  except the one `catch` block inside `_runPdfExport` from Step 59 (no
  further change there this step).
- **Gemini/API logic**: not opened.
- **No paid API / network service introduced**: `file_saver` writes to
  local device storage only; `syncfusion_flutter_pdf` (already a
  dependency) remains fully on-device; nothing in this step makes a
  network call.
