# STEP 42 — Voice Conversation + Natural-Language File Actions

## Summary

Two features, both additive on top of Steps 38–41:

- **Feature 1 — Voice Conversation:** already fully implemented in the
  existing codebase (mic button, `VoiceInputService`, voice → composer →
  review → Send flow, all the required error handling). One real gap was
  found and fixed: an active listening session wasn't cancelled when
  switching conversations / starting a new chat / clearing chat, which
  could leak a stray transcription into the wrong conversation's
  composer.
- **Feature 2 — Natural-Language File Actions:** extended Step 40's local
  intent router with five new document actions (notes, plain questions,
  MCQs, a language-aware explanation, and a table explanation), backed by
  a new `DocumentIntelligenceService.runAction()` that reuses the exact
  same Gemini call pattern (`_ask`) and Step 41 timeout protection as the
  existing `analyze()`/`askQuestion()`.

## Feature 1: Voice Conversation

Inspection of `chat_screen.dart` and `voice_input_service.dart` found this
feature already built and matching the spec closely:

- Tap mic → `_onVoiceTap()` → `VoiceInputService.ensureReady()` →
  `startListening()`; recognized words stream live into
  `_inputController` as partial results arrive (`onResult`), so the
  person can watch it fill in and edit it — nothing is auto-sent.
- Tap mic again → `stop()`, a brief "processing" beat, back to idle.
- The mic button shows a distinct listening state (animated equalizer)
  inline in the existing input bar — no new screen, no full-screen
  takeover.
- `VoiceInputService` already has a friendly message for every plugin
  error code (`error_permission`, `error_no_match`/timeout,
  `error_network`, `error_busy`, `error_audio_error`, etc.), surfaced via
  a SnackBar (`_showVoiceSnack`) — never a raw exception, never a crash.
- `_sendMessage()` already cancels any still-listening session before
  reading the composer, so a late speech result can't repopulate the
  field right after Send clears it.

**Gap found and fixed:** `_switchConversation()`, `_startNewChat()`, and
`_clearChat()` reset `_isSending`-guarded state but had no guard against
an *active listening session* (listening doesn't set `_isSending`), and
didn't cancel `VoiceInputService`. A person could tap the drawer to
switch conversations (or start new / clear chat) mid-listen, and a
still-arriving speech result would then land in the new/cleared
conversation's composer. Fixed by cancelling voice input
(`_voiceInput.cancel()`) and resetting `_micState` in all three methods,
mirroring the existing pattern already used in `_sendMessage()`.

No new voice/speech service was created — everything routes through the
existing `VoiceInputService`.

## Feature 2: Natural-Language File Actions

**Architecture** — extends Step 40's `_SmartIntent` enum (unchanged
values kept) with five more:

```dart
enum _SmartIntent {
  none, ocr, handwriting, documentIntel,   // Step 40, unchanged
  documentNotes, documentQuestions, documentMcqs,
  documentExplanation, documentTableExplain,   // Step 42, new
}
```

`_detectSmartIntent()` (still 100% local keyword matching — no Gemini
call) gained five new phrase groups, checked in priority order *before*
the existing `documentIntelPhrases` catch-all so more specific phrasing
wins:

1. `mcqPhrases` ("mcq", "mcqs", "multiple choice", "objective question…")
2. `questionPhrases` ("exam questions", "questions bana", "quiz bana"…)
3. `notesPhrases` ("short notes", "notes bana", "study notes"…)
4. `tableExplanation` — requires **both** a table word *and* an explain
   verb together (e.g. "table" + "explain"/"samjhao") — bare "table"
   alone still falls through to Step 40's existing full-analysis card,
   unchanged.
5. `explanation`/translation — requires **both** a named language
   ("urdu"/"hindi"/"english"/"roman urdu"/"roman hindi") *and* an
   explain/translate verb together — bare "samjhao" with no language
   named still falls through to `documentIntelPhrases`, unchanged.

Two small local helpers support this, both pure string parsing, no
network calls:

- `_extractRequestedCount(text)` — pulls a number like "10" out of "10
  MCQs" / "5 questions" via regex, capped at 50 as a sanity ceiling.
- `_extractRequestedLanguage(text)` — maps a named language word to a
  clear instruction string ("Urdu", "Roman Urdu (Urdu written in English
  letters)", etc.), or `null` if none was named.

