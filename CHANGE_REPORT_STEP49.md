# CHANGE REPORT — STEP 49
Fix TTS Gender Options, Emoji Filtering & Natural Voice Selection

## Root cause

Step 48 already built the real machinery this step needed — a live
per-device voice list, a Settings picker, per-language persisted
selection, a Google-engine preference, and a "never force female"
Automatic heuristic — but two things were still missing:

1. **No gender label at all.** `TtsVoiceOption` only carried `name` and
   `locale`. The picker showed the device's raw technical voice name
   (e.g. `ur-pk-x-cfn-network`) with no Male/Female/Voice label, so a
   Male vs. Female Urdu/English choice wasn't "clearly" presented as
   Step 49 requires — even though the underlying `_maleHints`/
   `_femaleHints` name-hint lists `VoiceManager` already trusted for its
   *own* Automatic-selection logic could answer that question just as
   reliably for display purposes.
2. **No emoji filtering.** `toggle()` passed the chat message's raw
   text straight to `FlutterTts.speak()`. An AI reply like `"Hello! 👋
   How can I help you today? 🤖"` would have most Android TTS engines
   either skip the emoji silently (best case) or, on some engines,
   speak a description like "waving hand" / "robot" (worst case) — the
   bug this step's requirement 7 describes.

Preview text, Urdu/English selection independence, persistence, and the
"don't force female" rule were all already correct from Step 48 and are
unchanged.

## Files changed

Only the two files the task allowed:

- `lib/core/services/tts_voice_service.dart`
- `lib/screens/settings_screen.dart`

No other file differs from the Step48.zip baseline (verified with a
full recursive diff against the uploaded project).

## Exact fixes

### 1–2. Male/Female Urdu & English options (`tts_voice_service.dart`)

- Added `enum TtsVoiceGender { male, female, unknown }`.
- Added `TtsVoiceOption.gender`, a getter that classifies a voice
  **purely from its own `name`**, reusing the exact same
  `VoiceManager._maleHints` / `_femaleHints` lists the Automatic
  heuristic already trusted (e.g. `male`/`female` tags, known Google TTS
  legacy codes like `ur-pk-x-had` vs `ur-pk-x-hae`, common voice given
  names). If a name matches both lists, or neither, the result is
  `TtsVoiceGender.unknown` — never a guess.
- No new voices are invented anywhere — this only labels voices
  `flutter_tts.getVoices` already returned on the device.

### 3. Voice preview (`tts_voice_service.dart`)

- `previewVoice()` already existed from Step 48 (per-voice 🔊 button,
  uses the selected voice's own locale, generation-guarded so it can't
  overlap). Updated its sample sentences to match this step's exact
  wording:
  - Urdu: `"السلام علیکم، یہ آواز کی جانچ ہے۔"`
  - English: `"Hello, this is a voice test."`

### 4–6. Natural priority / no forced female / language-specific voice

Already implemented in Step 48 (`_preferGoogleEngineIfAvailable`,
`_bestVoice`'s male-priority-with-network-preference chain, per-language
`_userVoiceOverride`) and deliberately left untouched — re-verified
these rules still hold:
- Google TTS engine preferred when installed, never fatal if absent.
- `_bestVoice` never falls back to a female-tagged voice while an
  untagged/male alternative exists.
- Urdu text always resolves through the `isUrdu` locale prefix; English
  always through `en`; the two selections are stored under independent
  `SharedPreferences` keys (`tts_selected_voice_*_ur` /
  `tts_selected_voice_*_en`) and never cross-applied.

### 7–8. Emoji filtering — audio-only (`tts_voice_service.dart`)

- Added `VoiceManager.sanitizeForSpeech(String)`: a Unicode-aware
  regex (`RegExp(..., unicode: true)`) built from the actual emoji
  Unicode blocks/codepoints (misc pictographs, emoticons, transport,
  supplemental symbols A, dingbats, misc symbols, a short explicit list
  of the individual arrow/star/shape codepoints that are genuinely used
  as emoji, plus the invisible variation-selector/ZWJ/keycak-joiner
  codepoints that only ever attach to emoji) — not a blanket "delete
  this whole Unicode range" pass, so it can't collide with Urdu/Arabic
  script, Latin letters, digits, or normal punctuation (none of which
  fall in any of the ranges used).
- Wired into `toggle()`: `_tts.speak(text)` → `_tts.speak(sanitizeForSpeech(text))`.
  Language detection (`_looksUrdu`) still runs on the original,
  unmodified `text` first — sanitization only affects the very last
  step, the string hand-off to the engine.
- Verified against the task's own example:
  `"Hello! 👋 How can I help you today? 🤖"` → `"Hello! How can I help
  you today?"` (double-space left behind by the removed emoji is also
  collapsed).

### 9. Speaker button unchanged

`chat_screen.dart` was not touched. `VoiceManager.instance.toggle(index,
text)` keeps its exact existing signature; sanitization happens inside
`VoiceManager`, invisibly to every caller.

### 10. Voice picker UI (`settings_screen.dart`)

- Added `_friendlyLocaleName(String locale)` — a small, purely cosmetic
  lookup (`ur-PK` → `"Urdu (Pakistan)"`, `en-US` → `"English (US)"`,
  etc., case-insensitive, with an honest fallback to the raw code for
  anything not in the small known list). Never used for any
  selection/matching logic — that still keys off the raw locale string
  exactly as the engine reported it.
