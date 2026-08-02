import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/image_generation_models.dart';
import 'gemini_service.dart';
import 'image_generation_service.dart';

/// Thrown by [GeminiImageGenerationService.generate] for any real-world
/// failure — bad/missing API key, no internet, timeout, quota exceeded,
/// a safety-blocked prompt, or an empty response. [message] is always
/// short and friendly enough to show directly in a [SnackBar]; callers
/// never need to interpret an HTTP status code themselves.
class ImageGenerationException implements Exception {
  final String message;
  const ImageGenerationException(this.message);

  @override
  String toString() => message;
}

/// Real [ImageGenerationService] backed by Gemini's native image
/// generation (`gemini-3.1-flash-image`, aka "Nano Banana 2") — the
/// current, non-deprecated Gemini model family for text-to-image, reached
/// through the same `generateContent` REST endpoint, the same
/// `x-goog-api-key` header, and the same saved API key as the chat
/// feature's [GeminiService]. There is no separate image API key to
/// configure.
///
/// Style, aspect ratio, and image count all come from the existing
/// [ImageGenerationRequest] fields the screen already builds — nothing
/// about the request/response shape changed from the mock service it
/// replaces, so `image_screen.dart` only had to change the one line that
/// instantiates `_service`.
///
/// Mapping notes:
/// - **Style** has no dedicated API parameter, so it's folded into the
///   prompt as a natural-language instruction ("Create a &lt;style&gt;
///   image. ..."), which is how Google's own prompting guide recommends
///   steering this model.
/// - **Negative prompt** likewise has no dedicated field on this model
///   (unlike some diffusion APIs) — it's appended as an explicit
///   "avoid ..." instruction, which the model reliably follows.
/// - **Aspect ratio** maps directly: [AspectRatioOption.label] already
///   produces strings ("1:1", "16:9", ...) in exactly the format the API
///   expects.
/// - **Quality** maps to the API's `imageSize` tiers: standard → "1K",
///   high → "2K", ultra → "4K".
/// - **Count** issues one `generateContent` call per requested image
///   (same loop shape as the mock service it replaces), so cancellation
///   can be checked between images and a partial batch never silently
///   returns fewer images than asked for without cancellation involved.
class GeminiImageGenerationService implements ImageGenerationService {
  const GeminiImageGenerationService();

  static const String _model = 'gemini-3.1-flash-image';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1/models';

  @override
  Future<List<GeneratedImage>> generate(
    ImageGenerationRequest request, {
    CancellationToken? cancelToken,
  }) async {
    final apiKey = await GeminiService.getApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw const ImageGenerationException(
        'No Gemini API key configured yet. Add one in Settings → Gemini API Key.',
      );
    }
    final trimmedKey = apiKey.trim();

    final images = <GeneratedImage>[];
    for (var i = 0; i < request.count; i++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const ImageGenerationCancelledException();
      }

      final bytes = await _generateOne(
        request: request,
        apiKey: trimmedKey,
        cancelToken: cancelToken,
      );

      // The response may have landed right as Cancel was pressed — per
      // the cancellation requirement, ignore it rather than adding a
      // straggler image to the gallery.
      if (cancelToken?.isCancelled ?? false) {
        throw const ImageGenerationCancelledException();
      }