`_actionRequestFor(intent, instructionText)` turns a matched intent +
the user's own typed text into a `DocumentActionRequest` (defined in
`document_intelligence_service.dart`).

`_runSmartCapability()` gained one new switch case covering all five new
intents together (they share the same handling): it builds the
`PreparedDocument` from the **already-processed** attachment (identical
pattern to the existing `documentIntel` case — no second
`AttachmentProcessorService.process()` call), calls
`DocumentIntelligenceService.runAction(doc, request)`, wraps it in the
**same Step 41 `_kSmartOperationTimeout` (90s) `.timeout()`** used by
every other smart-document call, and renders the result as a plain
`ChatMessage(text: ..., isUser: false)` — a normal Markdown chat bubble,
exactly like Step 38's OCR/handwriting results. On success it also sets
`_activeDocument`/clears `_activeDocumentQaTurns`, so a document Q&A
follow-up ("and the total?") works after any of these new actions too,
same as it already does after `documentIntel`.

`DocumentIntelligenceService` (new, additive-only content — every
existing method/prompt/field is untouched):

- `DocumentActionType` enum: `notes`, `questions`, `mcqs`, `explanation`,
  `tableExplanation`.
- `DocumentActionRequest` — carries the type plus optional `language`
  (explanation) / `count` (questions/MCQs).
- `runAction(doc, request)` — builds a dedicated grounded prompt per
  action type via `_promptFor()`, then calls the existing private `_ask()`
  helper (same one `analyze()`/`askQuestion()` already use) — so it's the
  exact same `GeminiService.sendMessage()` call, same attachment/text
  reuse, same `GeminiException → DocumentIntelligenceException`
  translation. Every prompt explicitly instructs the model to answer
  **only** from the attached document/text and to say so plainly instead
  of inventing content when the document doesn't have enough information
  — the grounding requirement from the spec.
- MCQ prompt enforces the exact requested format (numbered question, A–D
  options, `Answer: <letter>` line).

**Chat-native result:** No `Navigator.push`, no new screen, no new
result widget. Every one of the five new actions renders as a normal
assistant chat bubble via the existing `ChatMessage`/`ChatBubble`
pipeline — the same one OCR/handwriting results already use. The
existing `DocumentResultCard` (used only by `documentIntel`'s structured
JSON result) is completely untouched and not used by any of the new
actions.

## Files Added

None.

## Files Modified

- `lib/screens/chat_screen.dart`
  - Extended `_SmartIntent` enum (5 new values).
  - Extended `_detectSmartIntent()` with the new phrase groups (Step 40's
    existing groups/logic untouched).
  - Added `_extractRequestedCount()`, `_extractRequestedLanguage()`,
    `_actionRequestFor()`.
  - Extended `_labelFor()` with loading labels for the new intents.
  - Extended `_runSmartCapability()`: added `instructionText` parameter
    (threaded through the existing retry closure) and one new switch case
    handling all five new intents; the existing `ocr`/`handwriting`/
    `documentIntel` cases are byte-for-byte unchanged.
  - `_switchConversation()` / `_startNewChat()` / `_clearChat()`: added
    the voice-cancel + `_micState` reset described in Feature 1.
- `lib/core/services/document_intelligence_service.dart`
  - Added `DocumentActionType`, `DocumentActionRequest`, `runAction()`,
    `_promptFor()`. Every existing class/method/field (`PreparedDocument`,
    `DocumentIntelligenceResult`, `analyze()`, `askQuestion()`, `_ask()`,
    `_analysisPrompt`, `_qaInstructions`, all the JSON parsing helpers) is
    untouched — confirmed by diff.

No other file was touched. `pak_home_widgets.dart`, the attachment sheet,
`chat_bubble.dart`, `document_result_card.dart`, `text_recognition_service.dart`,
`gemini_service.dart`, `attachment_processor_service.dart`,
`DocumentIntelligenceScreen`, `TextScanResultScreen`, and Home/Drawer/
AppBar/Quick-Action-pill code are all byte-identical to the Step 41
baseline.

## Dependencies

None added, none removed. `pubspec.yaml` is byte-identical to the Step 41
baseline (confirmed by diff). Voice input continues to use the existing
`speech_to_text`-backed `VoiceInputService`; document actions reuse the
existing `http`-backed `GeminiService`.

