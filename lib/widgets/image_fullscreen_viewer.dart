import 'package:flutter/material.dart';

import '../models/image_generation_models.dart';
import 'image_gallery_card.dart' show imageHeroTag;

/// Fullscreen gallery viewer (Step 14): dark background, pinch-to-zoom
/// per image via [InteractiveViewer], and swiping between images via
/// [PageView] — pushed from [ImageGalleryCard]'s thumbnail (and Hero-
/// animated from it).
///
/// Deleting closes the viewer and returns to the grid rather than trying
/// to keep the [PageView] in sync with a shrinking list — simpler and
/// more predictable than reflowing the remaining pages in place.
class ImageFullscreenViewer extends StatefulWidget {
  final List<GeneratedImage> images;
  final int initialIndex;
  final ValueChanged<GeneratedImage> onDownload;
  final ValueChanged<GeneratedImage> onShare;
  final ValueChanged<GeneratedImage> onDelete;

  const ImageFullscreenViewer({
    super.key,
    required this.images,
    required this.initialIndex,
    required this.onDownload,
    required this.onShare,
    required this.onDelete,
  });

  @override
  State<ImageFullscreenViewer> createState() => _ImageFullscreenViewerState();
}

class _ImageFullscreenViewerState extends State<ImageFullscreenViewer> {
  late final PageController _pageController =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.images.isEmpty) {
      // Defensive only — the caller always pops on delete before this can
      // be reached with an empty list.
      return const Scaffold(backgroundColor: Colors.black);
    }
    final safeIndex = _index.clamp(0, widget.images.length - 1);
    final current = widget.images[safeIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text('${safeIndex + 1} / ${widget.images.length}'),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final image = widget.images[i];
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: Hero(
                tag: imageHeroTag(image.id),
                child: Image.memory(image.bytes, fit: BoxFit.contain),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ViewerAction(
                icon: Icons.download_rounded,
                label: 'Download',
                onTap: () => widget.onDownload(current),
              ),
              _ViewerAction(
                icon: Icons.ios_share_rounded,
                label: 'Share',
                onTap: () => widget.onShare(current),
              ),
              _ViewerAction(
                icon: Icons.delete_outline_rounded,
                label: 'Delete',
                onTap: () {
                  widget.onDelete(current);
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ViewerAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 4),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
