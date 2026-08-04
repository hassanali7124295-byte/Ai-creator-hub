import 'package:flutter_tts/flutter_tts.dart';

/// Step 17 (section 6) / Step 18.5: configures a [FlutterTts] instance to
/// sound as natural as possible for "Read Aloud" — prefers the best
/// available male voice for whichever language it's about to speak (English
/// or Urdu), a natural (not default-robotic) speech rate, and a balanced
/// pitch.
///
/// Falls back gracefully at every step: if voice enumeration isn't
/// supported on a device/engine, or nothing matches, the engine's own
/// default voice is left in place, so offline / older devices keep
/// working exactly as before — this only ever *upgrades* the voice when
/// a clearly better one is available.
class TtsVoiceService {
  const TtsVoiceService._();

  /// Substrings that flag a voice as male, seen across common Android TTS
  /// engines (Google, Samsung) and iOS voice names, for both English and
  /// Urdu voice packs. Checked before the female list so an explicit
  /// "male" tag always wins.
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

  /// Cached best-match voices, so we only ever enumerate the engine's
  /// voice list once per app session. Populated by [_prepareVoices]; null
  /// means "engine default" (either not found or enumeration failed).
  static Map<String, String>? _englishVoice;
  static Map<String, String>? _urduVoice;
  static bool _voicesPrepared = false;

  /// Applies natural-sounding defaults and switches to the best available
  /// male English voice, then eagerly looks up (and caches) the best male
  /// Urdu voice too, so [speak] can switch languages instantly later. Safe
  /// to call every time [FlutterTts] is created — every step is
  /// independently wrapped so one unsupported call (e.g. `getVoices` on an
  /// engine that doesn't expose it) never blocks the rest.
  static Future<void> configureNaturalVoices(FlutterTts tts) async {
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

    await _prepareVoices(tts);
    if (_englishVoice != null) {
      await _tryAsync(() => tts.setVoice(_englishVoice!));
    }
  }

  /// Speaks [text] aloud, automatically switching [tts] to the best
  /// available Urdu male voice when [text] is written in Urdu script, or
  /// the best available English male voice otherwise (this also covers
  /// Roman Urdu, i.e. Urdu written in Latin letters, which reads fine
  /// through the English voice). Call [configureNaturalVoices] once first
  /// so both voices are already resolved — if it hasn't finished yet, this
  /// still falls back to whatever language/voice is currently set.
  static Future<void> speak(FlutterTts tts, String text) async {
    await _prepareVoices(tts);

    if (_looksLikeUrdu(text)) {
      await _tryAsync(() => tts.setLanguage('ur-PK'));
      if (_urduVoice != null) {
        await _tryAsync(() => tts.setVoice(_urduVoice!));
      }
    } else {
      await _tryAsync(() => tts.setLanguage('en-US'));
      if (_englishVoice != null) {
        await _tryAsync(() => tts.setVoice(_englishVoice!));
      }
    }

    await tts.speak(text);
  }

  /// True if [text] contains any character from the Arabic-script Unicode
  /// blocks Urdu is written in (the base Arabic block plus the Arabic
  /// Supplement and Presentation Forms blocks, which cover the extra
  /// letters Urdu adds, like ٹ، ڈ، ڑ، ں، ھ، ے). Roman Urdu (Urdu words
  /// spelled out in Latin letters) is indistinguishable from English by
  /// script alone, so it's read with the English voice.
  static bool _looksLikeUrdu(String text) {
    for (final rune in text.runes) {
      if ((rune >= 0x0600 && rune <= 0x06FF) ||
          (rune >= 0x0750 && rune <= 0x077F) ||
          (rune >= 0xFB50 && rune <= 0xFDFF) ||
          (rune >= 0xFE70 && rune <= 0xFEFF)) {
        return true;
      }
    }
    return false;
  }

  /// Looks through every voice the engine reports once, and resolves +
  /// caches the best male voice for English and for Urdu. No-ops on every
  /// call after the first (successful or not) so voice enumeration —
  /// which is a bit heavier than the other setup calls — only ever runs
  /// once per app session.
  static Future<void> _prepareVoices(FlutterTts tts) async {
    if (_voicesPrepared) return;
    _voicesPrepared = true;

    List<dynamic>? voices;
    try {
      final raw = await tts.getVoices;
      if (raw is List) voices = raw;
    } catch (_) {
      return; // engine doesn't support voice enumeration — use defaults
    }
    if (voices == null || voices.isEmpty) return;

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

    final all = voices.map(asVoiceMap).whereType<Map<String, String>>().toList();

    _englishVoice = _bestMaleVoiceForLocale(all, 'en');
    // Urdu locale tags vary by engine ('ur', 'ur-PK', 'ur-IN'); matching
    // just the 'ur' prefix catches all of them.
    _urduVoice = _bestMaleVoiceForLocale(all, 'ur');
  }

  /// Scores every voice whose locale starts with [localePrefix] and
  /// returns the best match, preferring (in order): an explicit male-name
  /// match, then a higher-quality "network" voice over a legacy "local"
  /// one, then just the first voice in that language available. Returns
  /// null if no voice for that language exists at all.
  static Map<String, String>? _bestMaleVoiceForLocale(
    List<Map<String, String>> all,
    String localePrefix,
  ) {
    bool matchesAny(String haystack, List<String> hints) =>
        hints.any((hint) => haystack.contains(hint));

    final matching = all
        .where((v) => v['locale']!.toLowerCase().startsWith(localePrefix))
        .toList();
    if (matching.isEmpty) return null;

    // 1. Explicit male match (and not also flagged female).
    for (final v in matching) {
      final key = v['name']!.toLowerCase();
      if (matchesAny(key, _maleHints) && !matchesAny(key, _femaleHints)) {
        return v;
      }
    }

    // 2. No explicit gender tag either way — prefer a higher-quality
    // "network" voice over a "local" one (network voices sound noticeably
    // less robotic), as long as it isn't explicitly flagged female.
    final untaggedNetwork = matching.where((v) {
      final key = v['name']!.toLowerCase();
      return key.contains('network') && !matchesAny(key, _femaleHints);
    });
    if (untaggedNetwork.isNotEmpty) return untaggedNetwork.first;

    // 3. Last resort: any voice in this language not explicitly flagged
    // female — still better than leaving an unpredictable engine default
    // in a mixed voice pack, and keeps offline/local-only voices working.
    final untagged =
        matching.where((v) => !matchesAny(v['name']!.toLowerCase(), _femaleHints));
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