## UX Changes

- No visible new buttons anywhere (no OCR/Handwriting/Document
  AI/Notes/MCQ menu) — the five new actions are discoverable only through
  natural language, per spec.
- New in-chat loading labels: "Preparing your notes…", "Creating
  questions…" (shared by both plain questions and MCQs), "Preparing your
  explanation…", "Reading the table…" — shown via the same existing
  loading-bubble mechanism Step 40/41 already use.
- Voice: unchanged visually — the mic button's existing idle/listening/
  processing states and compact inline UI are untouched; only its
  cancellation behavior on conversation switch was added.
- Home, Drawer, AppBar, Quick Action pills, chat bubble appearance,
  composer layout, attachment preview, and attachment sheet are all
  visually unchanged — no file among them was modified.

## Performance

- Zero duplicate attachment processing: every new action builds its
  `PreparedDocument` from the same already-processed `ProcessedAttachment`
  passed into `_runSmartCapability` — `AttachmentProcessorService.process()`
  is not called again, and PDF text is not re-extracted, exactly matching
  the existing `documentIntel` case's approach.
- Zero extra Gemini calls for intent classification — routing is 100%
  local string matching, same as Step 40.
- Each new action is exactly one Gemini call (via `_ask`/`sendMessage`),
  same as `analyze()`/`askQuestion()` — no chaining, no polling.
- Reuses Step 41's `_kSmartOperationTimeout` (90s) at the call site for
  all five new actions — no change to `GeminiService`'s own internal
  timeouts.

## Error Handling

All five new actions flow through the same `try`/`on
TextRecognitionException`/`on DocumentIntelligenceException`/`catch`/
`finally` structure `_runSmartCapability` already had — no new catch
paths were added, no raw exceptions can reach the UI:

- Empty/insufficient document content → `DocumentIntelligenceException`
  with a friendly message (existing pattern, reused).
