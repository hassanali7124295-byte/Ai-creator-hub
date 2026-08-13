# STEP 56 — AI Q&A → PDF Export Feature

## Files modified

- `lib/models/chat_message.dart` — added one new optional field,
  `pdfExportResult` (`Map<String, dynamic>?`), following the exact same
  pattern as the existing `documentResult` field from Step 40: serialized
  via `toJson()`/`fromJson()`, defaults to `null`, so chat history saved
  before this step loads exactly as before.
- `lib/widgets/chat_bubble.dart` — one new `else if` branch, placed right
  next to the existing `documentResult` branch: when an assistant
  message's `pdfExportResult` is set, render the new `PdfExportResultCard`
  instead of the normal Markdown body. Nothing else in the file changed —
  bubble chrome, the six-icon action row, streaming, all untouched.
- `lib/screens/chat_screen.dart` — three additions, all inside/near
  `_sendMessage()`:
  1. `_detectPdfExportIntent(text)` — local keyword-based intent check
     (see below).
  2. `_extractQaPairs(messages)` — pulls consecutive (user, AI-reply) pairs
     out of the existing `_messages` list.
  3. `_runPdfExport(scope)` — calls `PdfExportService.generate`, then adds
     either a `pdfExportResult` assistant message or a friendly error
     message.
  One new branch was inserted at the very top of the existing
  `if (attachmentsToSend.isEmpty) { ... }` block in `_sendMessage()`, so it
  only ever runs for plain-text turns (never touches the attachment/image/
  document pipeline). Everything else in that 4000+ line file — smart
  attachment routing, streaming, voice messages, document follow-up,
  history, etc. — is untouched.
- `pubspec.yaml` — no new dependency. Only a comment added above the
  existing `syncfusion_flutter_pdf` entry noting it's now also used for
  PDF *writing*.

## Files added

- `lib/core/services/pdf_export_service.dart` — the actual PDF generation.
- `lib/widgets/pdf_export_result_card.dart` — the "📄 PDF Ready" chat card.

## Dependencies

**No new package was added.** `syncfusion_flutter_pdf` (already a
dependency since Step 22A, used there for `PdfDocument` +
`PdfTextExtractor` to *read* PDF attachments) is reused here to *write*
one — the same package supports both directions. `path_provider` (already
used by the voice-recorder service) and `share_plus` (already used for the
AI-reply "Share" action) are reused for saving and opening/sharing the
generated file. No paid API, no API key, no network call of any kind.

## How PDF intent detection works

`_detectPdfExportIntent(text)` in `chat_screen.dart`:

1. Requires the word "pdf" (`\bpdf\b`) to appear at all — otherwise
   returns `null` immediately, so it can never fire on unrelated text.
2. Requires at least one export/action phrase from a fixed list (`bana
   do`, `banado`, `convert`, `download`, `export`, `create pdf`, `make a
   pdf`, `save as pdf`, `pdf mein de do`, etc., covering the English and
   Roman Urdu/Hindi variants named in the spec). A message that mentions
   "pdf" with none of these — e.g. **"What is a PDF?"** or **"PDF kya
   hota hai?"** — has no action cue and returns `null`, so it falls
   straight through to the normal Gemini chat flow untouched.
3. If both checks pass, a second small keyword list decides the scope:
   phrases like "poori chat" / "whole conversation" / "complete
   conversation" → `PdfExportScope.fullConversation`; phrases like "in
   sab" / "these questions and answers" / "multiple" →
   `PdfExportScope.allQa`; anything else (the common case, e.g. "Is Q/A ko
   PDF mein bana do") → `PdfExportScope.currentQa`.

This is a **local, zero-Gemini-call** check, run only for plain-text turns
with no attachment — it never intercepts an attachment-based send.

## How conversation/Q&A selection works

`_extractQaPairs()` walks the existing `_messages` list and pairs up every
consecutive (user message, non-error AI reply) — the same list already
rendered on screen and already persisted via `ConversationProvider`, no
new storage. The user's own PDF-request message (already appended to
`_messages` by the shared code above the branch) is excluded via
`sublist` before pairing, so it's never itself included as a "question."

- `currentQa` → just the last pair.
- `allQa` / `fullConversation` → every pair found. (The two scopes
  currently produce the same PDF content, differing only in the
  subtitle line printed at the top — "AI Conversation / Q&A" vs.
  "Complete Conversation Export." A future step could make
  `fullConversation` include non-paired standalone messages too if
  that distinction turns out to matter in practice — noted as a
  limitation below.)
- If no pairs are found (e.g. the very first message in a fresh chat is
  a PDF request), `PdfExportService.generate` throws a friendly
  `PdfExportException` instead of producing an empty/garbage PDF.

## How the PDF is generated and saved

`PdfExportService.generate()`:

- Builds a real `PdfDocument` via `syncfusion_flutter_pdf` — A4 pages,
  40pt margins, a "Pak AI" title in the app's emerald accent color, a
  subtitle, then a "Question" / "Answer" block per pair with clean
  spacing and a light divider between pairs.
- All text is drawn with `PdfTextElement` + `PdfLayoutFormat(layoutType:
  PdfLayoutType.paginate)`, which automatically starts a new page
  whenever a block overflows the current one — this is what gives real,
  automatic multi-page output with proper text wrapping for long AI
  answers, matching Syncfusion's own documented pattern for flowing text.
  Every character is real, selectable PDF text — no screenshots, no
  rasterized chat UI.
- Unicode/Urdu text renders as far as the built-in Helvetica standard
  font supports it (see Limitations).
