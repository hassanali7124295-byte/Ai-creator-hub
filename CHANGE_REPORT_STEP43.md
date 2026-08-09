# CHANGE REPORT — Step 43: Proper Voice Message System

## Summary

Replaced the chat composer's mic button behavior end-to-end: it no longer
runs continuous speech-to-text into the text field. It now records real
microphone audio and produces an actual playable voice message inside the
conversation — matching the brief exactly:

> 🎙️ → REAL AUDIO RECORDING → VOICE MESSAGE → PLAY/DELETE/SEND.

No automatic transcription is ever written into the composer.

---

## Files changed

| File | Change |
|---|---|
| `pubspec.yaml` | Added `record`, `audioplayers`, `path_provider`. |
| `lib/models/chat_attachment.dart` | Added `ChatAttachmentKind.audio` + optional `durationMs` field. |
| `lib/core/services/voice_recorder_service.dart` | **New.** Wraps `record` for permission check + start/stop/cancel. |
| `lib/core/services/voice_playback_service.dart` | **New.** `VoicePlaybackManager` singleton — one voice message plays at a time app-wide. |
| `lib/widgets/attachment_preview.dart` | Added an audio branch (`_AudioMessageChip`): play/pause, progress bar, duration. Used automatically by both the composer preview and sent `ChatBubble`s. |
| `lib/widgets/chat_bubble.dart` | One-line change: skip the plain `Text` widget when `message.text` is empty (voice messages have no text — avoids a stray blank line). No other change. |
| `lib/screens/chat_screen.dart` | Removed the `VoiceInputService`/`_MicState` wiring from the mic button; added the recording/preview state machine and UI (`_VoiceRecordState`, `_startRecording`, `_stopRecordingToPreview`, `_cancelRecording`, `_sendVoiceMessage`, `_VoiceRecordingBar`, `_VoiceMessagePreviewBar`). |

**Not touched:** `lib/core/services/voice_input_service.dart` (left exactly
as-is — see below), `lib/models/chat_message.dart`,
`document_intelligence_service.dart`, `text_recognition_service.dart`,
`pak_home_widgets.dart`, AppBar/Home screen, or any other file outside the
list above.

---

## Part 1 — What was removed from Speech-to-Text

`VoiceInputService` (the `speech_to_text` wrapper) is **not deleted** — the
brief explicitly said not to delete it blindly. It's simply no longer
imported or referenced by `chat_screen.dart`. The old `_MicState` enum
(`idle`/`listening`/`processing`) and `_onVoiceTap` — which streamed
recognized words straight into `_inputController` — are gone, replaced by
the new `_VoiceRecordState` (`idle`/`recording`/`preview`/`sending`) and
`_startRecording`/`_stopRecordingToPreview`/`_cancelRecording`/
`_sendVoiceMessage`. Nothing in the new flow ever writes to
`_inputController`.

## Part 2 — Real audio recording

`VoiceRecorderService` (new) wraps the `record` plugin:

- `ensureReady()` checks/prompts the mic permission (only when the person
  taps the mic — never on screen load).
- `start()` begins recording real microphone audio (AAC-LC, `.m4a`) to a
  fresh file in the OS temp directory (`path_provider`).
- `stop()` finalizes and keeps the file (the "✓ Done" path).
- `cancel()` stops (if needed) and permanently deletes the file (the
  "Cancel"/delete path).

`record` and `audioplayers` were chosen because they're small,
purpose-built, pure-plugin packages (no large "audio framework"), and both
declare their own required Android/iOS manifest permissions internally —
same pattern `speech_to_text` already used successfully in this project, so
no manual `AndroidManifest.xml`/`Info.plist` edit was needed (the project
has no generated `android/`/`ios/` folders yet; those are produced fresh by
the CI workflow's `flutter create` step, and plugin manifests merge in
automatically at that point).

## Part 3 — Mic button UX

Idle: a plain mic icon in the composer, unchanged position/size next to
the text field. Tapping it starts recording immediately — no toggle, no
second tap needed to "arm" it.

