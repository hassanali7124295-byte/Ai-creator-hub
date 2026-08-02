import 'package:flutter/material.dart';

import '../models/image_generation_models.dart';

/// The Hero tag shared between a gallery card's thumbnail and the
/// matching page in [ImageFullscreenViewer] — kept in one place so both
/// sides always agree on it.
String imageHeroTag(String imageId) => 'generated-image-$imageId';

/// One card in the generated-images gallery: the image itself (tappable
/// to open fullscreen) with a translucent bottom bar exposing all five
/// required actions — Download, Share, Regenerate, Delete, Fullscreen.
/// Fills whatever box its parent (a grid cell) gives it.
class ImageGalleryCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Hero(
              tag: imageHeroTag(image.id),
              child: Image.memory(image.bytes, fit: BoxFit.cover),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.55),
                    ],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CardIcon(
                      icon: Icons.download_rounded,
                      tooltip: 'Download',
                      onTap: onDownload,
                    ),
                    _CardIcon(
                      icon: Icons.ios_share_rounded,
                      tooltip: 'Share',
                      onTap: onShare,
                    ),
                    _CardIcon(
                      icon: Icons.refresh_rounded,
                      tooltip: 'Regenerate',
                      onTap: onRegenerate,
                    ),
                    _CardIcon(
                      icon: Icons.fullscreen_rounded,
                      tooltip: 'Fullscreen',
                      onTap: onOpen,
                    ),
                    _CardIcon(
                      icon: Icons.delete_outline_rounded,
                      tooltip: 'Delete',
                      onTap: onDelete,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small always-white icon button for the card's bottom action bar —
/// 16dp, matching the icon size used for the chat screen's action row.
class _CardIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _CardIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}
