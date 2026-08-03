import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/image_generation_models.dart';
import 'image_generation_service.dart';

/// Real [ImageGenerationService] backed by Pollinations AI's `flux` image
/// model, reached through its key-less `GET /prompt/{prompt}` endpoint
/// (`https://image.pollinations.ai/prompt/{prompt}`). Step 15 replacement
/// for [GeminiImageGenerationService] — no billing or quota is required, so
/// it works even though the project's Gemini API key has no
/// image-generation quota available.
///
/// **Step 15.1 fix**: this previously pointed at
/// `https://gen.pollinations.ai/image/{prompt}` — Pollinations' newer
/// *unified* gateway. That host now requires an `Authorization: Bearer`
/// API key for every request (see the "Authentication & Rate Limits"
/// section of the official docs); with no key attached, every call came
/// back `401 Unauthorized` and no image was ever generated. The original
/// `image.pollinations.ai/prompt/{prompt}` host is still documented,
/// still key-less, and still live, so [generate] now targets that host
/// again — restoring the "no billing or quota required" behavior this
/// service was built for.
///
/// This is a drop-in swap: it implements the same [ImageGenerationService]
/// contract, throws the same [ImageGenerationException] /
/// [ImageGenerationCancelledException] types, and reads/returns the same
/// [ImageGenerationRequest] / [GeneratedImage] models the mock and Gemini
/// services used — so `image_screen.dart` only changes the one line that
/// instantiates `_service`.
///
/// Mapping notes:
/// - **Style** and **negative prompt** have no dedicated Pollinations
///   parameter (this endpoint takes a single free-text prompt), so both
///   are folded into the prompt as natural-language instructions, exactly
///   like the Gemini service did.
/// - **Aspect ratio + quality** map together to pixel `width`/`height`
///   query params via the existing [AspectRatioOptionX.pixelSize] /
///   [ImageQualityX.baseLongEdge] helpers already used for the on-screen
///   preview — no new sizing logic needed.
/// - **Count**: Pollinations' `GET /prompt/{prompt}` returns exactly one
///   image per request, so [generate] issues one HTTP call per requested
///   image (same sequential-loop shape the Gemini service used), checking
///   cancellation between each.
/// - **Model**: `flux` — Pollinations' free, unlimited, key-less image
///   model (per the official API docs at
///   https://github.com/pollinations/pollinations/blob/main/APIDOCS.md).
/// - **Seed**: the docs define `seed` as an integer whose *default*
///   (when the param is omitted) is a random value — there is no documented
///   "-1 means random" convention, so a literal `-1` is just the seed
///   `-1` and would return the same image every call. [generate] now
///   generates a real random non-negative seed client-side per request
///   instead.
class PollinationsImageGenerationService implements ImageGenerationService {
  const PollinationsImageGenerationService();

  static const String _model = 'flux';
  static const String _host = 'image.pollinations.ai';