- Timeout (90s) → "This is taking too long. Please try again." (matching
  Step 41's existing wording style for Q&A).
- Any Gemini failure → translated to `DocumentIntelligenceException` by
  the existing `_ask()` helper, unchanged.
- Retry (`_smartRetryAction`) reruns only the failed action against the
  same captured `processed`/`instructionText` — no re-picking the file.
- Voice errors: unchanged, already comprehensive (see Feature 1).

## Persistence

Fully backward compatible — **no changes to `ChatMessage` or its
serialization at all.** The five new actions render as plain `text`
(Markdown), exactly like Step 38's OCR/handwriting results already do;
they don't use the `documentResult` structured field, so there was
nothing new to serialize and nothing to make backward-compatible. Old
saved conversations, and conversations mixing old and new message types,
load exactly as before.

## Verification

- Traced the actual existing implementation before writing anything (per
  the step's own instruction) — found Feature 1 essentially complete
  already, which shaped the (small) scope of that half of the work.
- Diffed the modified files against the Step 41 baseline
  (`Step41.zip`, the previous delivered state) and confirmed exactly two
  files changed: `lib/screens/chat_screen.dart` and
  `lib/core/services/document_intelligence_service.dart`.
- Confirmed via diff that the import lines in both changed files are
  identical to the Step 41 baseline — no new/unused imports.
- Checked brace `{}`/bracket `[]` balance in the modified file (parenthesis
  count is not meaningfully checkable this way here, since the new MCQ
  prompt's string literals intentionally contain unmatched `)` characters
  like "A) option" — manually re-read that section instead).
- Grepped `lib/core/services/*.dart` for `class .*Service` — exactly one
  class per existing service name, no duplicates introduced.
- Confirmed `pubspec.yaml` is byte-identical to the Step 41 baseline.
- Confirmed Step 41's `_kSmartOperationTimeout` constant and its three
  original `.timeout()` call sites are all still present and unchanged;
  the new action branch adds a fourth, identical pattern.
- Confirmed Step 40's original `_detectSmartIntent`/`_runSmartCapability`/
  `_runDocumentFollowUp`/`_looksLikeDocumentFollowUp` logic is extended,
  not replaced — every original phrase list, case, and code path is
  still present verbatim.
- **Flutter/Android SDK is not available in this environment, so
  `flutter analyze`, `flutter test`, and a real build could not be run.**
  No build/test success is being claimed — the checks above are static/
  manual only. `git` was likewise not usable as a live repository here
  (working from an extracted zip), so literal `git diff --check` /
  `git diff --name-only` could not be run; the manual file-comparison
  checks above cover the same intent.

## Known Limitations

- Local keyword routing is inherently heuristic — very unusual phrasing
  for notes/questions/MCQs/table-explanation/translation may still fall
  through to the existing generic `documentIntel` analysis or the plain
  image/document understanding fallback rather than the most specific new
  action. This matches the spec's own instruction ("if ambiguous, do not
  force a specialized action").
- "Is PDF ka summary 5 points mein do" (a point-count constraint on a
  *summary*, not on questions/MCQs) still routes to the existing
  `documentIntel` full analysis rather than a dedicated "N-point summary"
  action — no new action type was built for that specific nuance, to keep
  this step's scope controlled; the existing summary is still grounded
  and useful, just not guaranteed to be exactly 5 bullet points.
- `_extractRequestedCount` only recognizes Arabic-numeral counts (e.g.
  "10 MCQs"), not spelled-out numbers ("ten MCQs") — a reasonable,
  deterministic boundary for a purely local parser.
- As with Step 41, the 90s smart-operation timeout does not cancel the
  underlying in-flight Gemini HTTP request — it only stops the UI from
  waiting past that point (standard `Future.timeout()` behavior, already
  documented in `CHANGE_REPORT_STEP41.md`).
- Not build/runtime-verified in this environment — please run the manual
  checklist below on an Android device.

## Manual Testing Checklist

**Voice**
- [ ] Tap mic, speak — listening indicator shows inline, composer stays
      visible (no new screen).
- [ ] Recognized text appears in the composer as you speak; you can edit
      it before sending.
- [ ] Tap mic again to stop listening early — works, no auto-send.
- [ ] Deny microphone permission — friendly message, no crash.
- [ ] Try voice input with no internet — friendly "no internet" message.
- [ ] Speak nothing / stay silent until timeout — friendly message, no
      stuck listening state.
- [ ] Start listening, then switch conversation from the drawer mid-listen
      — listening stops, and no stray text appears in the newly opened
      conversation's composer.
- [ ] Start listening, then tap "New Chat" mid-listen — same check.
- [ ] Start listening, then clear chat mid-listen — same check.

**Natural-language file actions**
- [ ] Attach a PDF, type "Is PDF ke short notes bana do" — "Preparing
      your notes…" appears, then structured notes appear inline in chat.
- [ ] Attach a PDF, type "Is PDF se 10 MCQs bana do" — 10 MCQs appear in
      the A/B/C/D + Answer format, grounded in the document.
- [ ] Attach a PDF, type "5 questions bana do" — 5 plain questions appear
      (no options), grounded in the document.
- [ ] Attach a document, type "Is document ko Urdu mein samjhao" —
      explanation appears written in Urdu.
- [ ] Attach a document with a table, type "Is table ko explain karo" —
      a narrative explanation of the table appears (not a re-listing of
      every cell, and not the full structured analysis card).
- [ ] Attach an image, type "Is image ka text nikal do" — still routes to
      OCR exactly as before (unchanged).
- [ ] Attach an image, type "Is handwritten note ko read karo" — still
      routes to handwriting recognition exactly as before (unchanged).
- [ ] Attach anything, type "What is this?" — still falls through to the
      unchanged generic image/document understanding flow, not a
      specialized action.
- [ ] Attach a document with very little content, ask for 10 MCQs — the
      response says there isn't enough content rather than inventing
      questions.
- [ ] After any new action, ask a follow-up ("iska total kitna hai?") —
      document Q&A still works against the same attached document.
- [ ] Trigger a slow/failing request for a new action — friendly timeout/
      error message + Retry, and Retry does not reopen the file picker.
- [ ] Combine voice + file: attach a PDF, use the mic to say "Is PDF ke 5
      important points batao", review the text, tap Send — routes and
      completes exactly as if typed.
- [ ] Confirm the attachment sheet still shows only Camera/Gallery/Files/
      PDF — no new buttons.
- [ ] Open an old saved conversation (from before this step) — loads
      normally, no errors.
- [ ] Confirm normal "Hello" chat, generic image/PDF chat, and Step 41's
      timeout/retry behavior are all still exactly as before.
