import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../models/image_generation_models.dart';
import 'image_generation_service.dart';

/// Fake [ImageGenerationService] for Step 14: no network call, no real
/// model. It waits a realistic 2–3s (racing the [CancellationToken] the
/// caller can cancel with), then renders one small offline placeholder
/// "image" per requested count — a gradient in the chosen [ImageStyle]'s
/// colors with its glyph centered — using only `dart:ui`, so no new
/// package is needed just to demo the gallery/viewer UI.
///
/// Swapping this out for a real provider later means writing a new class
/// that implements [ImageGenerationService] and changing the one line in
/// `image_screen.dart` that instantiates it — nothing else in the feature
/// needs to change.
class MockImageGenerationService implements ImageGenerationService {
  const MockImageGenerationService();

  @override
  Future<List<GeneratedImage>> generate(
    ImageGenerationRequest request, {
    CancellationToken? cancelToken,
  }) async {
    final delayMs = 2000 + Random().nextInt(1000); // 2.0–3.0s, like a real call
    final delay = Future<void>.delayed(Duration(milliseconds: delayMs));

    if (cancelToken != null) {
      await Future.any<void>([delay, cancelToken.whenCancelled]);
      if (cancelToken.isCancelled) {
        throw const ImageGenerationCancelledException();
      }
    } else {
      await delay;
    }

    final images = <GeneratedImage>[];
    for (var i = 0; i < request.count; i++) {
      if (cancelToken?.isCancelled ?? false) {
        throw const ImageGenerationCancelledException();
      }
      final bytes = await _renderPlaceholder(request: request, seed: i);
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

  /// Draws a small PNG offline: a diagonal gradient in the style's colors,
  /// two soft translucent blobs (position seeded per-image so a batch
  /// looks like distinct variations rather than identical copies), the
  /// style's glyph centered, and the style name along the bottom.
  Future<Uint8List> _renderPlaceholder({
    required ImageGenerationRequest request,
    required int seed,
  }) async {
    final (widthInt, heightInt) =
        request.aspectRatio.pixelSize(request.quality.baseLongEdge);
    final width = widthInt.toDouble();
    final height = heightInt.toDouble();
    final rng = Random(seed + request.style.index * 97);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
    final rect = Rect.fromLTWH(0, 0, width, height);

    final colors = request.style.gradient;
    final gradientPaint = Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, 0),
        Offset(width, height),
        colors,
      );
    canvas.drawRect(rect, gradientPaint);

    final blobA = Paint()..color = Colors.white.withOpacity(0.10);
    canvas.drawCircle(
      Offset(width * (0.65 + rng.nextDouble() * 0.2),
          height * (0.15 + rng.nextDouble() * 0.15)),
      width * 0.30,
      blobA,
    );
    final blobB = Paint()..color = Colors.black.withOpacity(0.08);
    canvas.drawCircle(
      Offset(width * (0.10 + rng.nextDouble() * 0.15),
          height * (0.75 + rng.nextDouble() * 0.15)),
      width * 0.24,
      blobB,
    );

    final glyph = request.style.glyph;
    final glyphPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(glyph.codePoint),
        style: TextStyle(
          fontFamily: glyph.fontFamily,
          package: glyph.fontPackage,
          fontSize: width * 0.30,
          color: Colors.white.withOpacity(0.92),
        ),
      ),
    )..layout();
    glyphPainter.paint(
      canvas,
      Offset(
        (width - glyphPainter.width) / 2,
        (height - glyphPainter.height) / 2 - height * 0.03,
      ),
    );

    final labelPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      text: TextSpan(
        text: request.style.label.toUpperCase(),
        style: TextStyle(
          fontSize: width * 0.042,
          fontWeight: FontWeight.w700,
          letterSpacing: width * 0.003,
          color: Colors.white.withOpacity(0.85),
        ),
      ),
    )..layout(maxWidth: width * 0.8);
    labelPainter.paint(
      canvas,
      Offset((width - labelPainter.width) / 2, height * 0.84),
    );

    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(widthInt, heightInt);
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    uiImage.dispose();
    return byteData!.buffer.asUint8List();
  }
}
