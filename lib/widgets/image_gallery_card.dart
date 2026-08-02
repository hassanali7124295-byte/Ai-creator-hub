import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/image_generation_models.dart';
import 'image_studio_kit.dart';

/// The Hero tag shared between a gallery card's thumbnail and the
/// matching page in [ImageFullscreenViewer] — kept in one place so both
/// sides always agree on it.
String imageHeroTag(String imageId) => 'generated-image-$imageId';

/// One card in the generated-images gallery (Step 14.1 restyle): large
/// rounded corners, a premium drop shadow, a Hero-animated + fade-in
/// image, and an action bar that stays hidden until the card itself is
/// tapped — matching the chat screen's "tap the AI reply to reveal its
/// actions" pattern instead of showing five icons at all times.
class ImageGalleryCard extends StatefulWidget {
  final GeneratedImage image;
  final VoidCallback onOpen;
  final VoidCallback onDownload;
  final VoidCallback onShare;
  final VoidCallback onRegenerate;
  final VoidCallback onDelete;

  const ImageGalleryCard({
    super.key,
    required this.image,
    required this.onOpen,
    required this.onDownload,
    required this.onShare,
    required this.onRegenerate,
    required this.onDelete,
  });

  @override
  State<ImageGalleryCard> createState() => _ImageGalleryCardState();
}

class _ImageGalleryCardState extends State<ImageGalleryCard> {
  bool _actionsVisible = false;

  void _toggleActions() => setState(() => _actionsVisible = !_actionsVisible);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // Shadow lives on this outer, unclipped Container; the inner
    // ClipRRect only clips the image/ripple content — putting the shadow
    // on a clipped widget would silently cut it off.
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: theme.colorScheme.shadow.withOpacity(0.12),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          child: InkWell(
            onTap: _toggleActions,
            onLongPress: _toggleActions,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Hero(
                  tag: imageHeroTag(widget.image.id),
                  child: _FadeInImage(bytes: widget.image.bytes),
                ),
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 220),
                  opacity: _actionsVisible ? 1 : 0,
                  child: IgnorePointer(
                    ignoring: !_actionsVisible,
                    child: Container(
                      alignment: Alignment.bottomCenter,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withOpacity(0.60),
                          ],
                          stops: const [0.5, 1],
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            GlassIconButton(
                              icon: Icons.download_rounded,
                              tooltip: 'Download',
                              onTap: widget.onDownload,
                            ),
                            GlassIconButton(
                              icon: Icons.ios_share_rounded,
                              tooltip: 'Share',
                              onTap: widget.onShare,
                            ),
                            GlassIconButton(
                              icon: Icons.refresh_rounded,
                              tooltip: 'Regenerate',
                              onTap: widget.onRegenerate,
                            ),
                            GlassIconButton(
                              icon: Icons.fullscreen_rounded,
                              tooltip: 'Fullscreen',
                              onTap: widget.onOpen,
                            ),
                            GlassIconButton(
                              icon: Icons.delete_outline_rounded,
                              tooltip: 'Delete',
                              onTap: widget.onDelete,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades a decoded [Image.memory] in on its first frame instead of
/// popping in instantly — a small touch that matches the "image fade-in"
/// requirement without needing a network image / placeholder loader.
class _FadeInImage extends StatefulWidget {
  final Uint8List bytes;
  const _FadeInImage({required this.bytes});

  @override
  State<_FadeInImage> createState() => _FadeInImageState();
}

class _FadeInImageState extends State<_FadeInImage> {
  double _opacity = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _opacity = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _opacity,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      child: Image.memory(widget.bytes, fit: BoxFit.cover),
    );
  }
}

