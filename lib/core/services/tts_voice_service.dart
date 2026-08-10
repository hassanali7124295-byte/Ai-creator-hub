import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Step 21A — Premium Voice Engine (Foundation).
///
/// [VoiceManager] is the single owner of the app's [FlutterTts] instance
/// and the single source of truth for "what is speaking right now". Every
/// screen that offers a Speak button talks to `VoiceManager.instance`
/// instead of touching a [FlutterTts] object itself, which is what makes
/// the following guarantees possible app-wide, not just per-screen:
///
///  • Only one utterance is ever active. Starting a new one always stops
///    whatever is currently playing first.
///  • Tapping the same id again stops it instantly — no loading pause.
///  • Rapid taps (same id or different ids) can never produce overlapping
///    or duplicate speech: every async step is guarded by [_generation],
///    a counter bumped on every call, so a superseded request that's
///    still mid-flight simply gives up instead of clobbering state a
///    newer request already set.
///  • The underlying engine's completion/cancel/error callbacks carry no
///    id of their own, so a stale one (e.g. the cancel event produced by
///    our own `tts.stop()` when interrupting a previous message) is
///    recognized and ignored via [_liveSpeakGeneration] instead of being
///    allowed to wipe out a newer utterance's state.
///
/// Step 48 — Voice Selection + Free Voice Picker (see
/// CHANGE_REPORT_STEP48.md): this Step 47 finding stands unchanged —
/// Android TTS voice names can't be reliably classified as "male"/
/// "female" from their strings alone, and a male Urdu voice can't be
/// guaranteed to exist on every device. Rather than continue guessing,
/// this step (a) best-effort prefers Google's TTS engine on Android when
/// it's actually installed (generally the broadest/most natural voice
/// set, including Urdu where available), and (b) exposes the device's
/// *real* voice list to a Settings picker so the person can explicitly
/// choose (and persist) their own preferred voice per language, with a
/// live 🔊 preview. The existing heuristic in [_bestVoice] is kept
/// exactly as-is as the Automatic fallback for whichever language the
/// person hasn't picked a voice for — this step does not touch or
/// re-tune it. Every existing public method
/// (`toggle`/`stop`/`dispose`/`ensureInitialized`/`state`/`activeId`/
/// `isBusy`/`addListener`/`removeListener`) keeps its exact previous
/// signature and behavior; `chat_screen.dart` needed zero changes.
enum VoiceState { idle, loading, speaking, stopped, error }

typedef VoiceStateListener = void Function(VoiceState state, Object? activeId);

/// Step 48 — a single voice exactly as reported by the device's TTS
/// engine via `flutter_tts.getVoices` — never invented or assumed. Only
/// [name] and [locale] are used: the two keys `flutter_tts` documents as
/// present across every platform. Other keys some platforms/engines
/// include (gender, quality, identifier, ...) are not modeled here on
/// purpose — Step 47 found voice names/metadata can't be trusted to
/// reliably encode gender, so this stays limited to what can actually be
/// guaranteed.
@immutable
class TtsVoiceOption {
  final String name;
  final String locale;
  const TtsVoiceOption({required this.name, required this.locale});

  /// True when this voice's own reported locale is Urdu (`ur*`) — read
  /// directly from the voice data the engine returned, never guessed
  /// from the voice's name.
  bool get isUrdu => locale.toLowerCase().startsWith('ur');

  /// True when this voice's own reported locale is English (`en*`).
  bool get isEnglish => locale.toLowerCase().startsWith('en');

  Map<String, String> toMap() => {'name': name, 'locale': locale};

  @override
  bool operator ==(Object other) =>
      other is TtsVoiceOption && other.name == name && other.locale == locale;

  @override
  int get hashCode => Object.hash(name, locale);
}

class VoiceManager {
  VoiceManager._internal();

  static final VoiceManager instance = VoiceManager._internal();

  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  Future<void>? _initializing;

  VoiceState _state = VoiceState.idle;
  Object? _activeId;

  /// Bumped on every [toggle]/[stop]/[previewVoice] call. Every async
  /// step re-checks its own snapshot of this value before touching shared
  /// state, so an older call that's still awaiting something can never
  /// overwrite what a newer call has already done.
  int _generation = 0;

