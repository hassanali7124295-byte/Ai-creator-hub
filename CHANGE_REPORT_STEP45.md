# CHANGE REPORT — STEP 45

## Root Cause

`AttachmentProcessorService.process()` in
`lib/core/services/attachment_processor_service.dart` has a `switch (kind)`
over `ChatAttachmentKind` (around line 155) that only handled `image`,
`pdf`, and `file`. Step 43 added a fourth enum value, `audio`
(`ChatAttachmentKind.audio`, in `lib/models/chat_attachment.dart`), but
this particular switch was never updated for it. Dart's exhaustiveness
checker for `switch` over an enum requires every value to be handled, so
compilation failed with:

```
lib/core/services/attachment_processor_service.dart:155:13:
Error: The type 'ChatAttachmentKind' is not exhaustively matched by the switch cases since it doesn't match 'ChatAttachmentKind.audio'.
```

This is a hard compile-time error, so it blocked `flutter build apk
--release` in CI regardless of the Step 44 `record`/`record_linux` fix
already being in place.

## Exact File Changed

- `lib/core/services/attachment_processor_service.dart` — one new `case`
  branch added inside the existing `switch (kind)` in `process()`. Nothing
  else in the file was touched.

No other file was modified.

## Exact Fix

Added an explicit `case ChatAttachmentKind.audio:` branch that throws
`AttachmentException` instead of processing anything:

```dart
case ChatAttachmentKind.audio:
  // Step 45: `classify()` above never returns `.audio` — voice
  // messages are recorded by `VoiceRecorderService` and built as a
  // `ChatAttachment` directly in `chat_screen.dart`, entirely
  // bypassing this picker-driven pipeline (see the class doc comment
  // and `ChatAttachmentKind.audio`'s doc comment). So this case is
  // unreachable in practice; it exists only so the switch is
  // exhaustive. It deliberately throws rather than silently falling
  // through to image/PDF/generic-file handling, so an audio
  // attachment can never accidentally be sent to Gemini, OCR, or
  // document intelligence if this method is ever reached with one.
  throw AttachmentException(
    'Voice messages are handled separately and should never be '
    'processed here.',
  );
```

## Why Audio Must Not Go Through AttachmentProcessorService's Image/PDF Processing

Tracing every use of `ChatAttachmentKind.audio` and of
`AttachmentProcessorService` in the codebase confirms voice messages are,
by design, a completely separate path from the picker/Gemini attachment
pipeline:

- `AttachmentProcessorService.classify(source, mimeType)` — the only
  function that decides a `ChatAttachmentKind` for anything passed into
  `process()` — can only return `image`, `pdf`, or `file`. It has no
  branch that ever produces `audio`.
- Voice messages are recorded on-device by `VoiceRecorderService` (mic →
  temp `.m4a` file), and the resulting `ChatAttachment` is constructed
  directly with `kind: ChatAttachmentKind.audio` in `chat_screen.dart`
  (composer send path and the sent-message-bubble path) — never by calling
  `AttachmentProcessorService.process()`.
- `ChatAttachmentKind.audio`'s own doc comment in `chat_attachment.dart`
  states this explicitly: unlike `image`/`pdf`/`file`, an audio attachment
  "is never handed to `AttachmentProcessorService`/Gemini — it's a
  self-contained recorded voice message that lives entirely in chat
  history and plays back on-device."
- `AttachmentPreview` (in `attachment_preview.dart`) already special-cases
  `kind == ChatAttachmentKind.audio` before it ever reaches the
  icon/PDF/file chip rendering, giving it its own play/progress/duration
  row instead.

So routing `audio` through `_processImage`/`_processPdf`/
`_processGenericFile` would be actively wrong even if it were somehow
reached: it would try to JPEG-decode, PDF-parse, or mime-allow-list-check
raw recorded audio bytes, fail or produce garbage, and — worse — could
send a person's recorded voice message to Gemini as if it were a document
or image, which is not the Step 43 design. The new `case` throws instead,
which:

1. Makes the switch exhaustive (fixes the build), and
2. Preserves the existing invariant that audio never flows through this
   service's image/PDF/generic-file code paths, with a clear error message
   if that invariant is ever accidentally violated in the future (e.g. by
   a future change to `classify()`).

## Search for Other `ChatAttachmentKind` Switches

Searched all of `lib/` for switches over `ChatAttachmentKind` (and every
file referencing the enum at all):

