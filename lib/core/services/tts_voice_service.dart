import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

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
/// Language detection and voice selection are unchanged in behavior from
/// the previous implementation: script-based Urdu/English detection, a
/// male-voice-first preference with graceful fallback, and a voice list
/// that's fetched once and cached for reuse.
enum VoiceState { idle, loading, speaking, stopped, error }

typedef VoiceStateListener = void Function(VoiceState state, Object? activeId);

class VoiceManager {
  VoiceManager._internal();

  static final VoiceManager instance = VoiceManager._internal();

  final FlutterTts _tts = FlutterTts();

  bool _initialized = false;
  Future<void>? _initializing;

  VoiceState _state = VoiceState.idle;
  Object? _activeId;

  /// Bumped on every [toggle]/[stop] call. Every async step re-checks its
  /// own snapshot of this value before touching shared state, so an older
  /// call that's still awaiting something can never overwrite what a
  /// newer call has already done.
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
    await _applyNaturalDefaults(_tts);
    await _cacheVoices(_tts);
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
  // Language detection & voice selection — behavior unchanged from the
  // previous implementation, just owned by the manager instance instead
  // of living as bare static state on a stateless service class.
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

  /// The voice selected for each language, memoized so the exact same
  /// voice is reused on every call — selection never changes randomly
  /// between taps of the Speak button, only if the underlying voice list
  /// itself changes (e.g. a fresh cache after a cold start).
  final Map<bool, Map<String, String>?> _selectedVoice = {};

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
  /// real work once — a failed/empty result is remembered too, so we
  /// don't keep hammering an engine that doesn't support enumeration.
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

  /// Picks the best cached voice for the requested language and remembers
  /// it (see [_selectedVoice]) so repeated calls always return the exact
  /// same voice instead of recomputing — and logs the pick once, so which
  /// voice is in use is always visible in the debug console.
  ///
  /// The reply's detected language (Urdu vs English) is always respected
  /// first — picking a Urdu-locale voice to read an English reply (or vice
  /// versa) would mispronounce it, regardless of the voice's gender. Within
  /// that language, priority matches the product requirement:
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
}
