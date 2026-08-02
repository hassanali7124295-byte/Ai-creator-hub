import 'package:flutter/material.dart';

import '../models/image_generation_models.dart';
import 'image_gallery_card.dart' show imageHeroTag;
import 'image_studio_kit.dart';

/// Fullscreen gallery viewer (Step 14.2 restyle): pinch-to-zoom per image
/// via [InteractiveViewer], swiping between images via [PageView] — pushed
/// from [ImageGalleryCard]'s thumbnail and Hero-animated from it.
///
/// Step 14.2 adds the premium "glass" treatment used elsewhere in the
/// Image Generator: a soft top/bottom scrim instead of a flat black
/// [AppBar], a pill-shaped page counter, small swipe-position dots, a
/// prompt caption with style/quality badges, and a frosted bottom action
/// bar built from the same [GlassIconButton] as the gallery card's hover
/// bar. None of the underlying behavior changed — same constructor,
/// same [PageView]/[InteractiveViewer]/[Hero] wiring, same callbacks.
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
    var safeIndex = _index;
    if (safeIndex < 0) safeIndex = 0;
    if (safeIndex > widget.images.length - 1) safeIndex = widget.images.length - 1;
    final current = widget.images[safeIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      extendBody: true,
      body: Stack(
        fit: StackFit.expand,
        children: [
          PageView.builder(
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
          _buildTopBar(context),
          _buildBottomPanel(context, current),
        ],
      ),
    );
  }

  /// A soft top scrim (instead of a flat black AppBar) holding the close
  /// button, a pill-shaped "n / total" counter, and — for multi-image
  /// batches — small position dots that animate the active one wider.
  Widget _buildTopBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black.withOpacity(0.55), Colors.transparent],
            ),
          ),
          child: Row(
            children: [
              GlassIconButton(
                icon: Icons.close_rounded,
                tooltip: 'Close',
                filled: true,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              if (widget.images.length > 1) _buildPageDots(context),
              if (widget.images.length > 1) const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_index + 1} / ${widget.images.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageDots(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.images.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: i == _index ? 16 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(i == _index ? 0.95 : 0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }

  /// A bottom scrim holding the prompt caption + style/quality badges and
  /// the frosted action row — everything needed to identify and act on
  /// the current image without leaving the viewer.
  Widget _buildBottomPanel(BuildContext context, GeneratedImage current) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withOpacity(0.78)],
            stops: const [0, 0.35],
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // AnimatedSwitcher fades the caption in/out as the page
              // changes instead of popping between prompts instantly.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Column(
                  key: ValueKey(current.id),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      current.prompt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _InfoBadge(icon: current.style.glyph, label: current.style.label),
                        const SizedBox(width: 8),
                        _InfoBadge(icon: Icons.high_quality_rounded, label: current.quality.label),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GlassIconButton(
                    icon: Icons.download_rounded,
                    tooltip: 'Download',
                    label: 'Download',
                    onTap: () => widget.onDownload(current),
                  ),
                  GlassIconButton(
                    icon: Icons.ios_share_rounded,
                    tooltip: 'Share',
                    label: 'Share',
                    onTap: () => widget.onShare(current),
                  ),
                  GlassIconButton(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete',
                    label: 'Delete',
                    onTap: () {
                      widget.onDelete(current);
                      Navigator.of(context).maybePop();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tiny glass pill for a style/quality label under the prompt caption.
class _InfoBadge extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoBadge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white70),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