  @override
  Future<List<GeneratedImage>> generate(
    ImageGenerationRequest request, {
    CancellationToken? cancelToken,
  }) async {
    final images = <GeneratedImage>[];
    for (var i = 0; i < request.count; i++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const ImageGenerationCancelledException();
      }

      final bytes = await _generateOne(request: request, cancelToken: cancelToken);

      // The response may have landed right as Cancel was pressed — ignore
      // it rather than adding a straggler image to the gallery.
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

  /// Issues one `GET /prompt/{prompt}` call and returns the raw JPEG/PNG
  /// bytes Pollinations sends back directly as the response body.
  Future<Uint8List> _generateOne({
    required ImageGenerationRequest request,
    CancellationToken? cancelToken,
  }) async {
    final (width, height) =
        request.aspectRatio.pixelSize(request.quality.baseLongEdge);

    final uri = Uri.https(_host, '/prompt/${_buildPrompt(request)}', {
      'model': _model,
      'width': '$width',
      'height': '$height',
      // A fresh random seed per call (rather than a fixed/magic value)
      // ensures requesting several images for the same prompt (Task 6)
      // doesn't just replay one cached result.
      'seed': '${_randomSeed()}',
    });

    // ---- Step 15.1 debug logging: final outgoing request URL ----
    // ignore: avoid_print
    print('[Pollinations] GET $uri');

    // http has no built-in request cancellation, so the network call and
    // the cancellation signal race via this Completer: whichever finishes
    // first wins, and a response that arrives after cancellation is never
    // awaited any further.
    final completer = Completer<http.Response>();

    unawaited(
      http.get(uri).timeout(const Duration(seconds: 60)).then((response) {
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
      throw ImageGenerationException('Could not reach Pollinations: $e');
    }

    return _parseImageBytes(response);
  }

  static final Random _rng = Random();

  /// A fresh non-negative random seed for the `seed` query param. The
  /// docs define `seed` as a plain integer (default: random-if-omitted) —
  /// there's no "-1 means randomize" sentinel, so a real random value is
  /// generated here instead of relying on a magic constant.
  int _randomSeed() => _rng.nextInt(1 << 31);

  /// Folds style and negative prompt into the user's prompt as
  /// natural-language instructions (Pollinations has no dedicated field
  /// for either). Returns raw, un-encoded text — [Uri.https] percent-encodes
  /// its `unencodedPath` argument itself, so encoding it again here would
  /// double-encode the prompt (e.g. a space would become `%2520`).
  String _buildPrompt(ImageGenerationRequest request) {
    final buffer = StringBuffer()
      ..write('${request.style.label} style image. ')
      ..write(request.prompt.trim());

    final negative = request.negativePrompt?.trim();
    if (negative != null && negative.isNotEmpty) {
      buffer.write(' Avoid including or depicting: $negative.');
    }
    return buffer.toString();
  }

  /// Maps the HTTP response to either the decoded image bytes or an
  /// [ImageGenerationException] carrying the *exact* server response
  /// (Task 5) — never a generic "try again" message — so a runtime
  /// failure that only shows up on-device is diagnosable straight from
  /// the thrown message.
  ///
  /// **Step 15.2 audit** (still holds): [http.Response.bodyBytes] (raw
  /// `Uint8List`), never `.body`, is what's returned as image data; no
  /// JSON parsing happens on the image-success path; both `image/jpeg`
  /// and `image/png` are accepted via a generic `image/` prefix check.
  Uint8List _parseImageBytes(http.Response response) {
    final contentType = response.headers['content-type'] ?? '(none)';
    final contentLength = response.headers['content-length'] ?? '(none)';
    final bytes = response.bodyBytes;
    final isImage = contentType.startsWith('image/');

    // ---- Step 15.3 debug logging ----
    // ignore: avoid_print
    print('[Pollinations] status=${response.statusCode} '
        'content-type=$contentType content-length=$contentLength '
        'bodyBytes.length=${bytes.length}');

    if (isImage) {
      // ignore: avoid_print
      print('[Pollinations] first32Bytes=${_hexPreview(bytes, 32)}');
      // ignore: avoid_print
      print('[Pollinations] signature=${_signatureOf(bytes)}');
    } else {
      // Content-Type says this ISN'T an image — dump the entire body,
      // not a snippet, so whatever the server actually said (HTML error
      // page, JSON error, plain text, empty string, ...) is fully visible.
      // ignore: avoid_print
      print('[Pollinations] FULL body (${response.body.length} chars): '
          '${response.body}');
    }

    // Every failure path below includes the exact status, Content-Type,
    // and (for non-image responses) body text the server actually sent —
    // no generic "please try again" placeholders.
    if (response.statusCode == 200 && isImage) {
      if (bytes.isNotEmpty) return bytes;
      throw ImageGenerationException(
        'Pollinations returned HTTP 200 with Content-Type: $contentType '
        'but an EMPTY body (bodyBytes.length=0, Content-Length header: '
        '$contentLength).',
      );
    }

    throw ImageGenerationException(
      'Pollinations request failed — '
      'HTTP ${response.statusCode}, Content-Type: $contentType, '
      'Content-Length: $contentLength, bodyBytes.length=${bytes.length}. '
      'Server response: ${isImage ? '<${bytes.length} bytes of $contentType data, not returned as an image — see signature=${_signatureOf(bytes)}>' : (response.body.isEmpty ? '(empty body)' : response.body)}',
    );
  }

  /// Renders up to [count] bytes of [bytes] as space-separated hex pairs
  /// (e.g. `ff d8 ff e0 00 00 ...`) for the debug log — lets you eyeball
  /// the real JPEG/PNG magic-number header and confirm the bytes Flutter
  /// received are an actual image and not e.g. `3c 68 74 6d 6c` (`<html`)
  /// or `7b 22 65 72` (`{"er`, a JSON error body).
  String _hexPreview(Uint8List bytes, int count) {
    final preview = bytes.take(count);
    return preview
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }

  /// Checks the leading magic-number bytes against the documented JPEG
  /// and PNG signatures and reports what was actually found, so a
  /// mismatched/truncated/corrupted payload is obvious in the log even
  /// when the HTTP status and Content-Type both looked fine.
  String _signatureOf(Uint8List bytes) {
    const jpeg = [0xFF, 0xD8, 0xFF];
    const png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    bool matches(List<int> magic) =>
        bytes.length >= magic.length &&
        List.generate(magic.length, (i) => bytes[i] == magic[i])
            .every((ok) => ok);
    if (matches(jpeg)) return 'JPEG (ff d8 ff)';
    if (matches(png)) return 'PNG (89 50 4e 47 0d 0a 1a 0a)';
    return 'UNRECOGNIZED (no JPEG/PNG signature match — '
        'got ${_hexPreview(bytes, 8)})';
  }

  /// Pulls `error.message` out of Pollinations' documented JSON error
  /// shape (`{"status", "success", "error": {"code", "message", ...}}`)
  /// so a failure shows the real, specific reason instead of a made-up
  /// generic string. Falls back to the raw body if the JSON doesn't match
  /// that shape, and never throws — this is purely a best-effort helper.
  ///
  /// **Step 15.3**: no longer called — [_parseImageBytes] now embeds the
  /// server's exact response text directly in every thrown exception
  /// (Task 5) instead of extracting/reformatting just an `error.message`
  /// field, so this JSON-shape-specific extraction is redundant. Left
  /// unused-but-intact rather than deleted, since removing it would be a
  /// larger diff than this debugging pass calls for.
  // ignore: unused_element
  String _extractApiErrorMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) return message;
        }
      }
    } catch (_) {
      // Not JSON, or not the expected shape — fall through to raw body.
    }
    return body.isNotEmpty ? body : 'No error details were returned.';
  }
}
