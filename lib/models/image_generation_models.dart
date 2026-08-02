import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Visual style applied to a generated image (Step 14).
///
/// Purely a UI/request concern — the mock service uses [icon]/[gradient]
/// below to draw a representative placeholder; a real provider would map
/// each value to whatever style parameter/prompt-prefix it expects.
enum ImageStyle {
  realistic,
  anime,
  pixar,
  threeD,
  cartoon,
  watercolor,
  oilPainting,
  sketch,
  cyberpunk,
  fantasy,
  minimal,
  logo,
  icon,
  sticker,
}

extension ImageStyleX on ImageStyle {
  String get label => switch (this) {
        ImageStyle.realistic => 'Realistic',
        ImageStyle.anime => 'Anime',
        ImageStyle.pixar => 'Pixar',
        ImageStyle.threeD => '3D',
        ImageStyle.cartoon => 'Cartoon',
        ImageStyle.watercolor => 'Watercolor',
        ImageStyle.oilPainting => 'Oil Painting',
        ImageStyle.sketch => 'Sketch',
        ImageStyle.cyberpunk => 'Cyberpunk',
        ImageStyle.fantasy => 'Fantasy',
        ImageStyle.minimal => 'Minimal',
        ImageStyle.logo => 'Logo',
        ImageStyle.icon => 'Icon',
        ImageStyle.sticker => 'Sticker',
      };

  /// A representative glyph — used both in the style-picker chip and
  /// drawn onto the mock service's placeholder image.
  IconData get glyph => switch (this) {
        ImageStyle.realistic => Icons.camera_alt_rounded,
        ImageStyle.anime => Icons.emoji_emotions_rounded,
        ImageStyle.pixar => Icons.theater_comedy_rounded,
        ImageStyle.threeD => Icons.view_in_ar_rounded,
        ImageStyle.cartoon => Icons.brush_rounded,
        ImageStyle.watercolor => Icons.water_drop_rounded,
        ImageStyle.oilPainting => Icons.palette_rounded,
        ImageStyle.sketch => Icons.edit_rounded,
        ImageStyle.cyberpunk => Icons.bolt_rounded,
        ImageStyle.fantasy => Icons.auto_awesome_rounded,
        ImageStyle.minimal => Icons.crop_square_rounded,
        ImageStyle.logo => Icons.workspace_premium_rounded,
        ImageStyle.icon => Icons.grid_view_rounded,
        ImageStyle.sticker => Icons.star_rounded,
      };

  /// Two-color gradient used for both the chip's selected state and the
  /// mock placeholder's background — deliberately distinct per style so a
  /// gallery of mixed styles reads as visually varied.
  List<Color> get gradient => switch (this) {
        ImageStyle.realistic => const [Color(0xFF4B6CB7), Color(0xFF182848)],
        ImageStyle.anime => const [Color(0xFFFF6FD8), Color(0xFF3813C2)],
        ImageStyle.pixar => const [Color(0xFFFFB75E), Color(0xFFED8F03)],
        ImageStyle.threeD => const [Color(0xFF00C6FF), Color(0xFF0072FF)],
        ImageStyle.cartoon => const [Color(0xFFFFD93D), Color(0xFFFF6B6B)],
        ImageStyle.watercolor => const [Color(0xFF89F7FE), Color(0xFF66A6FF)],
        ImageStyle.oilPainting => const [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
        ImageStyle.sketch => const [Color(0xFF757F9A), Color(0xFFD7DDE8)],
        ImageStyle.cyberpunk => const [Color(0xFFFF00CC), Color(0xFF333399)],
        ImageStyle.fantasy => const [Color(0xFF6A11CB), Color(0xFF2575FC)],
        ImageStyle.minimal => const [Color(0xFFE0E0E0), Color(0xFFB0BEC5)],
        ImageStyle.logo => const [Color(0xFF11998E), Color(0xFF38EF7D)],
        ImageStyle.icon => const [Color(0xFF10B981), Color(0xFF34D399)],
        ImageStyle.sticker => const [Color(0xFFFFAFBD), Color(0xFFFFC3A0)],
      };
}

/// Output aspect ratio for a generation request.
enum AspectRatioOption { square, portrait3x4, landscape4x3, portrait9x16, landscape16x9 }

extension AspectRatioOptionX on AspectRatioOption {
  String get label => switch (this) {
        AspectRatioOption.square => '1:1',
        AspectRatioOption.portrait3x4 => '3:4',
        AspectRatioOption.landscape4x3 => '4:3',
        AspectRatioOption.portrait9x16 => '9:16',
        AspectRatioOption.landscape16x9 => '16:9',
      };

