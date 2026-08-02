import 'dart:async';

import '../../models/image_generation_models.dart';

/// Thrown by [ImageGenerationService.generate] when a request is stopped
/// early via [CancellationToken.cancel] (the gallery's "Cancel" button).
class ImageGenerationCancelledException implements Exception {
  const ImageGenerationCancelledException();

  @override
  String toString() => 'Image generation was cancelled.';
}

/// A simple cooperative-cancellation handle: the caller holds one, passes
/// it into [ImageGenerationService.generate], and calls [cancel] to ask
/// the in-flight request to stop. Implementations should race their work
/// against [whenCancelled] and throw [ImageGenerationCancelledException]
/// once cancelled.
class CancellationToken {
  bool _cancelled = false;
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Provider-agnostic interface for turning a [ImageGenerationRequest] into
/// a batch of [GeneratedImage]s.
///
/// This is the *only* seam a real backend needs to plug into: swap
/// whichever concrete [ImageGenerationService] the Image screen
/// instantiates (currently a local mock implementation) for one that
/// calls Gemini Image, OpenAI Images, Stability AI, Fal AI, or any future
/// provider — the request/response shapes and every widget in
/// `image_screen.dart` stay exactly the same.
abstract class ImageGenerationService {
  /// Generates [ImageGenerationRequest.count] images. If [cancelToken] is
  /// cancelled before completion, implementations should throw
  /// [ImageGenerationCancelledException] instead of returning a result.
  Future<List<GeneratedImage>> generate(
    ImageGenerationRequest request, {
    CancellationToken? cancelToken,
  });
}
