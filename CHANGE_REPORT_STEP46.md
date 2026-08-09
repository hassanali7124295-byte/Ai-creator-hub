# CHANGE REPORT — STEP 46

## Root Cause

Traced the complete flow from mic tap to AI reply:

```
mic tap → _startRecording() → VoiceRecorderService.start()
       → _stopRecordingToPreview() → VoiceRecorderService.stop() (file kept)
       → _sendVoiceMessage() → ChatAttachment(kind: audio) + ChatMessage
       → setState(_messages.add(...)) → ConversationProvider.saveCurrentMessages()
       → [END — nothing further happened]
```

`_sendVoiceMessage()` in `lib/screens/chat_screen.dart` built the
`ChatAttachment`/`ChatMessage` for the recorded audio, appended it to
`_messages`, saved it to conversation history, and returned. It never
called `GeminiService` at all. Its own doc comment said as much directly:
*"the existing Gemini chat pipeline is text-only, so this simply appends
the message to the conversation ... without inventing a new Gemini
request shape for audio."* That was accurate for Step 43/45, but it's
exactly the gap this step closes — a voice message reached the chat
history and nothing ever asked Gemini to respond to it.

`GeminiService` and `AttachmentProcessorService` were also inspected: as
of Step 45, `AttachmentProcessorService.process()` explicitly refuses to
handle `ChatAttachmentKind.audio` (throws, by design — audio is never
supposed to go through image/PDF/generic-file processing). `GeminiService`
itself, however, already supports arbitrary inline attachments via
`GeminiInlinePart` (mime type + base64 data) and `sendMessage(...,
attachments: [...])` — the exact same mechanism used for images and
generic files, just never previously pointed at a recorded audio file.

## Exact Files Changed

- `lib/screens/chat_screen.dart` — the only file changed. Everything else
  in the project (including `attachment_processor_service.dart`,
  `chat_attachment.dart`, `voice_recorder_service.dart`,
  `voice_playback_service.dart`, `attachment_preview.dart`,
  `chat_bubble.dart`) is byte-for-byte identical to the Step 45 baseline
  (confirmed by diffing the full extracted project tree against
  `Step45.zip` — see Verification below).

## Exact Fix

Three small additions inside `chat_screen.dart`, all new code — nothing
existing was rewritten or restructured:

1. **`_sendVoiceMessage()`** — unchanged in every respect except one new
   line at the very end: after the voice message bubble is appended and
   saved (exactly as before), it now calls the new
   `await _requestVoiceAiReply(path)`. Also resets `_smartErrorIndex`/
   `_smartRetryAction` to `null` in the same `setState` that appends the
   message — the same reset every other send path (`_sendMessage`,
   `_switchConversation`, `_startNewChat`) already does, so a stale error
   from an earlier failed request can never be wired to the wrong retry.

2. **New method `_requestVoiceAiReply(String audioPath)`** — reads the
   recorded file's bytes, wraps them in a `GeminiInlinePart(mimeType:
   'audio/m4a', base64Data: ...)` (`audio/m4a` is one of Gemini's
   documented supported audio MIME types), builds the same
   `history`/`role`/`text` shape `_sendMessage()` already builds for every
   other send, and calls the existing
   `GeminiService.sendMessage(prompt, history: history, attachments:
   [audioPart], modeInstruction: _mode.systemPrompt)` — the same method
   used for the plain-text streaming path, just with one audio attachment
   instead of zero. `prompt` is a fixed instruction telling the model it
   received a voice message and should reply naturally to what was said;
   this text is only ever sent to Gemini, never shown in the chat (the
   voice message's own bubble `text` stays `''`, exactly as before — see
   "Why Audio Must Never Be Converted to Composer Text" below). On
   success, appends a normal AI `ChatMessage` — identical in shape to
   every other AI reply. Uses the existing `_isSending`/`_sendingHasImages`
   /`_sendStage` fields, so the existing bottom `_LiveStatus` row (with
   `hasImages: false`, which already renders as the plain "Thinking..."
   label) is the loading indicator — no new loading UI was built.

3. **New methods `_appendVoiceReplyError(...)` and
   `_retryVoiceAiReply(...)`** — on any failure, append a friendly
   `isError: true` chat bubble (message text depends on the failure: file
   missing, empty file, a `GeminiException`, or a generic fallback) and
   wire `_smartErrorIndex`/`_smartRetryAction` to `_retryVoiceAiReply`,
   which removes that error bubble and calls `_requestVoiceAiReply` again
   against the same `audioPath` — the same
   `_smartErrorIndex`/`_smartRetryAction` mechanism `_runSmartCapability`
   already uses elsewhere in this file for its own Retry buttons, reused
   here rather than reinvented. The generic `_retryLastMessage` is
   deliberately never used for this — it only knows how to re-ask Gemini a
   plain text prompt (`userMessage.text`) and has no audio file to
   reattach, so it would silently fail to actually retry the voice
   request.

## Voice-Message Request Flow (After This Fix)

```
mic tap → _startRecording()
       → _stopRecordingToPreview() (file kept at a temp path)
       → user taps Send → _sendVoiceMessage()
           → ChatAttachment(kind: audio) + ChatMessage appended (unchanged)
           → conversation saved (unchanged)
           → _requestVoiceAiReply(path)                              [NEW]
               → reads audio bytes from the same recorded file
               → GeminiInlinePart(mimeType: 'audio/m4a', ...)
               → GeminiService.sendMessage(prompt, history, [audioPart])
               → success → ChatMessage(isUser: false, text: reply) appended
               → failure → error bubble appended, Retry wired to
                            _retryVoiceAiReply(errorIndex, path)
