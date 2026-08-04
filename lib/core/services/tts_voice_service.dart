import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Step 19 — professional, auto-language Text-to-Speech.
///
/// Detects whether a reply is Urdu or English from its script (no manual
/// switching), then speaks it with the best available *male* voice for
/// that language — falling back to the highest-quality voice the engine
/// offers when no male voice exists (this matters most for Urdu, where
/// many voice packs only ship one or two voices total).
///
/// Every platform call is wrapped in [_tryAsync], so an engine that
/// doesn't support voice enumeration, a locale it doesn't have installed,
/// or any other unsupported call never throws — it just leaves the
/// previous setting (or the engine default) in place. Nothing here can
/// crash the app or block the Speak button.
class TtsVoiceService {
  const TtsVoiceService._();

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
  static List<Map<String, String>>? _voiceCache;
  static bool _voiceCacheAttempted = false;

  /// Call once per [FlutterTts] instance (e.g. in `initState`). Sets up
  /// natural, non-robotic defaults and warms the voice cache. Safe to
  /// await in the background — if the first Speak tap lands before this
  /// finishes, [speak] below applies the same settings itself.
  static Future<void> initialize(FlutterTts tts) async {
    await _tryAsync(() => tts.awaitSpeakCompletion(true));
    await _applyNaturalDefaults(tts);
    await _cacheVoices(tts);
  }

  /// Detects the reply's language from its script, switches the engine to
  /// the best matching male voice (or best available voice for that
  /// language if no male voice exists), applies natural pacing/volume,
  /// and speaks. Starts from the beginning every time it's called — the
  /// caller (ChatScreen) is responsible for stopping any in-flight
  /// utterance first, which it already does on every Speak tap.
  static Future<void> speak(FlutterTts tts, String text) async {
    final isUrdu = _looksUrdu(text);

    await _applyNaturalDefaults(tts, isUrdu: isUrdu);
    await _tryAsync(() => tts.setLanguage(isUrdu ? 'ur-PK' : 'en-US'));

    if (_voiceCache == null && !_voiceCacheAttempted) {
      await _cacheVoices(tts);
    }
    final voice = _bestVoice(isUrdu: isUrdu);
    if (voice != null) {
      await _tryAsync(() => tts.setVoice(voice));
    }

    await _tryAsync(() => tts.speak(text));
  }

  /// The voice selected for each language, memoized so the exact same
  /// voice is reused on every call — selection never changes randomly
  /// between taps of the Speak button, only if the underlying voice list
  /// itself changes (e.g. a fresh cache after a cold start).
  static final Map<bool, Map<String, String>?> _selectedVoice = {};

  /// True when enough of [text] is Arabic-script (Urdu) characters that
  /// it should be read as Urdu rather than English. A small threshold
  /// avoids one stray character (e.g. a quoted Urdu word in an otherwise
  /// English sentence) flipping the whole reply's voice.
  static bool _looksUrdu(String text) {
    final letters = text.replaceAll(RegExp(r'\s'), '');
    if (letters.isEmpty) return false;
    final urduLetters = _arabicScript.allMatches(text).length;
    return urduLetters > 0 && urduLetters >= letters.length * 0.25;
  }

  /// Natural, comfortable pacing shared by both languages, plus max
  /// volume. Urdu reads slightly slower than English at the same rate
  /// value on most engines, so it gets a touch more time per syllable to
  /// avoid sounding rushed or clipped.
  static Future<void> _applyNaturalDefaults(FlutterTts tts, {bool isUrdu = false}) async {
    await _tryAsync(() => tts.setVolume(1.0));
    await _tryAsync(() => tts.setPitch(1.0));
    await _tryAsync(() => tts.setSpeechRate(isUrdu ? 0.42 : 0.47));
  }

  /// Fetches and caches every voice the engine reports. Only ever called
  /// once successfully — a failed/empty result is remembered too, so we
  /// don't keep hammering an engine that doesn't support enumeration.
  static Future<void> _cacheVoices(FlutterTts tts) async {
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
  static Map<String, String>? _bestVoice({required bool isUrdu}) {
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
        'TtsVoiceService: selected voice "${chosen['name']}" '
        '(${chosen['locale']}) for ${isUrdu ? 'Urdu' : 'English'} — $reason.',
      );
    } else {
      debugPrint(
        'TtsVoiceService: no voice available for ${isUrdu ? 'Urdu' : 'English'} — '
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