  /// The generation that actually issued the in-flight `tts.speak(...)`
  /// call, if any. Used to tell a genuine finish/cancel/error for the
  /// *current* utterance apart from a stale echo belonging to one we
  /// already interrupted.
  int? _liveSpeakGeneration;

  final List<VoiceStateListener> _listeners = [];

  VoiceState get state => _state;
  Object? get activeId => _activeId;
  bool get isBusy => _state == VoiceState.loading || _state == VoiceState.speaking;

  void addListener(VoiceStateListener listener) => _listeners.add(listener);

  void removeListener(VoiceStateListener listener) => _listeners.remove(listener);

  void _emit() {
    for (final listener in List<VoiceStateListener>.of(_listeners)) {
      listener(_state, _activeId);
    }
  }

  /// Wires up the engine's callbacks, applies natural defaults, and warms
  /// the voice cache. Safe to call from every screen that uses voice —
  /// only the first call does real work; the rest await the same Future.
  Future<void> ensureInitialized() {
    if (_initialized) return Future.value();
    return _initializing ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    _tts.setCompletionHandler(() => _handleEngineFinished(VoiceState.idle));
    _tts.setCancelHandler(() => _handleEngineFinished(VoiceState.stopped));
    _tts.setErrorHandler((_) => _handleEngineFinished(VoiceState.error));
    await _tryAsync(() => _tts.awaitSpeakCompletion(true));
    // Step 48: attempted before the first voice-list fetch below, since
    // switching engines changes which voices are available.
    await _preferGoogleEngineIfAvailable();
    await _applyNaturalDefaults(_tts);
    await _cacheVoices(_tts);
    // Step 48: restore the person's saved voice choice(s), if any, now
    // that the real voice list is loaded to validate them against.
    await _loadPersistedSelection();
    _initialized = true;
  }

  void _handleEngineFinished(VoiceState terminal) {
    // A callback only belongs to the utterance we're still tracking as
    // "live". Anything else is a stale echo (most commonly the cancel
    // event our own `tts.stop()` produces when interrupting a previous
    // message) arriving after a newer utterance has already taken over —
    // ignore it rather than let it erase the newer state.
    if (_liveSpeakGeneration == null || _liveSpeakGeneration != _generation) {
      return;
    }
    _liveSpeakGeneration = null;
    _state = terminal;
    _activeId = null;
    _emit();
  }

  /// Speaks [text] for [id], or stops instantly if [id] is already the
  /// one speaking/loading. Only one message ever plays: starting a new
  /// one always stops whatever is currently active first.
  Future<void> toggle(Object id, String text) async {
    await ensureInitialized();
    final myGeneration = ++_generation;

    if (_activeId == id && isBusy) {
      await _stopInternal(myGeneration, VoiceState.stopped);
      return;
    }

    await _tryAsync(() => _tts.stop());
    if (myGeneration != _generation) return; // superseded while stopping

    _activeId = id;
    _state = VoiceState.loading;
    _emit();

    // A short, deliberate pause so the loading state is perceptible —
    // still fully cancellable by a follow-up tap during this window.
    await Future.delayed(const Duration(milliseconds: 150));
    if (myGeneration != _generation) return;

    final isUrdu = _looksUrdu(text);
    await _applyNaturalDefaults(_tts, isUrdu: isUrdu);
    await _tryAsync(() => _tts.setLanguage(isUrdu ? 'ur-PK' : 'en-US'));
    if (_voiceCache == null && !_voiceCacheAttempted) {
      await _cacheVoices(_tts);
    }
    final voice = _bestVoice(isUrdu: isUrdu);
    if (voice != null) {
      await _tryAsync(() => _tts.setVoice(voice));
    }
    if (myGeneration != _generation) return; // superseded during setup

    _liveSpeakGeneration = myGeneration;
    _state = VoiceState.speaking;
    _emit();

    await _tryAsync(() => _tts.speak(text));
  }

  /// Stops whatever is currently speaking/loading, if anything.
  Future<void> stop() async {
    if (_state == VoiceState.idle) return;
    final myGeneration = ++_generation;
    await _stopInternal(myGeneration, VoiceState.stopped);
  }

  Future<void> _stopInternal(int generation, VoiceState terminal) async {
    _liveSpeakGeneration = null;
    await _tryAsync(() => _tts.stop());
    if (generation != _generation) return; // an even newer call took over
    _state = terminal;
    _activeId = null;
    _emit();
  }

