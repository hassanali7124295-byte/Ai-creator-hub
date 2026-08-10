# CHANGE REPORT — STEP 48

## Problem

Read Aloud's speaker button worked but always spoke in a female voice,
and Urdu pronunciation/quality was unsatisfactory. Step 47's inspection
established this was not a hardcoded choice in the app, but a combination
of (a) whatever voices the device's installed TTS engine actually offers
— which for Urdu on many Android devices may have no male voice at all —
and (b) the app's own gender-detection heuristic being unable to reliably
read gender off opaque, vendor-specific voice-name strings.

## Root Cause

Unchanged from Step 47's finding, restated for this report: `VoiceManager`
in `lib/core/services/tts_voice_service.dart` picked a voice purely by
string-matching each device voice's `name` against hardcoded
`_maleHints`/`_femaleHints` lists. Two structural gaps meant this could
never be fully reliable:

1. Many modern Android TTS voice names (especially Google's newer
   "network" voices) carry no gender-indicating substring at all, so a
   real male voice could go undetected.
2. Even with perfect detection, the app had no way to guarantee a male
   Urdu voice existed on a given device — that depends entirely on which
   engine is installed and which voice packs that engine has downloaded,
   neither of which the app controls.

Step 47 recommended not re-tuning the heuristic further, but instead (a)
best-effort preferring Google's TTS engine when available (generally the
richest voice set), and (b) giving the person a real, transparent voice
picker showing the device's actual installed voices — turning an invisible
guess into a visible, user-controlled choice. This step implements both.

## What Changed

### A) `lib/core/services/tts_voice_service.dart`

- **Kept unchanged, byte-identical in behavior**: `toggle(id, text)`,
  `stop()`, `dispose()`, `ensureInitialized()`, `state`, `activeId`,
  `isBusy`, `addListener`/`removeListener`, `reassignActiveId`, the Urdu
  script-detection heuristic (`_looksUrdu`), the natural pacing defaults,
  and the entire existing `_maleHints`/`_femaleHints`/`_bestVoice`
  Automatic-selection heuristic — none of it was re-tuned or removed, per
  the explicit instruction not to treat keyword-list tweaking as the fix.
- **New: Google TTS engine preference** (`_preferGoogleEngineIfAvailable`,
  called once during `_doInitialize()`, before the first voice-list
  fetch). Uses `flutter_tts`'s documented Android-only `getEngines`/
  `getDefaultEngine`/`setEngine` APIs: if `com.google.android.tts` is in
  the device's installed-engines list and isn't already the active
  engine, switches to it. Wrapped in `try/catch` end-to-end — on iOS/
  other platforms, or any device/engine that rejects the call, it's a
  silent no-op and the existing system/default engine keeps working
  exactly as before. Never forced, never fatal.
- **New: `TtsVoiceOption`** — a small `@immutable` model of exactly what
  `flutter_tts.getVoices` reports (`name`, `locale` only — the two keys
  guaranteed cross-platform; nothing else is inferred or invented), with
  `isUrdu`/`isEnglish` getters read from the voice's own reported locale.
- **New public API** for the Settings picker, all added below the
  existing code without touching it:
  - `loadAvailableVoices({forceRefresh})` → the device's real voice list.
  - `urduVoices` / `englishVoices` → that list filtered by locale.
  - `selectedVoiceFor({required isUrdu})` → the person's current explicit
    choice for that language, or `null` for Automatic.
  - `selectVoice(TtsVoiceOption)` → sets and persists a choice (keyed by
    the voice's *own* locale, so an English voice can never end up saved
    as the Urdu choice or vice versa).
  - `clearSelectedVoice({required isUrdu})` / `resetToAutomatic()` →
    reset one language, or both at once.
  - `previewVoice(TtsVoiceOption)` → speaks a short sample directly in
    that voice/locale (see Preview Behavior below).
- **`_bestVoice(isUrdu:)`** — one new step added at the very top: if the
  person has an explicit, still-valid choice for that language, it's
  returned immediately; otherwise execution falls through to the
  existing, untouched Automatic heuristic exactly as before.

### B) `lib/screens/settings_screen.dart`

