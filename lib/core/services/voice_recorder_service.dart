import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// Outcome of [VoiceRecorderService.ensureReady] — mirrors the shape of
/// `VoiceReadyStatus` in `voice_input_service.dart` so the screen can show
/// the same kind of plain-English message before it ever tries to record.
enum VoiceRecorderReadyStatus {
  /// The microphone permission is granted and recording can start.
  ready,

  /// The person denied the microphone permission — recording cannot start
  /// until they allow it (in-app or via device settings).
  permissionDenied,

  /// The device has no usable recording input at all.
  unavailable,
}

/// Step 43 — Proper Voice Message System.
///
/// Thin wrapper around the `record` plugin, purpose-built for the chat
/// composer's mic button: checks/prompts for the mic permission, starts a
/// real audio recording to a fresh temp file, and either keeps that file
/// (`stop`, for the "Done" checkmark) or throws it away (`cancel`, for
/// "Cancel"/discard). Nothing here ever produces text — recognized speech
/// has no part in this class at all, unlike the pre-Step-43
/// `VoiceInputService`.
///
/// One recording is tracked at a time, matching the composer's own
/// IDLE → RECORDING → RECORDED/PREVIEW states — a second `start()` call
/// while already recording is a no-op that returns `false`.
class VoiceRecorderService {
  final AudioRecorder _recorder = AudioRecorder();

  String? _currentPath;
  bool _isRecording = false;

  bool get isRecording => _isRecording;

  /// The temp file path of the in-progress or just-finished recording, if
  /// any — mainly useful for cleanup call sites that don't have the
  /// `stop()`/`cancel()` return value handy.
  String? get currentPath => _currentPath;

  /// Checks (and, on first use, prompts for) the microphone permission.
  /// Deliberately only called right when the person taps the mic — never
  /// on screen load — so the OS permission dialog never appears
  /// unprompted.
  Future<VoiceRecorderReadyStatus> ensureReady() async {
    try {
      final granted = await _recorder.hasPermission();
      return granted
          ? VoiceRecorderReadyStatus.ready
          : VoiceRecorderReadyStatus.permissionDenied;
    } catch (_) {
      return VoiceRecorderReadyStatus.unavailable;
    }
  }

  /// Starts recording real microphone audio to a new temp file. Returns
  /// `false` (with nothing started) if a recording is already in
  /// progress, or if the recorder failed to start for any reason.
  Future<bool> start() async {
    if (_isRecording) return false;
    try {
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/pak_ai_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: path,
      );
      _currentPath = path;
      _isRecording = true;
      return true;
    } catch (_) {
      _isRecording = false;
      _currentPath = null;
      return false;
    }
  }

  /// Stops recording and keeps the resulting file — the "Done" ✓ path.
  /// Returns the final file path (or `null` if nothing was recording, or
  /// the recorder failed to finalize the file).
  Future<String?> stop() async {
    if (!_isRecording) return null;
    try {
      final path = await _recorder.stop();
      _isRecording = false;
      return path ?? _currentPath;
    } catch (_) {
      _isRecording = false;
      return null;
    }
  }

  /// Stops (if still recording) and permanently deletes the temp file —
  /// the "Cancel" path, and also used for cleanup when a recording in
  /// preview is discarded, a send fails, or the screen/conversation is
  /// torn down mid-record. Safe to call even if nothing was recording.
  Future<void> cancel() async {
    try {
      if (_isRecording) {
        // `AudioRecorder.cancel()` stops the active recording *and*
        // deletes the underlying file in one step.
        await _recorder.cancel();
        _isRecording = false;
      } else if (_currentPath != null) {
        await _deleteFile(_currentPath);
      }
    } catch (_) {
      // Best-effort cleanup — never surfaced as an error to the person.
    }
    _currentPath = null;
  }

  /// Deletes an arbitrary recorded file by path — used once a sent voice
  /// message's local temp copy is no longer needed, or to clean up a
  /// stale path recovered after the recorder itself has already reset.
  static Future<void> deleteFile(String? path) => _deleteFile(path);

  static Future<void> _deleteFile(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup — a leftover temp file is not worth surfacing.
    }
  }

  void dispose() {
    _recorder.dispose();
  }
}