| File | Switch | Status |
|---|---|---|
| `lib/models/chat_attachment.dart` | `wireName` getter (`switch (this)`) | Already exhaustive — handles `image`, `pdf`, `file`, `audio` (unchanged, no fix needed) |
| `lib/core/services/attachment_processor_service.dart` | `process()` (`switch (kind)`) | **Fixed in this step** — `audio` case added |
| `lib/widgets/attachment_preview.dart` | `_icon` getter (`switch (attachment.kind)`) | Already exhaustive — handles `image`, `pdf`, `file`, `audio` (unchanged, no fix needed) |
| `lib/screens/chat_screen.dart` | No `switch` over `ChatAttachmentKind` — only `if`/`==` comparisons (e.g. `kind == ChatAttachmentKind.image`), which aren't exhaustiveness-checked | No change needed |
| `lib/core/services/document_intelligence_service.dart` | References `ChatAttachmentKind` as a field type only; its one `switch` is over a different enum (`request.type`) | Not applicable, no change needed |

After this change, every `switch` over `ChatAttachmentKind` in `lib/` is
exhaustive.

## Verification Performed

This sandbox still has **no Flutter/Dart SDK installed** (`flutter`/`dart`
are not on `PATH`), **no network egress**, and the project has no `.git`
directory (same constraints as Step 44). So the following could **not**
actually be executed here, and none are claimed to have passed:

- `flutter analyze` — **NOT RUN** (no SDK)
- `flutter test` — **NOT RUN** (no SDK)
- `flutter build apk --release` — **NOT RUN** (no SDK, no network)
- `git diff --check` — **NOT RUN** (no `.git` directory in this project
  state — same as noted in Step 44's report; this uploaded/working tree
  has never had one)

**Static verification performed instead:**

- Read the full `process()` method and confirmed the new `case` sits
  inside the existing `switch (kind) { ... }` block with correct Dart
  syntax (comma-free `case` label, single statement, matching brace
  nesting — brace count in the file is balanced: 60 open / 60 close).
- Confirmed `ChatAttachmentKind` still has exactly 4 values
  (`image, pdf, file, audio`) in `chat_attachment.dart`, matching the 4
  cases now present in the fixed switch.
- Grepped every file under `lib/` for `ChatAttachmentKind` and manually
  checked each `switch` against it (table above) — all exhaustive.
- Confirmed `pubspec.yaml` still reads `record: ^6.2.1` (Step 44's value,
  byte-for-byte unchanged) and that no other line in it was touched.
- Confirmed `AttachmentException` (thrown in the new case) is already
  defined and imported in this same file — no new import needed.
- Confirmed no new dependency was added to `pubspec.yaml`.

**No real build was run, so it is not confirmed whether
`flutter build apk --release` now succeeds.** This fix removes the one
specific compile error quoted in the task, based on direct reading of the
Dart exhaustiveness rule and the surrounding code — it needs to be run
through your actual GitHub Actions workflow (or a local Flutter
environment) to confirm the APK now builds. If any other compile error
follows (unrelated to this switch), that will need a separate follow-up
step.

## Step 40–44 Compatibility

- Voice-message architecture unchanged: `VoiceRecorderService`,
  `VoicePlaybackService`, and the composer's record/preview/send flow in
  `chat_screen.dart` were not touched.
- `ChatAttachmentKind.audio` was not removed or renamed.
- No default/catch-all case was added to hide the problem — the fix is an
  explicit, named `case` for `audio`.
- `pubspec.yaml` is unchanged from Step 44 (`record: ^6.2.1` intact); no
  new dependency added.
- Gradle/AGP/Kotlin versions untouched.
- Gemini/API architecture untouched.
- `chat_screen.dart`, `attachment_preview.dart`, `chat_bubble.dart`,
  `voice_recorder_service.dart` were inspected (per the task) but not
  modified — they already handle `audio` correctly wherever relevant.

## Manual Voice-Message Testing Checklist

Not executed — no device/emulator or Flutter SDK available in this
environment. Still needs to be verified once built for real:

- [ ] Start recording
- [ ] Cancel recording
- [ ] Preview recording
- [ ] Play preview
- [ ] Send voice message
- [ ] Play sent voice message
- [ ] Voice message never triggers an "unsupported file" or Gemini-upload
      error (confirms the new `audio` case is never actually reached in
      the running app, as expected)
- [ ] Normal text chat unaffected
- [ ] Image attachment send/processing unaffected
- [ ] PDF attachment send/processing unaffected
- [ ] Generic text-file attachment send/processing unaffected
- [ ] Existing OCR unaffected
- [ ] Existing handwriting recognition unaffected
- [ ] Existing Document AI unaffected

## Known Limitations

- No Flutter/Dart SDK, no network, and no `.git` history were available in
  this environment, so `flutter analyze` / `flutter test` /
  `flutter build apk --release` / `git diff --check` could not be run.
  This report documents static verification only; the real CI run is
  still required to confirm the APK now builds successfully.
- Because `classify()` never produces `ChatAttachmentKind.audio`, the new
  `case` is expected to be dead code at runtime. It is included solely to
  satisfy Dart's compile-time exhaustiveness check, per the task's
  explicit instruction not to use a default case to hide the problem.
