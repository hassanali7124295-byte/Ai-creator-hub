import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Outcome of [VoiceInputService.ensureReady] — lets the screen show the
/// right message (or none at all) before it ever tries to start listening.
enum VoiceReadyStatus {
  /// Speech recognition is available and the mic permission is granted.
  ready,

  /// The person denied the microphone permission (or it's otherwise not
  /// granted) — recognition cannot start until they allow it.
  permissionDenied,

  /// The device has no speech recognizer available at all (rare, but some
  /// devices/emulators genuinely don't support it).
  unavailable,
}

/// Thin wrapper around the `speech_to_text` plugin, purpose-built for the
/// chat composer's mic button: lazy one-time init, start/stop, and plain-
/// English error messages for every failure mode the plugin can report —
/// so the screen never has to know about `SpeechRecognitionError` codes.
///
/// Language: no picker is shown. Recognition uses the device's own speech
/// locale/engine, which is what lets a single session pick up more than
/// one spoken language (e.g. English and Urdu) automatically when the
/// person has multiple languages enabled in their device's voice/keyboard
/// settings — the same mechanism ChatGPT's mobile app relies on. Passing
/// no `localeId` to `listen()` is what opts into that device behaviour
/// instead of pinning the session to a single fixed language.
class VoiceInputService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _initialized = false;

  void Function(String text, bool isFinal)? _onResult;
  VoidCallback? _onDone;
  void Function(String message)? _onError;

  bool get isListening => _speech.isListening;

  /// Initializes the recognizer the first time it's called (subsequent
  /// calls are free no-ops). This is also what triggers the OS microphone
  /// permission prompt on first use, so it's deliberately only called
  /// right when the person taps the mic — never on screen load.
  Future<VoiceReadyStatus> ensureReady() async {
    if (_initialized) return VoiceReadyStatus.ready;
    var deniedPermission = false;
    try {
      final available = await _speech.initialize(
        onError: (SpeechRecognitionError error) {
          if (error.errorMsg == 'error_permission' ||
              error.errorMsg == 'error_insufficient_permissions') {
            deniedPermission = true;
          }
          _onError?.call(_friendlyMessage(error.errorMsg));
        },
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            _onDone?.call();
          }
        },
      );
      _initialized = available;
      if (available) return VoiceReadyStatus.ready;
      return deniedPermission
          ? VoiceReadyStatus.permissionDenied
          : VoiceReadyStatus.unavailable;
    } catch (_) {
      return VoiceReadyStatus.unavailable;
    }
  }

  /// Starts a continuous listening session. [onResult] fires repeatedly as
  /// words are recognized — `isFinal` is true once the engine has settled
  /// on that chunk of speech, matching how the composer streams live text
  /// into the field without ever sending it. Returns `false` (and reports
  /// through [onError]) if a session couldn't be started at all.
  Future<bool> startListening({
    required void Function(String text, bool isFinal) onResult,
    required VoidCallback onDone,
    required void Function(String message) onError,
  }) async {
    if (!_initialized) {
      onError('Voice input isn\'t ready yet. Please try again.');
      return false;
    }
    if (_speech.isListening) {
      onError('Already listening.');
      return false;
    }

    _onResult = onResult;
    _onDone = onDone;
    _onError = onError;

    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          _onResult?.call(result.recognizedWords, result.finalResult);
        },
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 6),
        // No localeId: let the device's own speech engine and its
        // configured languages decide — see the class doc above.
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: stt.ListenMode.dictation,
        ),
      );
      return true;
    } catch (_) {
      onError('Could not start voice input. Please try again.');
      return false;
    }
  }

  /// Stops listening and finalizes whatever was recognized so far — the
  /// mic-button "tap again to stop" path.
  Future<void> stop() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
  }

  /// Stops listening and discards the in-progress result — used if the
  /// screen is torn down mid-session.
  Future<void> cancel() async {
    if (_speech.isListening) {
      await _speech.cancel();
    }
  }

  String _friendlyMessage(String code) {
    switch (code) {
      case 'error_no_match':
      case 'error_speech_timeout':
        return "Didn't catch that — tap the mic and try again.";
      case 'error_network':
      case 'error_network_timeout':
        return 'No internet connection. Voice input needs network access.';
      case 'error_permission':
      case 'error_insufficient_permissions':
        return 'Microphone access is required for voice input. '
            'Please allow it in your device settings.';
      case 'error_busy':
        return 'Already listening.';
      case 'error_audio_error':
        return 'Could not access the microphone. Please try again.';
      default:
        return 'Voice input ran into a problem. Please try again.';
    }
  }
}
