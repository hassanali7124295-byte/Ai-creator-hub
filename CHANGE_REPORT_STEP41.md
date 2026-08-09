# STEP 41 — Document Intelligence Reliability & Timeout Fix

## 1. Problem

During real-device testing, attaching a document/image and asking for
something like "Summarize a file" would show "Analyzing the document…" and
could stay there for 5+ minutes with no result and no error — leaving the
user assuming the app had frozen. Plain text chat ("Hello") was unaffected
(~8–10s).

## 2. Root cause discovered

The full call chain was traced end-to-end:

`ChatScreen._sendMessage()` → `ChatScreen._runSmartCapability()` →
`DocumentIntelligenceService.analyze()` / `.askQuestion()` (and
`TextRecognitionService.recognizeFromPart()` for OCR/handwriting) →
`GeminiService.sendMessage()` → `http.post(...).timeout(...)`.

`GeminiService.sendMessage()` already had its own internal per-request
timeout (30s plain / 60s "heavy" text-and-PDF-text / **180s for image
attachments**), so a single Gemini call was never *literally* infinite.
The actual problem is that this 180-second ceiling is:

- **shared** across every Gemini call in the app (plain chat, generic
  image/PDF chat, OCR, handwriting, and document analysis all funnel
  through the same `sendMessage()`), so it could not be shortened there
  without also affecting normal chat and the generic understanding flow
  (explicitly out of scope for this step), and
- **too long** for the specific chat-native "Analyzing the document…" /
  "Reading your document…" / "Reading the handwriting…" moment, which the
  spec targets at 60–90s — 180s (plus any real-world variance around it)
  is what produced the "stuck for 5+ minutes" experience users actually
  hit.

There was no bug causing a truly unbounded/infinite wait (no missing
`await`, no runaway retry loop, no un-timed attachment processing on this
path — `AttachmentProcessorService.process()` for images/PDFs already
finishes, off the UI isolate via `compute()`, *before* the "Analyzing the
document…" bubble even appears, since Step 40 passes the already-processed
attachment into `_runSmartCapability`). The fix needed was a shorter,
purpose-specific deadline scoped only to the smart-document operation.

## 3. Exact files changed

- `lib/screens/chat_screen.dart` — **only file changed.**

No other file (including `document_intelligence_service.dart`,
`gemini_service.dart`, `text_recognition_service.dart`,
`attachment_processor_service.dart`, `pubspec.yaml`, or any widget/UI file)
was modified.

## 4. Exact timeout/deadline behavior

Added one new constant:

```dart
static const Duration _kSmartOperationTimeout = Duration(seconds: 90);
```

Applied via `.timeout(_kSmartOperationTimeout, onTimeout: () => throw ...)`
at exactly three call sites, all inside `chat_screen.dart`:

1. `TextRecognitionService.recognizeFromPart(...)` (OCR / Handwriting) in
   `_runSmartCapability`.
2. `DocumentIntelligenceService.analyze(doc)` (Document Intelligence
   summary) in `_runSmartCapability`.
3. `DocumentIntelligenceService.askQuestion(...)` (Document Q&A follow-up)
   in `_runDocumentFollowUp`.

This is a **narrowly-scoped, additive deadline** — `GeminiService`'s own
internal timeouts (used by every call in the app, including these three)
are completely untouched. The 90s outer deadline simply guarantees that,
however long anything deeper in the chain takes (Gemini's own up-to-180s
wait, a slow network, etc.), the smart-document loading state can never
be shown for longer than 90 seconds. Plain text chat and the generic
image/PDF understanding flow (`GeminiService.sendMessageWithImages`, used
when no smart intent matches) are not touched by this change at all and
keep their existing (pre-Step-41) timeout behavior.

90s was chosen as the upper end of the requested 60–90s range, to avoid
routinely killing genuinely slow-but-successful analyses (larger PDFs,
weaker connections) while still bringing the worst case down from 5+
minutes to 90 seconds.

## 5. Retry behavior

Unchanged and preserved exactly as Step 40 built it. When the new timeout
fires, it throws the *same* exception types (`TextRecognitionException` /
`DocumentIntelligenceException`) the rest of the code already expects and
catches — so it flows straight into the existing
`_replaceWithSmartError(insertIndex, message, retryAction)` path, which:

- shows a normal inline error bubble (not a raw `TimeoutException`),
- wires up the existing Retry button (`_smartRetryAction`), which re-runs
  only the failed capability against the same already-processed
  `ProcessedAttachment` / `PreparedDocument` — no re-picking the file, no
  re-processing it.

No changes were needed to the retry mechanism itself.

## 6. Loading-state cleanup

Unchanged and preserved. Both `_runSmartCapability` and
`_runDocumentFollowUp` already wrap their work in `try`/`catch`/`finally`,
and the `finally` block already unconditionally resets
`_isSending`/`_isSmartProcessing`/`_smartProcessingIndex`. Because the new
timeout throws through the same `try` block, that `finally` still runs on
a timeout exactly as it does on any other failure — so
`_isSmartProcessing` cannot get stuck `true`. This step's actual
improvement here: the *maximum* time that block could be stuck true before
(bounded only by the shared 180s Gemini timeout, plus real-world overrun)
is now hard-capped at 90s.

## 7. Conversation/stale-request safety

No changes needed — already correctly handled by Step 40. Both
`_switchConversation()` and `_startNewChat()` return immediately
(`if (id == _conversationId || _isSending) return;` / `if (_isSending) return;`)
while a smart-document operation is in flight, since `_isSending` stays
`true` for its entire duration. This step tightens that window (max 90s
instead of unbounded), which only makes this guard's practical exposure
smaller.