- The finished PDF is saved to
  `<app documents directory>/pak_ai_exports/PakAI_QA_<timestamp>.pdf` —
  the app's own private storage, not a public Downloads folder.

## How Download/Open and Share work

There is no file-opening (`open_file`) or MediaStore/public-Downloads-save
plugin already in the project, and a direct public-Downloads write is the
exact kind of thing that's unreliable under modern Android scoped storage.
So the existing `share_plus` dependency — already used for the AI-reply
"Share" action — is reused for the result card's single **"Download PDF"**
button: it calls `Share.shareXFiles([XFile(path, mimeType:
'application/pdf')])`, which opens the system share sheet. From there the
person can save the file to Files/Google Drive/etc., or hand it straight
to any installed PDF viewer, which functionally covers both "Download"
and "Share" from the spec with one action that's guaranteed to work
without any new native code or permissions. This is a deliberate,
documented deviation from the spec's literal two-button
(`[Download PDF]` + optional `[Share]`) mock — flagged here rather than
adding a second button that would just call the same underlying share
sheet a second time.

The card also checks the file still exists on tap (in case the app's
cache was cleared since the PDF was generated) and shows a friendly
message instead of a silent failure if it's gone.

## Error handling

`PdfExportService.generate` never lets a raw exception escape — every
failure path (empty conversation, a generation error, a file-system
error) is caught and turned into a `PdfExportException` with the exact
user-facing message from the spec: *"Sorry, I couldn't create the PDF.
Please try again."* (or, for the specific empty-conversation case, a more
specific "there's no conversation yet" message). `_runPdfExport` in
`chat_screen.dart` catches that and adds a normal error-styled chat
bubble — the same `isError: true` styling already used elsewhere in the
app — rather than crashing or silently doing nothing.

## Confirmation: existing PDF reading/extraction feature untouched

`lib/core/services/attachment_processor_service.dart` (the file that owns
`PdfDocument`/`PdfTextExtractor` for reading/extracting attached PDFs) was
**not modified at all** — confirmed via `diff` against the Step 55
baseline. The PDF picker, attachment sheet, PDF preview, and PDF-as-
attachment AI flow are all byte-identical to before this step.

## Confirmation: Step 55 Dark Mode / Light Mode untouched

No theme file (`lib/core/theme/*`) was touched. `chat_bubble.dart`'s only
change is the one new `else if` branch described above — the existing
bubble colors, action row, streaming, and Step 32/48/52/53 styling are
byte-identical elsewhere in the file (confirmed via diff).

## Confirmation: no paid API/key added

Zero new dependencies. Zero network calls anywhere in the new code path —
`PdfExportService.generate` is 100% local file I/O plus in-memory PDF
construction.

## Verification performed

No local Flutter/Android SDK is available in this environment (same as
every prior step in this project) — `flutter analyze`/`flutter build`
could not be run directly; verification was manual/structural:

- Diffed the full project tree against the Step 55 baseline: confirmed
  only the 4 files above were modified and only the 2 new files were
  added — nothing else in the ~65-file project changed.
- Brace/paren/bracket balance checked on every touched/added Dart file.
- Every Syncfusion PDF API call used (`PdfDocument`, `pages.add()`,
  `pageSettings.size`/`margins.all`, `PdfTextElement.draw` with
  `PdfLayoutFormat(layoutType: PdfLayoutType.paginate)`,
  `result.bounds.bottom`, `page.getClientSize()`, `PdfPen`/
  `graphics.drawLine`, `document.save()`/`.dispose()`) was checked
  against Syncfusion's own official Flutter PDF documentation and
  pub.dev package docs to match real, current method signatures — this
  package was not used for *writing* PDFs anywhere else in the project
  before this step, so nothing existing could be copied from.
  `Share.shareXFiles`/`XFile` (from `share_plus`, already a project
  dependency) was checked the same way.
- Real device/CI build verification (this project's standard practice
  for every step, per the existing GitHub Actions workflow) still needs
  to happen on push, same as all prior steps.

This step was **not** run through an actual `flutter analyze`/build, so
per the project's own standing rule this isn't claimed as a build-verified
change — it's a careful, spec-matched, dependency-reused implementation
ready for that CI build to confirm.

## Limitations

- `allQa` and `fullConversation` currently produce identical PDF content
  (every paired Q&A found) — only the printed subtitle differs. A
  standalone message with no paired reply (or vice versa) is silently
  skipped rather than included as a "full conversation" transcript in
  the literal sense. Flagging this as a reasonable first pass rather than
  a perfect match to the spec's three-tier wording.
- Intent detection is keyword-based (same approach as the existing Step
  40/42 smart-attachment routing) — very unusual phrasings not on the
  action-cue list will fall through to a normal chat reply instead of
  triggering an export, matching the existing project's established,
  intentionally-simple local-parsing approach rather than adding a new
  Gemini call just to classify one message.
- Unicode/Urdu rendering is limited by whatever the standard Helvetica
  PDF font supports — Syncfusion's standard fonts are Latin-script only,
  so Urdu script itself (as opposed to Roman-Urdu written in Latin
  letters) may not render correctly. Adding a bundled Unicode/Urdu TTF
  font (via `PdfTrueTypeFont`) would fix this but wasn't done here to
  keep this step's footprint minimal — noted as a natural follow-up.
- The "Download PDF" button uses the system share sheet rather than a
  literal, separate Download action — see the "How Download/Open and
  Share work" section above for the reasoning.