- Added `_voiceDisplayLabel(TtsVoiceOption)`:
  - `TtsVoiceGender.male` → `"Male — Urdu (Pakistan)"`
  - `TtsVoiceGender.female` → `"Female — English (US)"`
  - `TtsVoiceGender.unknown` → `"Urdu (Pakistan) — Voice"`
- `_VoiceOptionTile` now shows `_voiceDisplayLabel(voice)` as the bold
  primary line and the device's raw technical `voice.name` (e.g.
  `ur-pk-x-cfn-network`) as a smaller secondary line underneath —
  informative instead of the raw string being the only thing shown.
- The Settings screen's own summary rows ("Voice for Urdu replies" /
  "Voice for English replies") now use the same `_voiceDisplayLabel`
  helper for their subtitle, so the summary and the picker never
  disagree about how a voice is described.
- Selected-indicator, preview button, "No Urdu/English voices found"
  states, and "Reset to Automatic" are all unchanged from Step 48.

### 11. Step 48 preserved

Confirmed via a full recursive `diff` against the uploaded Step48.zip
that every other file — including `voice_recorder_service.dart`,
`voice_playback_service.dart`, `attachment_processor_service.dart`,
`gemini_service.dart`, `chat_screen.dart`, and `pubspec.yaml` — is
byte-identical to the Step 48 baseline. `VoiceManager`'s public API
(`toggle`/`stop`/`dispose`/`ensureInitialized`/`state`/`activeId`/
`isBusy`/`addListener`/`removeListener`/`loadAvailableVoices`/
`urduVoices`/`englishVoices`/`selectedVoiceFor`/`selectVoice`/
`clearSelectedVoice`/`resetToAutomatic`/`previewVoice`) is unchanged —
only new members (`TtsVoiceGender` enum, `TtsVoiceOption.gender`,
`sanitizeForSpeech`) were added.

### 12–13. Minimal file changes, no new dependency

Only `tts_voice_service.dart` and `settings_screen.dart` were touched,
as instructed. No package was added — the emoji filter is a hand-built
`RegExp` using only Dart core + the already-imported
`package:flutter/foundation.dart` (for `@visibleForTesting`, purely a
lint annotation with no runtime effect).

## What was verified

- Full recursive `diff` against the uploaded Step48.zip: only the two
  intended files differ.
- Brace/paren balance check on both changed files (151/151 braces,
  375/375 & 477/477 parens respectively — balanced).
- No duplicate class/enum/top-level-function names introduced (checked
  by grep across both files).
- `pubspec.yaml` still contains `record: ^6.2.1`, unchanged.
- The exact emoji-filtering example from the task
  (`"Hello! 👋 How can I help you today? 🤖"`) was reproduced in a
  standalone Python simulation of the same codepoint ranges/regex logic
  used in the Dart source, and produces exactly `"Hello! How can I help
  you today?"` — confirming the sanitize logic and Unicode ranges are
  correct — Urdu/Arabic text, digits, and punctuation were also
  confirmed to pass through untouched in the same simulation.

## What could not be verified

- **No local Flutter/Dart SDK is available in this environment**
  (`flutter`/`dart` are not installed, and outbound network access is
  disabled, so the SDK cannot be fetched here either). `flutter pub
  get`, `flutter analyze`, `flutter test`, and `flutter build apk
  --release` were **not run** and their results are **not claimed** —
  this matches every prior step in this project. Real build
  verification happens via the existing GitHub Actions workflow on
  push, unchanged by this step.
- Actual on-device behavior (which Urdu/English voices a real Android
  TTS engine + Google TTS installation reports, whether their names
  happen to contain the hint-list substrings, how a specific engine
  renders the sanitized text) can only be confirmed on a real device —
  the code is written to degrade honestly (`TtsVoiceGender.unknown` /
  "No voices found" messaging) whenever the device doesn't cooperate,
  never to fabricate a result.

## Manual testing checklist

1. Open **Settings → Voice & Speech → Voice for Urdu replies** (or
   English). Confirm the picker sheet opens and lists every voice the
   device reports under "Urdu" and "English" section headers.
2. For each voice row, confirm the bold line reads either
   `"Male — <Language (Region)>"`, `"Female — <Language (Region)>"`, or
   `"<Language (Region)> — Voice"` — never a fabricated gender — and the
   smaller line below shows the raw technical voice name.
3. Tap the 🔊 icon on a few different voices. Confirm each plays its own
   short preview sentence in the correct language, only one plays at a
   time, and tapping the icon again while it's playing stops it.
4. Select an Urdu voice, back out, reopen the picker — confirm it's
   still shown as selected (checkmark) and that English's selection is
   untouched.
5. Force-close and reopen the app — confirm both saved selections
   persist.
6. Tap **Reset to Automatic** — confirm both languages fall back to
   "Automatic" and the app doesn't crash.
7. In chat, get an AI reply containing emoji (e.g. ask something likely
   to produce a 👍 or 😀 in the response) and tap the speaker button.
   Confirm:
   - The chat bubble still visibly shows the emoji.
   - The spoken audio has no emoji description in it and doesn't
     stumble/pause oddly where an emoji was.
8. Get an AI reply that's fully in Urdu script and tap its speaker
   button — confirm it's read in the saved (or Automatic) Urdu voice,
   not English, and that no characters are dropped.
9. Confirm the existing voice-message recording/reply flow, Gemini
   audio replies, and attachment processing are all unaffected (none of
   those files were touched).