  /// Keeps the manager's notion of "which message" in sync when a
  /// caller's own ids shift under it (e.g. deleting a message above the
  /// one currently speaking renumbers every later index) — without
  /// touching playback at all.
  void reassignActiveId(Object newId) {
    if (!isBusy) return;
    _activeId = newId;
    _emit();
  }

  /// Releases everything this manager owns. Intended for whole-app
  /// teardown (e.g. tests) — a single screen going away should just stop
  /// playback and remove its own listener instead, since the manager is
  /// a shared, app-wide singleton.
  Future<void> dispose() async {
    _listeners.clear();
    await _tryAsync(() => _tts.stop());
    _state = VoiceState.idle;
    _activeId = null;
    _liveSpeakGeneration = null;
  }

  // ---------------------------------------------------------------------
  // Step 48 — Google TTS engine preference (Android only; best-effort,
  // never fatal, never forced).
  // ---------------------------------------------------------------------

  static const String _googleTtsEnginePackage = 'com.google.android.tts';

  /// Best-effort: if the device reports Google's TTS engine as one of its
  /// installed engines and it isn't already the active one, switches to
  /// it — Google's engine generally ships the broadest/most natural
  /// voice set on Android, including Urdu where available.
  /// `getEngines`/`getDefaultEngine`/`setEngine` are documented
  /// Android-only `flutter_tts` APIs; on any other platform, or if the
  /// call throws for *any* reason (no engines installed, a device/engine
  /// that rejects switching, a platform that doesn't support engine
  /// enumeration, etc.), this silently does nothing and the existing
  /// system/default engine keeps being used exactly as before Step 48 —
  /// never crashes, never blocks initialization, never forces a switch
  /// that could break playback on that device.
  Future<void> _preferGoogleEngineIfAvailable() async {
    try {
      final enginesRaw = await _tts.getEngines;
      if (enginesRaw is! List) return;
      final engines = enginesRaw.map((e) => e.toString()).toList();
      if (!engines.contains(_googleTtsEnginePackage)) return;

      String? current;
      try {
        final currentRaw = await _tts.getDefaultEngine;
        if (currentRaw is String) current = currentRaw;
      } catch (_) {
        // Some engines/devices don't support querying the current engine
        // — fall through and attempt the switch anyway; worst case it's
        // a harmless no-op if Google's engine is already active.
      }
      if (current == _googleTtsEnginePackage) return;

      await _tts.setEngine(_googleTtsEnginePackage);
      debugPrint('VoiceManager: switched to Google TTS engine.');
    } catch (e) {
      debugPrint('VoiceManager: Google TTS engine preference skipped ($e).');
    }
  }

  // ---------------------------------------------------------------------
  // Language detection & voice selection — the Step 21A heuristic is
  // unchanged (Step 48 deliberately does not re-tune it); it now only
  // runs as the Automatic fallback for a language the person hasn't
  // explicitly picked a voice for (see [_bestVoice]).
  // ---------------------------------------------------------------------

  /// Arabic-script Unicode ranges — Urdu is written in this script, and
  /// AI replies contain no other script that overlaps it, so counting
  /// these characters is a reliable, dependency-free language detector.
  static final RegExp _arabicScript =
      RegExp(r'[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]');

  static const List<String> _maleHints = [
    'male',
    '#male',
    'en-us-x-iom', // Google TTS "male 1" legacy code name
    'en-us-x-tpc', // Google TTS "male 2" legacy code name
    'en-gb-x-gbb', // Google TTS UK male legacy code name
    'ur-pk-x-had', // Google TTS Urdu male legacy code name
    'daniel', // common iOS/Android male voice name
    'aaron',
    'fred',
  ];

  static const List<String> _femaleHints = [
    'female',
    '#female',
    'en-us-x-sfg',
    'en-us-x-iob',
    'ur-pk-x-hae',
    'samantha',
    'karen',
    'victoria',
    'moira',
  ];

  /// Every voice the engine reports, fetched once and reused for both
  /// English and Urdu lookups — avoids re-querying the platform channel
  /// on every single tap of the Speak button.
  List<Map<String, String>>? _voiceCache;
  bool _voiceCacheAttempted = false;

  /// The Automatic voice selected for each language, memoized so the
  /// exact same voice is reused on every call — selection never changes
  /// randomly between taps of the Speak button, only if the underlying
  /// voice list itself changes (e.g. a fresh cache after a cold start).
  final Map<bool, Map<String, String>?> _selectedVoice = {};

