import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// Step 43 — Proper Voice Message System.
enum VoicePlaybackState { idle, loading, playing, paused, error }

typedef VoicePlaybackListener = void Function(
  VoicePlaybackState state,
  Object? activeId,
  Duration position,
  Duration duration,
);

/// The single owner of the app's voice-message [AudioPlayer] and the
/// single source of truth for "which recorded voice message is playing
/// right now" — mirrors the existing `VoiceManager` (Step 21A, text-to-
/// speech) pattern so the same one-at-a-time guarantee applies here:
///
///  • Only one voice message ever plays. Starting a new one always stops
///    whatever is currently active first (Part 7's requirement).
///  • Tapping the same id again pauses it; tapping it once more resumes
///    from the same position.
///  • Every screen/widget that shows a play button — the in-composer
///    preview and every sent voice-message bubble — talks to
///    `VoicePlaybackManager.instance` instead of owning a player itself,
///    which is what makes the guarantee hold across the whole app, not
///    just within one bubble.
///
/// [Object] ids are used (not `int`) so both a stable per-message index
/// and the composer preview's own fixed id (a plain string) can share the
/// same manager.
class VoicePlaybackManager {
  VoicePlaybackManager._internal() {
    _player.onPositionChanged.listen((p) {
      _position = p;
      _emit();
    });
    _player.onDurationChanged.listen((d) {
      _duration = d;
      _emit();
    });
    _player.onPlayerComplete.listen((_) {
      _state = VoicePlaybackState.idle;
      _position = Duration.zero;
      _emit();
    });
  }

  static final VoicePlaybackManager instance = VoicePlaybackManager._internal();

  final AudioPlayer _player = AudioPlayer();

  VoicePlaybackState _state = VoicePlaybackState.idle;
  Object? _activeId;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// Bumped on every [toggle]/[stop] call so a superseded async step (one
  /// still awaiting `play()`/`pause()` when a newer call already changed
  /// what should be active) can recognize it's stale and give up instead
  /// of clobbering newer state — same guard `VoiceManager` uses.
  int _generation = 0;

  final List<VoicePlaybackListener> _listeners = [];

  VoicePlaybackState get state => _state;
  Object? get activeId => _activeId;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isBusy =>
      _state == VoicePlaybackState.loading || _state == VoicePlaybackState.playing;

  void addListener(VoicePlaybackListener listener) => _listeners.add(listener);

  void removeListener(VoicePlaybackListener listener) =>
      _listeners.remove(listener);

  void _emit() {
    for (final listener in List<VoicePlaybackListener>.of(_listeners)) {
      listener(_state, _activeId, _position, _duration);
    }
  }

  /// Plays [path] for [id]: starts fresh if nothing (or a different
  /// message) is active, pauses if [id] is already playing, resumes if
  /// [id] is already paused.
  Future<void> toggle(Object id, String path) async {
    final myGeneration = ++_generation;

    if (_activeId == id && _state == VoicePlaybackState.playing) {
      await _tryAsync(() => _player.pause());
      if (myGeneration != _generation) return;
      _state = VoicePlaybackState.paused;
      _emit();
      return;
    }

    if (_activeId == id && _state == VoicePlaybackState.paused) {
      await _tryAsync(() => _player.resume());
      if (myGeneration != _generation) return;
      _state = VoicePlaybackState.playing;
      _emit();
      return;
    }

    // A different message (or nothing) was active — stop it first so only
    // one voice message ever plays at once.
    await _tryAsync(() => _player.stop());
    if (myGeneration != _generation) return;

    _activeId = id;
    _position = Duration.zero;
    _duration = Duration.zero;
    _state = VoicePlaybackState.loading;
    _emit();

    try {
      await _player.play(DeviceFileSource(path));
      if (myGeneration != _generation) return;
      _state = VoicePlaybackState.playing;
      _emit();
    } catch (_) {
      if (myGeneration != _generation) return;
      _state = VoicePlaybackState.error;
      _emit();
    }
  }

  /// Stops playback entirely, regardless of which id was active — used
  /// when leaving/switching/clearing a conversation (Part 10) or tearing
  /// down the screen.
  Future<void> stop() async {
    final myGeneration = ++_generation;
    await _tryAsync(() => _player.stop());
    if (myGeneration != _generation) return;
    _state = VoicePlaybackState.idle;
    _activeId = null;
    _position = Duration.zero;
    _emit();
  }

  /// Stops playback only if [id] is the one currently active — used when
  /// a specific voice message is deleted/cancelled so an unrelated one
  /// already playing elsewhere isn't interrupted.
  Future<void> stopIfActive(Object id) async {
    if (_activeId == id) await stop();
  }

  Future<void> _tryAsync(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Best-effort — a failed pause/stop on an already-finished player
      // is not worth surfacing as an error.
    }
  }
}