  int get widthPart => switch (this) {
        AspectRatioOption.square => 1,
        AspectRatioOption.portrait3x4 => 3,
        AspectRatioOption.landscape4x3 => 4,
        AspectRatioOption.portrait9x16 => 9,
        AspectRatioOption.landscape16x9 => 16,
      };

  int get heightPart => switch (this) {
        AspectRatioOption.square => 1,
        AspectRatioOption.portrait3x4 => 4,
        AspectRatioOption.landscape4x3 => 3,
        AspectRatioOption.portrait9x16 => 16,
        AspectRatioOption.landscape16x9 => 9,
      };

  /// width / height — used for the on-screen preview card's aspect ratio.
  double get ratio => widthPart / heightPart;

  /// Pixel dimensions for a render whose longer edge is [longEdge].
  (int width, int height) pixelSize(int longEdge) {
    if (widthPart >= heightPart) {
      final w = longEdge;
      final h = (longEdge * heightPart / widthPart).round();
      return (w, h);
    }
    final h = longEdge;
    final w = (longEdge * widthPart / heightPart).round();
    return (w, h);
  }
}

/// Output quality tier — for the mock service this only changes the
/// rendered resolution; a real provider would map it to its own
/// quality/step-count parameter.
enum ImageQuality { standard, high, ultra }

extension ImageQualityX on ImageQuality {
  String get label => switch (this) {
        ImageQuality.standard => 'Standard',
        ImageQuality.high => 'High',
        ImageQuality.ultra => 'Ultra HD',
      };

  int get baseLongEdge => switch (this) {
        ImageQuality.standard => 640,
        ImageQuality.high => 896,
        ImageQuality.ultra => 1152,
      };
}

/// Everything needed to ask [ImageGenerationService] for one batch of
/// images. Provider-agnostic on purpose — a real implementation reads the
/// same fields and maps them to whatever its API expects.
class ImageGenerationRequest {
  final String prompt;
  final String? negativePrompt;
  final ImageStyle style;
  final AspectRatioOption aspectRatio;
  final int count;
  final ImageQuality quality;

  const ImageGenerationRequest({
    required this.prompt,
    this.negativePrompt,
    required this.style,
    required this.aspectRatio,
    required this.count,
    required this.quality,
  });
}

/// One generated image plus the request settings that produced it — kept
/// together so the gallery card and fullscreen viewer can show/re-use them
/// (e.g. "Regenerate" re-issues the same request).
class GeneratedImage {
  final String id;
  final Uint8List bytes;
  final String prompt;
  final String? negativePrompt;
  final ImageStyle style;
  final AspectRatioOption aspectRatio;
  final ImageQuality quality;
  final DateTime createdAt;

  const GeneratedImage({
    required this.id,
    required this.bytes,
    required this.prompt,
    this.negativePrompt,
    required this.style,
    required this.aspectRatio,
    required this.quality,
    required this.createdAt,
  });

  ImageGenerationRequest get asRequest => ImageGenerationRequest(
        prompt: prompt,
        negativePrompt: negativePrompt,
        style: style,
        aspectRatio: aspectRatio,
        count: 1,
        quality: quality,
      );
}