  /// Step 48 — the person's own explicit voice choice per language
  /// (`true` = Urdu, `false` = English), persisted via
  /// [SharedPreferences] and restored on the next launch. `null` for a
  /// language means Automatic — [_bestVoice]'s existing heuristic picks
  /// for that language exactly as it always has. Always revalidated
  /// against the live [_voiceCache] before use (see [_bestVoice] and
  /// [_revalidatePersistedSelection]) — a voice that no longer exists on
  /// this device is never trusted silently.
  final Map<bool, TtsVoiceOption?> _userVoiceOverride = {};

  static const String _prefKeyNameUr = 'tts_selected_voice_name_ur';
  static const String _prefKeyLocaleUr = 'tts_selected_voice_locale_ur';
  static const String _prefKeyNameEn = 'tts_selected_voice_name_en';
  static const String _prefKeyLocaleEn = 'tts_selected_voice_locale_en';

  /// True when enough of [text] is Arabic-script (Urdu) characters that
  /// it should be read as Urdu rather than English. A small threshold
  /// avoids one stray character (e.g. a quoted Urdu word in an otherwise
  /// English sentence) flipping the whole reply's voice.
  bool _looksUrdu(String text) {
    final letters = text.replaceAll(RegExp(r'\s'), '');
    if (letters.isEmpty) return false;
    final urduLetters = _arabicScript.allMatches(text).length;
    return urduLetters > 0 && urduLetters >= letters.length * 0.25;
  }

  /// Natural, comfortable pacing shared by both languages, plus max
  /// volume. Urdu reads slightly slower than English at the same rate
  /// value on most engines, so it gets a touch more time per syllable to
  /// avoid sounding rushed or clipped.
  Future<void> _applyNaturalDefaults(FlutterTts tts, {bool isUrdu = false}) async {
    await _tryAsync(() => tts.setVolume(1.0));
    await _tryAsync(() => tts.setPitch(1.0));
    await _tryAsync(() => tts.setSpeechRate(isUrdu ? 0.42 : 0.47));
  }

  /// Fetches and caches every voice the engine reports. Only ever does
  /// real work once per call site — a failed/empty result is remembered
  /// too, so we don't keep hammering an engine that doesn't support
  /// enumeration. Callers that need a guaranteed fresh fetch (Step 48 —
  /// see [loadAvailableVoices]'s `forceRefresh`) call this directly.
  Future<void> _cacheVoices(FlutterTts tts) async {
    _voiceCacheAttempted = true;
    _selectedVoice.clear();
    List<dynamic>? raw0;
    try {
      final raw = await tts.getVoices;
      if (raw is List) raw0 = raw;
    } catch (_) {
      _voiceCache = [];
      return;
    }
    if (raw0 == null) {
      _voiceCache = [];
      return;
    }

    _voiceCache = raw0
        .map((entry) {
          if (entry is Map) {
            final name = entry['name']?.toString();
            final locale = entry['locale']?.toString();
            if (name != null && locale != null) {
              return {'name': name, 'locale': locale};
            }
          }
          return null;
        })
        .whereType<Map<String, String>>()
        .toList();
  }