```

## Why Audio Must Not Go Through AttachmentProcessorService's Image/PDF Processing

Unchanged from Step 45's reasoning, reaffirmed here: `AttachmentProcessorService.process()`'s
`switch (kind)` still has its explicit `case ChatAttachmentKind.audio:`
that throws rather than falling through to `_processImage`/`_processPdf`/
`_processGenericFile` (that file was not touched in this step — see Files
Changed). `_requestVoiceAiReply` never calls
`AttachmentProcessorService.process()` at all; it builds the
`GeminiInlinePart` directly from the raw recorded bytes, the same way
`AttachmentProcessorService._processGenericFile` builds one for a plain
file, but without ever entering that class. This keeps the invariant Step
43/45 established: routing audio through JPEG decoding, PDF text
extraction, or the plain-text mime allow-list would corrupt or reject real
recorded audio and could send it to the wrong place; audio has its own
dedicated, minimal path straight from `VoiceRecorderService`'s file to
`GeminiService`.

## Why Audio Must Never Be Converted to Composer Text

The recorded audio is sent to Gemini as a binary `GeminiInlinePart`
attachment, not transcribed to text anywhere in this app. No
speech-to-text package or service is invoked by this change —
`voice_input_service.dart` (the old `speech_to_text`-based service) is
untouched and still not wired to the composer, exactly as Step 43 left
it. `_inputController` (the composer's text field) is never written to by
any part of this flow. The sent voice message's `ChatMessage.text` stays
`''`, so `ChatBubble`/`AttachmentPreview` keep rendering it exactly as
they did before — an audio player row, never a text bubble. The prompt
string sent to Gemini (`"The user just sent a voice message instead of
typing..."`) exists purely as the API request's instruction text; it is
never assigned to any `ChatMessage`, never shown in any bubble, and never
touches the input field.

## Error Handling

- File missing (deleted/moved since recording) → friendly error, no crash.
- File exists but empty → friendly error, no crash.
- `GeminiException` (no API key, network failure, bad response, etc.) →
  its own message shown as the error bubble text (same as every other
  Gemini-calling path in this file).
- Any other unexpected exception → generic friendly fallback message.
- In every case: the already-sent voice message bubble is never removed,
  edited, or hidden. The recording UI (`_recordState`) is never reopened —
  it was already reset to `idle` before `_requestVoiceAiReply` is even
  called, and nothing in the new code touches `_recordState` again.
- Retry re-runs the exact same request against the same audio file — nol
  new recording, no re-transcription, no lost context.
- No new temporary files are created by this step. The only file touched
  is the one `VoiceRecorderService` already produced and kept for
  playback (`attachment.path`); it is deliberately never deleted here —
  it must keep existing so the sent voice message stays playable, and so
  Retry has bytes to re-read. Reading it (`File.readAsBytes()`) does not
  modify or lock the file, so voice playback is unaffected.

## Conversation-Safety Handling

No new conversation-identity bookkeeping was needed. This project's
existing conversation-switch guards already cover it:
`_switchConversation(id)` starts with `if (id == _conversationId ||
_isSending) return;` and `_startNewChat()` starts with `if (_isSending)
return;` — both already refuse to run while any request is in flight.
`_requestVoiceAiReply` sets `_isSending = true` for its entire duration
(cleared in its `finally`, same pattern as `_sendMessage` and
`_runSmartCapability`), so the person cannot switch to a different
conversation or start a new chat while the AI is processing a voice
message — the eventual reply can only ever land back in `_messages` for
the conversation that was active when the request started, exactly as
already guaranteed for every other in-flight AI request in this app.

## Verification Performed

This sandbox still has **no Flutter/Dart SDK installed**, **no network
egress**, and no `.git` directory in this project (unchanged from Steps
44/45). So the following could **not** actually be run, and none are
claimed to have passed:

- `flutter analyze` — **NOT RUN** (no SDK)
- `flutter test` — **NOT RUN** (no SDK)
- `flutter build apk --release` — **NOT RUN** (no SDK, no network)
- `git diff --check` — **NOT RUN** (no `.git` directory)

**Static verification performed instead:**

1. Searched every reference to `ChatAttachmentKind.audio` across `lib/`
   (see command output) — all in `chat_attachment.dart` (enum + wire
   name), `attachment_processor_service.dart` (Step 45's explicit-throw
   case, untouched), `attachment_preview.dart` (icon + dedicated render
   branch, untouched), and `chat_screen.dart` (building the attachment on
   send — unchanged; the new doc comment mentioning it). No new file
   introduces a competing/second voice/audio concept.