- New **"Voice & Speech"** section (placed between the existing
  "Appearance" and "About" sections, reusing the screen's existing
  `_SectionLabel`/`_SettingsCard`/`_SettingsTile`/`_SettingsDivider`
  components — no new visual language introduced): two tiles, "Voice for
  Urdu replies" and "Voice for English replies", each showing the current
  selection ("Automatic" or the voice's real name) and opening the same
  picker on tap.
- New **`_VoicePickerSheet`** — a modal bottom sheet (`showModalBottomSheet`,
  `isScrollControlled: true`) that:
  - Lazily fetches the device's actual voices via
    `VoiceManager.instance.loadAvailableVoices()` when opened (not at
    Settings-screen load time, so a slow/unsupported `getVoices` call on
    some device never blocks opening Settings itself).
  - Shows a loading spinner while fetching, a friendly message if the
    fetch failed, and a friendly message if the device reports no voices
    at all (or no voices for one specific language) — see Error Handling.
  - Lists **only** voices `loadAvailableVoices()` actually returned,
    grouped into "Urdu" and "English" sections, each row showing the
    voice's real `name` and `locale` — nothing invented.
  - Each row has a radio-style selected indicator (checkmark) and a 🔊
    preview `IconButton` that becomes a small spinner while that specific
    voice is previewing.
  - A third "Automatic" section with a single "System default" row that
    calls `resetToAutomatic()`, clearing both languages' choices at once.
  - Returns `true` to the caller if any selection changed, so the parent
    Settings screen's summary tiles refresh immediately.

## Google TTS Engine Handling

Detection and switching happen once, during `VoiceManager.ensureInitialized()`
(the same one-time init every other TTS setup already goes through — no
new init path). Sequence: check `getEngines` → if Google's engine
(`com.google.android.tts`) is present and not already the default →
`setEngine('com.google.android.tts')`. Every step is inside try/catch;
any failure (unsupported platform, no engines reported, the switch call
itself throwing) is caught, logged via the same `debugPrint` convention
the rest of this file already uses, and simply leaves the previously
active engine in place. This happens *before* the first voice-list fetch,
so if the switch does succeed, the voice list (and therefore both the
Automatic heuristic and the Settings picker) reflects Google's voices,
not a stale pre-switch list.

## Voice Picker Behavior

Opens from either "Voice for Urdu replies" or "Voice for English replies"
— both open the same sheet, which shows both languages at once. Tapping a
voice selects it immediately (no separate "Save" step) and persists it;
tapping 🔊 previews it without changing the selection; tapping "System
default" under "Automatic" clears both languages back to the existing
heuristic. Closing the sheet (✕ or swipe-down) stops any in-progress
preview immediately, so it can never keep talking after the sheet closes.

## Urdu Fallback Behavior

Unchanged in substance from Step 47/the original design, now layered
under the new explicit-choice check:

1. If the person has explicitly picked an Urdu voice (and it still exists
   on the device), that voice is used — no heuristic involved.
2. Otherwise, the existing Automatic heuristic runs exactly as before: an
   `ur-PK`-locale male voice if one is detected, else the best available
   `ur-PK` voice, never crossing into an English-locale voice to read
   Urdu text (locale is always filtered before gender). If the device
   truly has no Urdu voice installed, the Urdu section of the picker
   plainly says so ("No Urdu voices were found on this device") rather
   than inventing one, and `_bestVoice` falls through its existing
   priority chain (including, as a last resort, any-locale male voice —
   unchanged behavior) or returns `null`, in which case the engine's own
   default voice is used, exactly as before this step.
3. At no point does the code claim a male Urdu voice exists when it
   doesn't — the picker only ever lists what `getVoices` actually
   reported.

## Persistence Behavior

Reuses the project's existing `shared_preferences` dependency (already
used by `GeminiService` for the API key) — no new persistence mechanism
was introduced. Four string keys, one pair per language:
`tts_selected_voice_name_ur`/`tts_selected_voice_locale_ur` and
`tts_selected_voice_name_en`/`tts_selected_voice_locale_en`. On app
startup, `_loadPersistedSelection()` (called once at the end of
`_doInitialize()`, after the voice list is already cached) reads any
saved choice and immediately revalidates it against the real,
just-fetched voice list (`_revalidatePersistedSelection`) — a saved
voice that no longer exists (uninstalled voice pack, different device via
backup/restore, engine changed) is silently dropped back to Automatic and
its stale keys are removed; nothing crashes and nothing is assumed to
exist. `loadAvailableVoices(forceRefresh: true)` re-runs this same
revalidation against a fresh fetch, so a voice removed while the app was
already running (e.g. the person went to system settings and deleted a
voice pack) is caught the next time the picker is opened.

