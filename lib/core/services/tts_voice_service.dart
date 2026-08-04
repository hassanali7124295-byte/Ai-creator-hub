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

  /// Picks the best cached voice for the requested language: an explicit
  /// male match first, then a higher-quality "network" voice, then just
  /// the first voice for that language. Returns null (leave the engine's
  /// own default for the locale we just set) if no voices are cached or
  /// none match the language.
  static Map<String, String>? _bestVoice({required bool isUrdu}) {
    final voices = _voiceCache;
    if (voices == null || voices.isEmpty) return null;

    final prefix = isUrdu ? 'ur' : 'en';
    final matching =
        voices.where((v) => v['locale']!.toLowerCase().startsWith(prefix)).toList();
    if (matching.isEmpty) return null;

    bool matchesAny(String haystack, List<String> hints) =>
        hints.any((hint) => haystack.contains(hint));

    // 1. Explicit male match (and not also flagged female).
    for (final v in matching) {
      final key = v['name']!.toLowerCase();
      if (matchesAny(key, _maleHints) && !matchesAny(key, _femaleHints)) {
        return v;
      }
    }

    // 2. No explicit gender tag — prefer a higher-quality "network" voice
    // over a "local" one, as long as it isn't explicitly flagged female.
    final untaggedNetwork = matching.where((v) {
      final key = v['name']!.toLowerCase();
      return key.contains('network') && !matchesAny(key, _femaleHints);
    });
    if (untaggedNetwork.isNotEmpty) return untaggedNetwork.first;

    // 3. Any voice for the language not explicitly flagged female — still
    // better than leaving an unpredictable default in a mixed voice pack.
    final untagged =
        matching.where((v) => !matchesAny(v['name']!.toLowerCase(), _femaleHints));
    if (untagged.isNotEmpty) return untagged.first;

    // 4. Last resort: the single best (first) voice available for the
    // language, even if it's flagged female — satisfies "always speak in
    // the detected language" over "always speak with a male voice" when
    // a language only ships one voice.
    return matching.first;
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
