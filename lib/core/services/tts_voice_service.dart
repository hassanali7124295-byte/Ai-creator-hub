import 'package:flutter_tts/flutter_tts.dart';

/// Step 17 (section 6): configures a [FlutterTts] instance to sound as
/// natural as possible for "Read Aloud" — prefers a male English voice,
/// a natural (not default-robotic) speech rate, and a balanced pitch.
///
/// Falls back gracefully at every step: if voice enumeration isn't
/// supported on a device/engine, or nothing matches, the engine's own
/// default voice is left in place, so offline / older devices keep
/// working exactly as before — this only ever *upgrades* the voice when
/// a clearly better one is available.
class TtsVoiceService {
  const TtsVoiceService._();

  /// Substrings that flag a voice as male, seen across common Android TTS
  /// engines (Google, Samsung) and iOS voice names. Checked before the
  /// female list so an explicit "male" tag always wins.
  static const List<String> _maleHints = [
    'male',
    '#male',
    'en-us-x-iom', // Google TTS "male 1" legacy code name
    'en-us-x-tpc', // Google TTS "male 2" legacy code name
    'en-gb-x-gbb', // Google TTS UK male legacy code name
    'daniel', // common iOS/Android male voice name
    'aaron',
    'fred',
  ];

  static const List<String> _femaleHints = [
    'female',
    '#female',
    'en-us-x-sfg',
    'en-us-x-iob',
    'samantha',
    'karen',
    'victoria',
    'moira',
  ];

  /// Applies natural-sounding defaults, then tries to switch to the best
  /// available male English voice. Safe to call every time [FlutterTts]
  /// is created — every step is independently wrapped so one unsupported
  /// call (e.g. `getVoices` on an engine that doesn't expose it) never
  /// blocks the rest.
  static Future<void> configureNaturalMaleVoice(FlutterTts tts) async {
    // Wait for one utterance to fully finish before "speak" resolves —
    // needed for our stop/replace-in-flight logic in ChatScreen either way.
    await _tryAsync(() => tts.awaitSpeakCompletion(true));

    // A natural, non-robotic pace and a balanced pitch. 1.0 pitch is
    // neither chipmunk-high nor artificially deep; ~0.48 speech rate
    // reads as normal conversational pace on both Android and iOS engines
    // (both platforms treat 1.0 as their own "fast" ceiling).
    await _tryAsync(() => tts.setPitch(1.0));
    await _tryAsync(() => tts.setSpeechRate(0.48));
    await _tryAsync(() => tts.setLanguage('en-US'));

    final voice = await _bestMaleVoice(tts);
    if (voice != null) {
      await _tryAsync(() => tts.setVoice(voice));
    }
  }

  /// Looks through every voice the engine reports and scores English
  /// voices, preferring (in order): an explicit male-name match, then a
  /// higher-quality "network" voice over a legacy "local" one, then just
  /// the first English voice available. Returns null (leave the engine
  /// default) if voices can't be enumerated at all.
  static Future<Map<String, String>?> _bestMaleVoice(FlutterTts tts) async {
    List<dynamic>? voices;
    try {
      final raw = await tts.getVoices;
      if (raw is List) voices = raw;
    } catch (_) {
      return null; // engine doesn't support voice enumeration — use default
    }
    if (voices == null || voices.isEmpty) return null;

    Map<String, String>? asVoiceMap(dynamic entry) {
      if (entry is Map) {
        final name = entry['name']?.toString();
        final locale = entry['locale']?.toString();
        if (name != null && locale != null) {
          return {'name': name, 'locale': locale};
        }
      }
      return null;
    }

    bool isEnglish(Map<String, String> v) =>
        v['locale']!.toLowerCase().startsWith('en');

    bool matchesAny(String haystack, List<String> hints) =>
        hints.any((hint) => haystack.contains(hint));

    final english = voices
        .map(asVoiceMap)
        .whereType<Map<String, String>>()
        .where(isEnglish)
        .toList();
    if (english.isEmpty) return null;

    // 1. Explicit male match (and not also flagged female).
    for (final v in english) {
      final key = v['name']!.toLowerCase();
      if (matchesAny(key, _maleHints) && !matchesAny(key, _femaleHints)) {
        return v;
      }
    }

    // 2. No explicit gender tag either way — prefer a higher-quality
    // "network" voice over a "local" one (network voices sound noticeably
    // less robotic), as long as it isn't explicitly flagged female.
    final untaggedNetwork = english.where((v) {
      final key = v['name']!.toLowerCase();
      return key.contains('network') && !matchesAny(key, _femaleHints);
    });
    if (untaggedNetwork.isNotEmpty) return untaggedNetwork.first;

    // 3. Last resort: any English voice not explicitly flagged female —
    // still better than leaving an unpredictable engine default in a
    // mixed voice pack, and keeps offline/local-only voices working.
    final untagged =
        english.where((v) => !matchesAny(v['name']!.toLowerCase(), _femaleHints));
    if (untagged.isNotEmpty) return untagged.first;

    return null;
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