## Error Handling

| Scenario | Behavior |
|---|---|
| No TTS engine at all | `getVoices`/`getEngines` throw or return empty; `_cacheVoices` catches this and caches an empty list — picker shows "No text-to-speech voices were found on this device" and Read Aloud keeps using whatever the plugin's underlying default does (unchanged pre-Step-48 behavior). |
| No voices installed for one language | That language's section in the picker shows "No Urdu/English voices were found on this device"; the other language's section is unaffected. |
| Google TTS unavailable/switch fails | Caught in `_preferGoogleEngineIfAvailable`; falls back to whatever engine was already active — never crashes, never blocks init. |
| Previously-selected voice removed | Caught by `_revalidatePersistedSelection`/the top of `_bestVoice`; silently falls back to Automatic for that language and clears the stale persisted keys. |
| Invalid/malformed voice entry from `getVoices` | `_cacheVoices` only keeps entries that have both a `name` and a `locale`; anything else is dropped. |
| Preview failure | `previewVoice` uses the same `_tryAsync` wrapper as every other engine call — a failed `setVoice`/`setLanguage`/`speak` is swallowed and simply leaves the engine's prior setting in place; the picker's spinner clears via the normal `VoiceState` listener once the engine reports finished/error, same path a normal message already uses. |
| Engine selection failure | Same as "Google TTS unavailable" above — caught, logged, non-fatal. |

## Exact Files Changed

- `lib/core/services/tts_voice_service.dart`
- `lib/screens/settings_screen.dart`

Nothing else. Confirmed by diffing the entire extracted project tree
against `Step46.zip` — these are the only two files that differ.

## Files Explicitly NOT Touched

- `lib/screens/chat_screen.dart` — `VoiceManager.instance.toggle(index, text)`
  needed zero changes; still calls the exact same method with the exact
  same signature.
- `lib/core/services/voice_recorder_service.dart`
- `lib/core/services/voice_playback_service.dart`
- `lib/core/services/attachment_processor_service.dart`
- `lib/core/services/gemini_service.dart`
- `pubspec.yaml` — no new dependency was added; `shared_preferences` and
  `flutter_tts` were already present at their existing versions.
- Document intelligence / natural-language file actions / voice-message
  sending-and-reply (Steps 43–46) — none of these files were opened for
  editing in this step.

## Verification Performed

This sandbox still has **no Flutter/Dart SDK installed**, **no network
egress**, and no `.git` directory (unchanged from every prior step). So
`flutter analyze`, `flutter test`, and `flutter build apk --release`
could **not** be run, and none are claimed to have passed.

**Static verification performed instead:**

1. Searched all of `lib/` for `FlutterTts`/`flutter_tts`/`VoiceManager`/
   `tts_voice_service` — confirmed exactly one `FlutterTts()`
   instantiation exists (`tts_voice_service.dart`), `VoiceManager` remains
   the sole owner, and the only other references are `chat_screen.dart`
   (the speaker button, unchanged call) and `settings_screen.dart` (the
   new picker) plus one unrelated doc-comment mention in
   `voice_playback_service.dart` (a different class, recorded-audio
   playback, not TTS).
2. Confirmed no duplicate TTS service was created — one `VoiceManager`
   singleton, no second engine wrapper.
3. Confirmed `chat_screen.dart`'s `VoiceManager.instance.toggle(index, text)`
   call is byte-for-byte unchanged (diffed against Step 46).
4. Checked every import in both changed files against actual usage — no
   unused imports; the one new import in each file (`shared_preferences`
   in the service, `dart:async` in both, for `unawaited`) is used.
5. Checked bracket/brace/parenthesis balance in both changed files:
   `tts_voice_service.dart` — 87/87 braces, 337/337 parens, 83/83
   brackets; `settings_screen.dart` — 82/82 braces, 456/456 parens, 39/39
   brackets.
6. Checked enum/switch exhaustiveness: no new `switch` statement was
   added by this step. The three pre-existing `switch (mode)` statements
   over `ThemeMode` in `settings_screen.dart` were not touched and remain
   exactly as exhaustive as before.