## 8. Large-document handling

Not changed. `AttachmentProcessorService`'s existing PDF text cap
(`_maxPdfTextChars` = 120,000 chars, with truncation noted in the folded
prompt) and image downscale/compression (`_maxImageDimension` = 1600px,
target ≤3MB) were already in place from prior steps and are untouched.

## 9. Error handling

Friendly, existing-pattern messages only — no raw exceptions/stack traces
are ever shown:

- OCR/Handwriting timeout: "This is taking too long. Please try again."
- Document analysis timeout: "Document analysis took too long. Please try
  again."
- Document Q&A timeout: "This is taking too long. Please try again."

These are thrown as the existing `TextRecognitionException` /
`DocumentIntelligenceException` types, so they're caught by the existing
`on TextRecognitionException catch` / `on DocumentIntelligenceException
catch` blocks — no new exception classes were introduced, and no raw
`TimeoutException` can ever reach the UI.

## 10. Confirmation Step 40 UX remains intact

- Attachment sheet unchanged (Camera / Gallery / Files / PDF only) — file
  not touched.
- No Scan Text / Handwriting / Document AI buttons or separate screens
  reintroduced — `pak_home_widgets.dart` and the standalone Step 39
  screens were not touched.
- Results still render inline in chat via the existing
  `DocumentResultCard` / plain chat bubble path — no navigation added.
- Generic image/PDF fallback (`_SmartIntent.none` → existing
  `sendMessageWithImages` flow) is completely untouched.
- Document follow-up Q&A behavior, and never clearing `_activeDocument` on
  a failed Q&A, are both preserved exactly as before.
- Confirmed via diff against the Step 40 baseline that every file except
  `lib/screens/chat_screen.dart` is byte-identical, and that
  `pubspec.yaml` has zero changes (no new dependencies).

## 11. Verification performed

- Manually traced the full call chain in the actual repository code (not
  guessed) as described in Section 2.
- Diffed the modified file against the Step 40 baseline (`diff -u`) and
  confirmed the change set is exactly the three `.timeout(...)` additions
  plus the new constant/comment — nothing else in the 3,347-line file was
  touched.
- Verified every other file in `lib/` and `pubspec.yaml` is byte-identical
  to the Step 40 baseline (checksummed).
- Verified balanced parentheses/braces/brackets in the modified file
  (mechanical sanity check, not a substitute for a real compile).
- **Flutter/Android SDK is not available in this environment, so
  `flutter analyze`, `flutter test`, and a real build could not be run.**
  No build/test success is being claimed. `git` was also not available
  as a usable repo here (this was worked from an extracted zip rather
  than a git checkout), so `git diff --check` / `git diff --name-only`
  as literally specified could not be run either — the file-comparison
  checks above cover the same ground manually.

## 12. Known limitations

- This is a client-side deadline only: it stops the app from waiting
  past 90s, but it does not (and cannot) cancel the underlying in-flight
  HTTP request to Gemini — that request keeps running in the background
  and is simply ignored when it eventually completes. This is standard
  Dart `Future.timeout()` behavior and matches how the app's existing
  180s/60s/30s timeouts already work.
- 90s is a heuristic upper bound, not a guarantee that no legitimate
  analysis will ever be cut off — a very large document on a very slow
  connection could still hit it and require a Retry tap. This matches the
  task's own stated target range (60–90s) and its instruction not to make
  the timeout so short that normal analysis is routinely killed.
- The underlying shared 180s image-attachment timeout in
  `GeminiService.sendMessage()` was intentionally left as-is (per the
  task's instruction not to modify global Gemini timeout behavior); it
  simply becomes unreachable in practice for the three smart-document call
  sites now that the tighter 90s deadline sits in front of it.
- Because no Flutter/Android SDK is available in this environment, this
  fix has not been build- or runtime-verified here — please run the
  manual testing checklist below on your Android phone.

## 13. Manual testing checklist

- [ ] Normal "Hello" still responds normally (~8–10s), unaffected.
- [ ] Attach a normal document/image and request a summary — "Analyzing
      the document…" appears immediately, then the result appears inline
      in chat as before.
- [ ] Document analysis never remains stuck beyond ~90 seconds even on a
      slow/flaky connection.
- [ ] If it does time out, a friendly inline error appears ("Document
      analysis took too long. Please try again.") — not a raw exception.
- [ ] Retry button appears on that error bubble.
- [ ] Tapping Retry does **not** reopen the Camera/Gallery/Files/PDF
      picker.
- [ ] Tapping Retry reuses the already-picked/processed document (no
      re-selecting or re-reading the file).
- [ ] Document Q&A ("Is document mein total amount kya hai?") still works
      normally.
- [ ] A Document Q&A timeout keeps `_activeDocument` intact — you can
      still ask a follow-up without re-attaching.
- [ ] OCR ("extract text") still works and still bounded similarly.
- [ ] Handwriting recognition still works and still bounded similarly.
- [ ] Generic image/PDF understanding (e.g. "What do you see?" with no
      smart-intent keyword) is unaffected — same as before Step 41.
- [ ] Sending a normal unrelated chat message after a document analysis
      works normally.
- [ ] Switching conversation or starting a new chat while
      "Analyzing the document…" is showing is blocked exactly as before
      (Step 40's existing `_isSending` guard) — no old result appears in
      the wrong conversation.
- [ ] No loading indicator remains permanently visible after
      success, failure, or timeout.
- [ ] Confirm no new dependencies were added (`pubspec.yaml` unchanged).
- [ ] Confirm the attachment sheet still only shows Camera / Gallery /
      Files / PDF.