  /// Picks the voice actually used for the requested language: the
  /// person's own explicit choice (Step 48) if they made one and it still
  /// exists on this device, otherwise the existing Step 21A heuristic
  /// (unchanged, see the class doc above) as the Automatic fallback.
  ///
  /// The Automatic heuristic's own priority order is unchanged:
  ///   1. ur-PK male (when the reply is Urdu)
  ///   2. en-US male (when the reply is English)
  ///   3. en-GB male (when the reply is English and no en-US male exists)
  ///   4. Highest-quality male voice available, any locale (when the
  ///      requested language has no male voice of its own)
  ///   5. If no male voice exists at all: best available voice for the
  ///      requested language — but NEVER a voice hardcoded/flagged female
  ///      when a non-female alternative exists.
  ///
  /// If nothing matches at all (empty/unsupported voice list), this
  /// returns `null` and the caller simply leaves the engine's own default
  /// voice in place — never a crash, never a thrown exception.
  Map<String, String>? _bestVoice({required bool isUrdu}) {
    // Step 48 — an explicit user choice for this language always wins,
    // as long as it's still an actual voice on this device right now
    // (revalidated against the live cache every time, not just trusted
    // from persisted storage).
    final override = _userVoiceOverride[isUrdu];
    if (override != null) {
      final stillExists = (_voiceCache ?? const <Map<String, String>>[]).any(
        (v) => v['name'] == override.name && v['locale'] == override.locale,
      );
      if (stillExists) {
        return override.toMap();
      }
      // The previously-selected voice disappeared (uninstalled voice
      // pack, engine change, restore on a different device, etc.) — fall
      // back to Automatic for this language rather than silently
      // failing or crashing, and forget the stale choice so this check
      // doesn't repeat every call.
      _userVoiceOverride[isUrdu] = null;
      unawaited(_clearPersistedSelection(isUrdu: isUrdu));
    }

    if (_selectedVoice.containsKey(isUrdu)) {
      return _selectedVoice[isUrdu];
    }

    final voices = _voiceCache;
    if (voices == null || voices.isEmpty) {
      _selectedVoice[isUrdu] = null;
      return null;
    }

    bool matchesAny(String haystack, List<String> hints) =>
        hints.any((hint) => haystack.contains(hint));
    bool isMale(Map<String, String> v) {
      final key = v['name']!.toLowerCase();
      return matchesAny(key, _maleHints) && !matchesAny(key, _femaleHints);
    }

    Map<String, String>? firstMaleWithLocale(String localePrefix) {
      for (final v in voices) {
        if (v['locale']!.toLowerCase().startsWith(localePrefix) && isMale(v)) {
          return v;
        }
      }
      return null;
    }

    // Requested-language voices only — never cross into the other
    // language's locale, so pronunciation always matches the text.
    final prefix = isUrdu ? 'ur' : 'en';
    final matching =
        voices.where((v) => v['locale']!.toLowerCase().startsWith(prefix)).toList();

    Map<String, String>? chosen;
    String reason;

    if (isUrdu) {
      // 1. ur-PK male.
      chosen = firstMaleWithLocale('ur-pk');
      reason = 'priority #1 ur-PK male';
    } else {
      // 2. en-US male, then 3. en-GB male.
      chosen = firstMaleWithLocale('en-us');
      reason = 'priority #2 en-US male';
      chosen ??= firstMaleWithLocale('en-gb');
      reason = 'priority #3 en-GB male';
    }

    // 4. No male voice in the requested language — fall back to the
    // highest-quality male voice available in any locale, so the reply
    // is still read by a male voice even if it won't be native-accented.
    if (chosen == null) {
      final maleAny = voices.where(isMale).toList();
      if (maleAny.isNotEmpty) {
        final network = maleAny.where((v) => v['name']!.toLowerCase().contains('network'));
        chosen = network.isNotEmpty ? network.first : maleAny.first;
        reason = 'priority #4 best available male voice (different locale)';
      }
    }

    // 5. No male voice exists anywhere — never hardcode a female voice;
    // just pick the best available voice for the requested language.
    if (chosen == null && matching.isNotEmpty) {
      final untaggedNetwork = matching.where((v) {
        final key = v['name']!.toLowerCase();
        return key.contains('network') && !matchesAny(key, _femaleHints);
      });
      if (untaggedNetwork.isNotEmpty) {
        chosen = untaggedNetwork.first;
        reason = 'no male voice available — best untagged network voice';
      } else {
        final untagged =
            matching.where((v) => !matchesAny(v['name']!.toLowerCase(), _femaleHints));
        chosen = untagged.isNotEmpty ? untagged.first : matching.first;
        reason = untagged.isNotEmpty
            ? 'no male voice available — best untagged voice'
            : 'no male or untagged voice available — best voice for language';
      }
    }

    _selectedVoice[isUrdu] = chosen;
    if (chosen != null) {
      debugPrint(
        'VoiceManager: selected voice "${chosen['name']}" '
        '(${chosen['locale']}) for ${isUrdu ? 'Urdu' : 'English'} — $reason.',
      );
    } else {
      debugPrint(
        'VoiceManager: no voice available for ${isUrdu ? 'Urdu' : 'English'} — '
        'using engine default.',
      );
    }
    return chosen;
  }