2. Traced `_sendVoiceMessage()` end-to-end by reading the full function
   plus the new `_requestVoiceAiReply`/`_appendVoiceReplyError`/
   `_retryVoiceAiReply` methods top to bottom, confirming the audio file's
   path flows from `VoiceRecorderService.stop()` through to
   `File(audioPath).readAsBytes()` without being intercepted or discarded.
3. Confirmed the audio bytes reach the AI request: `GeminiInlinePart` is
   built from those bytes and passed as `attachments: [audioPart]` into
   the same `GeminiService.sendMessage` used elsewhere in this file.
4. Confirmed a normal AI text `ChatMessage` (`isUser: false`) is appended
   to `_messages` after a successful `sendMessage` call, immediately after
   the voice message's own bubble — same shape/rendering as every other
   AI reply, no new message type.
5. Confirmed the plain-text send path (`_sendMessage`, `_streamAiReply`)
   was not touched — diffed the full file section by section; only new
   methods were added plus the one new call at the end of
   `_sendVoiceMessage`.
6. Confirmed the image/PDF/document-analysis paths
   (`AttachmentProcessorService`, `_runSmartCapability`,
   `DocumentIntelligenceService`) were not touched — none of those files
   or methods appear in the diff (see file-diff result below).
7. Checked bracket/brace/paren balance of the modified file: 323 open /
   323 close braces, 1622 open / 1622 close parens (both balanced) before
   and after the edit.
8. Checked for unused imports: no new `import` statements were added —
   `dart:io` (`File`), `dart:convert` (`base64Encode`), and
   `gemini_service.dart` (`GeminiService`, `GeminiException`,
   `GeminiInlinePart`) plus `attachment_processor_service.dart`
   (`AttachmentException`) were all already imported and already used
   elsewhere in this file for other send paths.
9. `flutter analyze` — **NOT RUN** (no SDK available; see above).
10. Explicitly documented here: Flutter SDK is unavailable in this
    environment, so only static verification (items 1–8 above) was
    performed.
11. Diffed the complete extracted project tree against `Step45.zip`:
    `lib/screens/chat_screen.dart` is the **only** file that differs.
    Every other file (including all previous `CHANGE_REPORT_*.md` files,
    `pubspec.yaml`, and every other `lib/` file) is identical to Step 45.

**No real build was run, so it is not confirmed whether
`flutter build apk --release`, `flutter analyze`, or `flutter test`
actually succeed with this change.** This needs to be run through your
actual GitHub Actions workflow (or a local Flutter environment) to
confirm. If any compile error or analyzer warning turns up there, that
will need a follow-up step.

## Manual Voice-Message Testing Checklist

Not executed — no device/emulator or Flutter SDK available in this
environment. Still needs to be verified once built for real:

- [ ] Record and send a voice message → it appears immediately as a
      playable audio bubble (unchanged from Step 43/45)
- [ ] After sending, the normal "Thinking..." loading indicator appears
- [ ] The AI replies with a normal text bubble responding to what was
      actually said in the recording
- [ ] The voice message itself never shows any transcribed text, and the
      composer's text field is never populated by this flow
- [ ] Turn off the network / remove the API key, send a voice message →
      a friendly error bubble appears, the voice message stays visible,
      and Retry is offered
- [ ] Tap Retry on that error → it re-sends the same recording (no
      re-recording needed) and either succeeds or shows a fresh error
- [ ] Start a voice-message send, then try to switch conversations or
      start a new chat while it's processing → blocked until the request
      finishes (existing `_isSending` guard)
- [ ] Normal text chat still works
- [ ] Image attachment send/analysis still works
- [ ] PDF attachment send/analysis still works
- [ ] Existing OCR still works
- [ ] Existing handwriting recognition still works
- [ ] Existing Document AI still works
- [ ] Voice playback (tapping play on a sent voice message) still works
- [ ] Conversation history persists voice messages and their AI replies
      correctly across app restarts

## Known Limitations

- No Flutter/Dart SDK, no network, and no `.git` history were available
  in this environment, so `flutter analyze`, `flutter test`,
  `flutter build apk --release`, and `git diff --check` could not be run.
  This report documents static verification only; the real CI run is
  still required to confirm the app actually builds and behaves as
  described.
- The exact wording of the fixed instruction prompt sent to Gemini for a
  voice message (*"The user just sent a voice message instead of
  typing..."*) was not tunable/tested against a live Gemini response in
  this environment — it follows the same phrasing conventions already
  used for attachment-only sends elsewhere in this file, but its quality
  can only really be judged once real audio is actually sent to a live
  API key.
- `audio/m4a` was selected as the MIME type sent to Gemini because it
  matches the recording format `VoiceRecorderService` already produces
  (`AudioEncoder.aacLc` → `.m4a`) and is listed as a supported Gemini
  audio MIME type in Google's own documentation — this was not
  independently confirmed against a live API call in this environment.
- This step does not add any timeout tuning specific to audio requests —
  `GeminiService.sendMessage`'s existing `isHeavyRequest`/60-second
  timeout logic applies (any non-empty `attachments` list already counts
  as "heavy" in that method), unchanged from before this step.