7. Confirmed no recorded voice-message code was modified — diffed
   `voice_recorder_service.dart`, `voice_playback_service.dart`, and
   `attachment_processor_service.dart` against Step 46: all three are
   byte-identical.
8. Diffed the complete extracted project tree against `Step46.zip`:
   only `lib/core/services/tts_voice_service.dart` and
   `lib/screens/settings_screen.dart` differ; `pubspec.yaml` is
   byte-identical (confirmed separately) and every other file, including
   all prior `CHANGE_REPORT_*.md` files, is unchanged.
9. Cross-checked the exact `flutter_tts` API surface used
   (`getEngines`, `getDefaultEngine`, `setEngine`, `getVoices`) against
   the package's own published API documentation and changelog to confirm
   these methods genuinely exist with the signatures used here (all are
   documented, Android-scoped members of `FlutterTts`) — this is not a
   substitute for actually compiling against the real SDK, but reduces
   the risk of calling a nonexistent method.

**No real build was run, so it is not confirmed whether
`flutter analyze`/`flutter build apk --release` actually succeed with
this change.** This needs to be run through your actual GitHub Actions
workflow (or a local Flutter environment) to confirm. If any compile
error or analyzer warning turns up there, that will need a follow-up
step.

## Manual Phone Testing Checklist

Not executed — no device/emulator or Flutter SDK available in this
environment. Still needs to be verified once built for real:

- [ ] Speaker button on an AI reply still works exactly as before
- [ ] App still switches to Google's TTS engine automatically where it's
      installed and not already active (check via device TTS settings or
      logcat for the `VoiceManager: switched to Google TTS engine.` line)
- [ ] On a device without Google's TTS engine, or where switching fails,
      the app still speaks normally using whatever engine was already
      active — no crash, no silent failure
- [ ] Settings → Voice & Speech shows the two summary tiles
- [ ] Opening the picker shows the device's real installed voices,
      correctly split into Urdu / English sections
- [ ] Tapping 🔊 on a voice plays a short sample in that exact voice and
      correct language, without needing to select it first
- [ ] Selecting a voice shows a checkmark, and the very next AI reply in
      that language is spoken in that exact voice
- [ ] Selecting a different voice for the other language works
      independently (Urdu and English selections don't affect each other)
- [ ] Restarting the app keeps both selections (persistence)
- [ ] Tapping "System default" under Automatic clears both selections
      back to the original Automatic behavior
- [ ] If a previously-selected voice was uninstalled from the device
      (e.g. via system TTS settings), the app falls back to Automatic
      without crashing, and the picker no longer shows a checkmark next
      to it
- [ ] On a device with no Urdu voices installed at all, the Urdu section
      of the picker clearly says so instead of showing nothing/breaking
- [ ] Closing the picker mid-preview stops the preview immediately
- [ ] Recorded voice-message record/preview/send/playback (Steps 43–46)
      is completely unaffected by any of the above
- [ ] Normal text chat, image/PDF/document analysis, and OCR/handwriting
      are unaffected

## Known Limitations

- No Flutter/Dart SDK, no network, and no `.git` history were available
  in this environment, so `flutter analyze`, `flutter test`, and
  `flutter build apk --release` could not be run. This report documents
  static verification only (source review, balance checks, diffing
  against the Step 46 baseline, and cross-checking the `flutter_tts` API
  surface used against its published documentation); the real CI run is
  still required to confirm the app actually builds and behaves as
  described.
- A male Urdu voice is still **not guaranteed** — this was never
  possible to guarantee (Step 47's finding stands) and this step doesn't
  claim otherwise. What changed is that the person can now see exactly
  which Urdu voices actually exist on their device and pick the best one
  themselves, and the app now gives Google's (generally richer) engine a
  fair chance to be active first.
- Google TTS engine switching, `getEngines`/`getDefaultEngine`/`setEngine`
  behavior, and the actual on-device voice list can only be meaningfully
  confirmed on a real Android device — none of this could be exercised
  in this sandboxed environment.
- The `#ttsVoicePreview` Symbol-based preview sentinel relies on
  `chat_screen.dart`'s existing `activeId is int` check (unchanged, not
  touched by this step) to avoid being mistaken for a chat message index;
  this is a real, existing safeguard in that file, not a new assumption
  introduced here, but it's worth noting as the mechanism that keeps
  preview playback from visually appearing as "message speaking" in chat.