While recording, the **entire composer row is swapped** (via
`AnimatedSwitcher`, same rounded-pill footprint, no height jump) for a
compact bar:

```
🎙️ Recording 0:08          Cancel   ✓
```

No new screen, no navigation — everything happens inside `ChatScreen`.

## Part 4 — Stop / Done

Tapping ✓ stops the recorder, keeps the file + duration in memory, and
swaps in the preview bar:

```
[▶ ▬▬▬▬▬▬▬▬▬░░░ Voice message · 0:08]      [↑ Send]
```

The play button, progress bar, and duration are the exact same
`AttachmentPreview` audio-chip widget the sent message will use — built
from a throwaway in-memory `ChatAttachment` so the preview looks and
behaves identically to how it'll appear once sent. The text composer
stays empty and untouched throughout.

## Part 5 — Cancel recording

Cancel (during recording) or the chip's delete (✕) button (during
preview) both route through `_cancelRecording()`: stops the recorder if
still running, deletes the temp file, stops playback if that file happens
to be playing, and resets straight back to the idle composer. No message
is added; no text is inserted anywhere.

## Part 6 — Send voice message

`_sendVoiceMessage()` builds a `ChatMessage(text: '', isUser: true,
attachments: [audioAttachment])` and appends it to `_messages` /
conversation history exactly the way every other message is appended
(`setState` + `saveCurrentMessages`) — it renders inside the existing
`ChatBubble` via the existing `message.attachments` → `AttachmentPreview`
path, no new bubble type.

## Part 7 — Playback

`VoicePlaybackManager` (new) is a singleton `AudioPlayer` owner, modeled
directly on the existing `VoiceManager` (TTS) pattern already in the
project: play/pause/resume, a position/duration stream, and — critically —
starting playback for any id always stops whatever id was previously
active first, so only one voice message (composer preview or any sent
bubble, anywhere in the app) ever plays at once.

## Part 8 — AI voice conversation

The recorded audio is kept exactly as the user's voice message. The
existing Gemini pipeline in this project is text-only (`GeminiService` /
`AttachmentProcessorService` have no audio branch), so per the brief's
explicit instruction, **no new Gemini architecture was invented** and the
old dictation-into-composer behavior was **not** silently brought back.
Sending a voice message appends it to chat history as a normal user
message; it is not transcribed and does not trigger a Gemini call. This is
the safest, project-compatible path available without inventing new
backend behavior.

## Part 9 — Existing chat unchanged

Not touched: plain text send/receive, Camera/Gallery/Files/PDF attachment
flow, Document Intelligence (Steps 40/41), natural-language file actions
(Step 42). `_sendMessage()` (the normal text/attachment send path) is
otherwise untouched aside from one defensive top-of-function guard (`if
(_recordState != idle) return;`) replacing the old voice-cancel-on-send
logic — in practice this guard is unreachable in normal use since the
normal composer (and its Send button) isn't even rendered while a
recording/preview is active.

## Part 10 — Conversation safety

`_switchConversation`, `_startNewChat`, and `_clearChat` all now: stop any
active voice-message playback (`VoicePlaybackManager.instance.stop()`) and
cancel/discard any in-progress recording or unsent preview
(`_cancelRecording()`) before switching. `dispose()` does the same on
screen teardown. A recording or a sent-but-still-playing voice message can
never leak into a different conversation.

## Part 11 — Permissions / errors

Permission denied, recorder unavailable, recording failure, and playback
failure all surface through the existing `_showVoiceSnack` floating
SnackBar pattern (reused as-is, just repointed at the new failure
messages) — never a crash. The permission check
(`VoiceRecorderService.ensureReady()`) is only called on an explicit mic
tap and is never retried in a loop.

## Part 12 — UI requirement

No separate voice screen, no large recording page — the recording and
preview bars are just alternate composer states inside `ChatScreen`,
occupying the same footprint as the normal input bar.

## Part 13 — Cleanup