      images.add(
        GeneratedImage(
          id: '${DateTime.now().microsecondsSinceEpoch}_$i',
          bytes: bytes,
          prompt: request.prompt,
          negativePrompt: request.negativePrompt,
          style: request.style,
          aspectRatio: request.aspectRatio,
          quality: request.quality,
          createdAt: DateTime.now(),
        ),
      );
    }
    return images;
  }

  /// Issues one `generateContent` call and returns the decoded PNG/JPEG
  /// bytes of the resulting image.
  Future<Uint8List> _generateOne({
    required ImageGenerationRequest request,
    required String apiKey,
    CancellationToken? cancelToken,
  }) async {
    final uri = Uri.parse('$_baseUrl/$_model:generateContent');

    final body = jsonEncode({
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': _buildPrompt(request)},
          ],
        },
      ],
      'generationConfig': {
        'responseModalities': ['TEXT', 'IMAGE'],
        'responseFormat': {
          'image': {
            'aspectRatio': request.aspectRatio.label,
            'imageSize': _imageSizeFor(request.quality),
          },
        },
      },
    });

    // The `http` package has no built-in request cancellation, so the
    // network call and the cancellation signal race via this Completer:
    // whichever finishes first wins, and (per the cancellation
    // requirement) a Gemini response that arrives after cancellation is
    // simply never awaited any further.
    final completer = Completer<http.Response>();

    unawaited(
      http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            body: body,
          )
          .timeout(const Duration(seconds: 60))
          .then((response) {
        if (!completer.isCompleted) completer.complete(response);
      }).catchError((Object error, StackTrace stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }),
    );

    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancelled.then((_) {
          if (!completer.isCompleted) {
            completer.completeError(const ImageGenerationCancelledException());
          }
        }),
      );
    }

    late final http.Response response;
    try {
      response = await completer.future;
    } on ImageGenerationCancelledException {
      rethrow;
    } on TimeoutException {
      throw const ImageGenerationException(
        'The request timed out. Check your connection and try again.',
      );
    } on SocketException {
      throw const ImageGenerationException(
        'No internet connection. Check your network and try again.',
      );
    } catch (e) {
      throw ImageGenerationException('Could not reach Gemini: $e');
    }

    return _parseImageBytes(response);
  }

  /// Folds style and the (API-side-unsupported) negative prompt into the
  /// user's prompt as natural-language instructions — the officially
  /// recommended way to steer this model, since neither has a dedicated
  /// request field the way some diffusion APIs offer.
  String _buildPrompt(ImageGenerationRequest request) {
    final buffer = StringBuffer()
      ..write('Create a ${request.style.label.toLowerCase()}-style image. ')
      ..write(request.prompt.trim());

    final negative = request.negativePrompt?.trim();
    if (negative != null && negative.isNotEmpty) {
      buffer.write(' Avoid including or depicting: $negative.');
    }
    return buffer.toString();
  }

  String _imageSizeFor(ImageQuality quality) => switch (quality) {
        ImageQuality.standard => '1K',
        ImageQuality.high => '2K',
        ImageQuality.ultra => '4K',
      };

  /// Walks the response for the friendly-error cases (bad key, quota,
  /// safety block, empty result) before falling back to decoding the
  /// first inline image part.
  Uint8List _parseImageBytes(http.Response response) {
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const ImageGenerationException(
        'Your Gemini API key looks invalid or unauthorized. Double-check it in Settings.',
      );
    }
    if (response.statusCode == 429) {
      throw const ImageGenerationException(
        'You\'ve hit the Gemini image generation quota. Please try again later.',
      );
    }
    if (response.statusCode == 400) {
      throw const ImageGenerationException(
        'Gemini rejected this request. Try adjusting your prompt or settings.',
      );
    }
    if (response.statusCode != 200) {
      throw ImageGenerationException(
        'Gemini API error (${response.statusCode}). Please try again.',
      );
    }

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw const ImageGenerationException(
        'Gemini returned an unexpected response. Please try again.',
      );
    }

    final promptFeedback = decoded['promptFeedback'] as Map<String, dynamic>?;
    if (promptFeedback != null && promptFeedback['blockReason'] != null) {
      throw const ImageGenerationException(
        'That prompt was blocked by safety filters. Try rephrasing your description.',
      );
    }

    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw const ImageGenerationException(
        'Gemini returned no image. Try a different prompt.',
      );
    }

    final candidate = candidates[0] as Map<String, dynamic>;
    final finishReason = candidate['finishReason'] as String?;
    if (finishReason == 'SAFETY' ||
        finishReason == 'PROHIBITED_CONTENT' ||
        finishReason == 'BLOCKLIST') {
      throw const ImageGenerationException(
        'That prompt was blocked by safety filters. Try rephrasing your description.',
      );
    }

    final content = candidate['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw const ImageGenerationException('Gemini returned an empty response.');
    }

    for (final rawPart in parts) {
      final part = rawPart as Map<String, dynamic>;
      final inline = (part['inline_data'] ?? part['inlineData']) as Map<String, dynamic>?;
      if (inline == null) continue;
      final data = inline['data'] as String?;
      if (data != null && data.isNotEmpty) {
        return base64Decode(data);
      }
    }

    throw const ImageGenerationException(
      'Gemini did not return an image for this prompt. Try a different description.',
    );
  }
}