  static Future<void> _tryAsync(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Unsupported on this engine/platform — leave the existing setting
      // (or engine default) untouched rather than surfacing an error.
    }
  }

  // ---------------------------------------------------------------------
  // Step 48 — public API for the Settings voice picker. Nothing above
  // this point changes `chat_screen.dart`'s existing
  // `VoiceManager.instance.toggle(index, text)` behavior in any way.
  // ---------------------------------------------------------------------

  /// Every voice the device's TTS engine actually reports, as
  /// [TtsVoiceOption]s — never invented, always exactly what
  /// `flutter_tts.getVoices` returned. Ensures the manager is initialized
  /// and the voice list has been fetched at least once first. Pass
  /// [forceRefresh] to re-query the engine (e.g. the person just
  /// installed a new voice pack in system settings) instead of reusing
  /// whatever was cached at app start.
  Future<List<TtsVoiceOption>> loadAvailableVoices({bool forceRefresh = false}) async {
    await ensureInitialized();
    if (forceRefresh || (_voiceCache == null && !_voiceCacheAttempted)) {
      await _cacheVoices(_tts);
      // A fresh voice list may have dropped a previously-selected voice
      // — re-validate the persisted selection against it immediately so
      // the picker never shows a checkmark next to a voice that's gone.
      _revalidatePersistedSelection();
    }
    return (_voiceCache ?? const <Map<String, String>>[])
        .map((v) => TtsVoiceOption(name: v['name']!, locale: v['locale']!))
        .toList(growable: false);
  }

  /// The subset of the last [loadAvailableVoices] result whose locale is
  /// Urdu. Empty if the device has no Urdu voice installed — never
  /// invented. Only meaningful after [loadAvailableVoices] has been
  /// awaited at least once.
  List<TtsVoiceOption> get urduVoices => (_voiceCache ?? const <Map<String, String>>[])
      .where((v) => v['locale']!.toLowerCase().startsWith('ur'))
      .map((v) => TtsVoiceOption(name: v['name']!, locale: v['locale']!))
      .toList(growable: false);

  /// The subset of the last [loadAvailableVoices] result whose locale is
  /// English. Only meaningful after [loadAvailableVoices] has been
  /// awaited at least once.
  List<TtsVoiceOption> get englishVoices => (_voiceCache ?? const <Map<String, String>>[])
      .where((v) => v['locale']!.toLowerCase().startsWith('en'))
      .map((v) => TtsVoiceOption(name: v['name']!, locale: v['locale']!))
      .toList(growable: false);

  /// The person's current explicit choice for [isUrdu]'s language, or
  /// `null` for Automatic (the existing heuristic keeps picking). Already
  /// revalidated against the live voice cache — never returns a voice
  /// that no longer exists on this device.
  TtsVoiceOption? selectedVoiceFor({required bool isUrdu}) => _userVoiceOverride[isUrdu];

  /// Sets [voice] as the person's explicit choice for its own language
  /// (read from `voice.isUrdu` — never a separate, possibly-mismatched
  /// parameter, so an English voice can never end up saved as the Urdu
  /// choice or vice versa), persists it via [SharedPreferences] so it
  /// survives app restarts, and clears the Automatic-pick memo for that
  /// language so the very next [toggle] call picks it up immediately.
  Future<void> selectVoice(TtsVoiceOption voice) async {
    await ensureInitialized();
    final isUrdu = voice.isUrdu;
    _userVoiceOverride[isUrdu] = voice;
    _selectedVoice.remove(isUrdu);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(isUrdu ? _prefKeyNameUr : _prefKeyNameEn, voice.name);
      await prefs.setString(isUrdu ? _prefKeyLocaleUr : _prefKeyLocaleEn, voice.locale);
    } catch (_) {
      // Persistence failed — the choice still applies for the rest of
      // this app session (in-memory `_userVoiceOverride` above is
      // already set); it just won't survive a restart.
    }
  }

  /// Clears the explicit choice for one language only (back to Automatic
  /// for that language), leaving the other language's selection
  /// untouched.
  Future<void> clearSelectedVoice({required bool isUrdu}) async {
    _userVoiceOverride[isUrdu] = null;
    _selectedVoice.remove(isUrdu);
    await _clearPersistedSelection(isUrdu: isUrdu);
  }

  /// Clears both languages' explicit choices at once — the "Reset to
  /// Automatic" action in Settings.
  Future<void> resetToAutomatic() async {
    await clearSelectedVoice(isUrdu: true);
    await clearSelectedVoice(isUrdu: false);
  }

  /// A dedicated identifier for preview playback — deliberately never an
  /// `int`, the only type `chat_screen.dart`'s `_onVoiceStateChanged`
  /// treats as "a chat message is speaking" — so a preview can never be
  /// mistaken for a message bubble speaking, and vice versa.
  static const Object _previewSentinel = #ttsVoicePreview;

  /// Speaks a short sample of [voice] so the person can hear it before
  /// choosing it. Stops whatever is currently playing first (the same
  /// generation-guarded stop [toggle] uses, so a preview can never
  /// overlap with itself or with a real message), and applies [voice]'s
  /// own locale/language directly — never runs it through the Urdu/
  /// English text heuristic, since the voice itself already says which
  /// language it is. Normal app TTS state is restored afterward via the
  /// exact same completion/cancel/error handlers every other utterance
  /// already uses (see [_doInitialize]) — no separate teardown path.
  /// Never interferes with recorded voice-message playback — that's an
  /// entirely separate `VoicePlaybackManager`/`audioplayers` instance
  /// this file never touches.
  Future<void> previewVoice(TtsVoiceOption voice) async {
    await ensureInitialized();
    final myGeneration = ++_generation;
    await _tryAsync(() => _tts.stop());
    if (myGeneration != _generation) return; // superseded while stopping

    _activeId = _previewSentinel;
    _state = VoiceState.loading;
    _emit();

    final isUrdu = voice.isUrdu;
    await _applyNaturalDefaults(_tts, isUrdu: isUrdu);
    await _tryAsync(() => _tts.setLanguage(isUrdu ? 'ur-PK' : 'en-US'));
    await _tryAsync(() => _tts.setVoice(voice.toMap()));
    if (myGeneration != _generation) return; // superseded during setup

    _liveSpeakGeneration = myGeneration;
    _state = VoiceState.speaking;
    _emit();

    final sample = isUrdu
        ? 'السلام علیکم، یہ اس آواز کا ایک مختصر نمونہ ہے۔'
        : 'Hello, this is a short preview of this voice.';
    await _tryAsync(() => _tts.speak(sample));
  }

  // ---------------------------------------------------------------------
  // Step 48 — persistence for the selected voice(s).
  // ---------------------------------------------------------------------

  Future<void> _loadPersistedSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final urName = prefs.getString(_prefKeyNameUr);
      final urLocale = prefs.getString(_prefKeyLocaleUr);
      if (urName != null && urLocale != null) {
        _userVoiceOverride[true] = TtsVoiceOption(name: urName, locale: urLocale);
      }
      final enName = prefs.getString(_prefKeyNameEn);
      final enLocale = prefs.getString(_prefKeyLocaleEn);
      if (enName != null && enLocale != null) {
        _userVoiceOverride[false] = TtsVoiceOption(name: enName, locale: enLocale);
      }
    } catch (_) {
      // Persistence unavailable for some reason — behave exactly as if
      // nothing had ever been selected (Automatic for both languages).
    }
    _revalidatePersistedSelection();
  }

  /// Drops any restored/selected voice that isn't actually present in the
  /// current [_voiceCache] — e.g. restored on a fresh install, a
  /// different device via backup/restore, or after a voice pack was
  /// uninstalled. Never crashes; simply falls back to Automatic for that
  /// language (per Step 48 requirement E).
  void _revalidatePersistedSelection() {
    for (final isUrdu in const [true, false]) {
      final selected = _userVoiceOverride[isUrdu];
      if (selected == null) continue;
      final stillExists = (_voiceCache ?? const <Map<String, String>>[]).any(
        (v) => v['name'] == selected.name && v['locale'] == selected.locale,
      );
      if (!stillExists) {
        _userVoiceOverride[isUrdu] = null;
        unawaited(_clearPersistedSelection(isUrdu: isUrdu));
      }
    }
  }

  Future<void> _clearPersistedSelection({required bool isUrdu}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(isUrdu ? _prefKeyNameUr : _prefKeyNameEn);
      await prefs.remove(isUrdu ? _prefKeyLocaleUr : _prefKeyLocaleEn);
    } catch (_) {
      // Best-effort — worst case the stale keys linger in storage, but
      // `_userVoiceOverride` in memory is already cleared, so they're
      // never trusted again this session.
    }
  }
}