Temp recording files are deleted on: cancel (recording or preview),
recording failure, conversation switch, new chat, `ChatScreen` dispose. A
successfully **sent** voice message's file is intentionally *not* deleted
— it's still needed for playback/history (same lifetime as any other
attachment's local path in this project, e.g. images).

---

## Dependencies changed

Added to `pubspec.yaml`: `record: ^5.1.2`, `audioplayers: ^6.1.0`,
`path_provider: ^2.1.4`. No dependency was removed (`speech_to_text` stays,
per Part 1).

---

## Verification performed

**⚠️ Flutter SDK was not available in this environment** (`flutter` /
`dart` are not installed, and network access is disabled for package
fetching), so `flutter analyze` / `flutter pub get` / `flutter test` could
**not** be run. The following static verification was performed instead:

1. ✅ Diffed the full project tree against the Step 42 baseline — confirmed
   exactly 5 files modified (`pubspec.yaml`, `chat_attachment.dart`,
   `chat_screen.dart`, `attachment_preview.dart`, `chat_bubble.dart`) and 2
   new files added (`voice_recorder_service.dart`,
   `voice_playback_service.dart`). Nothing else in the project changed.
2. ✅ Bracket/paren/brace balance checked programmatically (Python) for
   every changed/new file — all balanced.
3. ✅ Grepped the whole `lib/` tree for `_MicState`, `_voiceInput`,
   `VoiceReadyStatus`, `micState` — none remain in executable code (only
   two doc-comment mentions of the old class/package names, for context).
4. ✅ Confirmed `_textController`/`_inputController` is never written to
   anywhere in the new recording/preview/send flow.
5. ✅ Confirmed `voice_input_service.dart` is untouched on disk and no
   longer imported by any file.
6. ✅ Added the missing `dart:io` import to `chat_screen.dart` (needed for
   `File(path).length()` in `_sendVoiceMessage`) — caught during review.
7. ⚠️ Not run/verifiable without the Flutter SDK: full compile,
   `flutter analyze`, widget tests, or an actual on-device recording/
   playback smoke test.

---

## Known limitations

- **Not build-verified.** This has been reviewed line-by-line and is
  believed correct, but has not been compiled. The manual testing
  checklist below should be run on a real device/emulator before treating
  this as final.
- Voice messages are stored as local file paths, same as images/PDFs in
  this project — if the app is reinstalled or the OS clears the temp
  directory, an old voice message's playback will fail gracefully (same
  existing fallback pattern `AttachmentPreview` already uses for missing
  image files), but the audio itself will be gone. Nothing in this step
  changes that existing trade-off; it was already true for other
  attachment kinds.
- No maximum recording length is enforced (Part 2 didn't request one).
- Recorded audio is never sent to or understood by Gemini (see Part 8) —
  by design, per the brief.

---

## Manual phone testing checklist

- [ ] Tap mic → recording starts immediately, composer swaps to the
      "Recording 0:0X · Cancel · ✓" bar, timer counts up.
- [ ] Tap Cancel mid-recording → composer returns to normal, no message
      added, no text in the field.
- [ ] Tap ✓ → recording stops, preview bar appears with play button,
      progress bar, duration, and Send.
- [ ] Tap play in preview → audio plays back; tap again → pauses.
- [ ] Tap delete (✕) in preview → discarded, back to normal composer.
- [ ] Tap Send → voice message appears as a bubble in the conversation
      with working play/pause/progress; text composer is untouched.
- [ ] Start a second voice message while a previous one is playing back →
      previous playback stops automatically.
- [ ] Deny mic permission → clear message shown, no crash, no repeated
      permission prompt loop.
- [ ] Start recording, then switch conversations / start a new chat /
      clear chat → recording is discarded, no leakage into the other
      conversation.
- [ ] Normal text send, image/PDF attachment send, and Document
      Intelligence flows all still work exactly as in Step 42.
- [ ] Force-close the app mid-recording → no crash on relaunch; no orphan
      recording appears anywhere.
