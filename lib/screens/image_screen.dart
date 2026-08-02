import 'dart:io';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/services/image_generation_service.dart';
import '../core/services/mock_image_generation_service.dart';
import '../core/theme/chat_palette.dart';
import '../models/image_generation_models.dart';
import '../widgets/image_fullscreen_viewer.dart';
import '../widgets/image_gallery_card.dart';
import '../widgets/image_shimmer_card.dart';

/// AI Image Generator screen (Step 14) — prompt, style/aspect-ratio/
/// count/quality controls, a shimmering loading state, and a gallery of
/// generated images with a fullscreen pinch-zoom viewer.
///
/// Talks only to [ImageGenerationService] — see `_service` below. Swapping
/// in a real provider later (Gemini Image, OpenAI Images, Stability AI,
/// Fal AI, ...) means writing one new class that implements that
/// interface and changing the single line that instantiates `_service`;
/// nothing else on this screen needs to change.
class ImageScreen extends StatefulWidget {
  const ImageScreen({super.key});

  @override
  State<ImageScreen> createState() => _ImageScreenState();
}

class _ImageScreenState extends State<ImageScreen>
    with SingleTickerProviderStateMixin {
  // The one line to change to plug in a real image-generation provider.
  final ImageGenerationService _service = const MockImageGenerationService();

  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _negativeController = TextEditingController();
  bool _negativeExpanded = false;

  ImageStyle _style = ImageStyle.realistic;
  AspectRatioOption _aspectRatio = AspectRatioOption.square;
  int _count = 1;
  ImageQuality _quality = ImageQuality.standard;

  final List<GeneratedImage> _gallery = [];
  bool _isGenerating = false;
  CancellationToken? _cancelToken;

  late final AnimationController _progressController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  static const List<String> _suggestions = [
    'Portrait',
    'Nature',
    'Futuristic City',
    'Robot',
    'Food',
    'Architecture',
    'Space',
    'Fantasy Castle',
    'Cute Animal',
    'Sports Car',
  ];

  @override
  void dispose() {
    _promptController.dispose();
    _negativeController.dispose();
    _progressController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Describe what you want to create first.'),
        ),
      );
      return;
    }
    final request = ImageGenerationRequest(
      prompt: prompt,
      negativePrompt: _negativeController.text.trim().isEmpty
          ? null
          : _negativeController.text.trim(),
      style: _style,
      aspectRatio: _aspectRatio,
      count: _count,
      quality: _quality,
    );
    final results = await _runGeneration(request);
    if (results != null && mounted) {
      setState(() => _gallery.insertAll(0, results));
    }
  }

  Future<void> _regenerate(GeneratedImage image) async {
    if (_isGenerating) return;
    final results = await _runGeneration(image.asRequest);
    if (results == null || !mounted) return;
    setState(() {
      final index = _gallery.indexWhere((g) => g.id == image.id);
      if (index == -1) {
        _gallery.insertAll(0, results);
      } else {
        _gallery.removeAt(index);
        _gallery.insertAll(index, results);
      }
    });
  }

  /// Shared by [_generate] and [_regenerate]: drives the fake progress bar,
  /// races the service call against cancellation, and always resets the
  /// generating flag afterwards. Returns `null` if cancelled or if the
  /// call threw for any other reason (nothing to add to the gallery).
  Future<List<GeneratedImage>?> _runGeneration(
    ImageGenerationRequest request,
  ) async {
    final cancelToken = CancellationToken();
    setState(() {
      _isGenerating = true;
      _cancelToken = cancelToken;
    });
    _progressController
      ..reset()
      ..animateTo(0.92, curve: Curves.easeOut);

    try {
      final results = await _service.generate(request, cancelToken: cancelToken);
      if (!mounted) return null;
      await _progressController.animateTo(
        1,
        duration: const Duration(milliseconds: 200),
      );
      return results;
    } on ImageGenerationCancelledException {
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _cancelToken = null;
        });
        _progressController.reset();
      }
    }
  }

  void _cancelGeneration() => _cancelToken?.cancel();

  void _delete(GeneratedImage image) {
    setState(() => _gallery.removeWhere((g) => g.id == image.id));
  }

  /// Writes the image to a temp file and hands it to the OS share sheet.
  /// Used for both Share and Download — without a gallery-write plugin
  /// (deliberately not added; Step 14 doesn't allow new pubspec
  /// dependencies), routing "Download" through the same native share
  /// sheet lets the person pick "Save Image"/"Save to Files" themselves.
  Future<void> _shareImage(GeneratedImage image, {required String shareText}) async {
    try {
      final file = File('${Directory.systemTemp.path}/ai_creator_hub_${image.id}.png');
      await file.writeAsBytes(image.bytes, flush: true);
      await Share.shareXFiles([XFile(file.path)], text: shareText);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong preparing the image.')),
      );
    }
  }

  void _download(GeneratedImage image) =>
      _shareImage(image, shareText: 'Save this image');

  void _share(GeneratedImage image) =>
      _shareImage(image, shareText: image.prompt);

  void _openFullscreen(int index) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => ImageFullscreenViewer(
          images: _gallery,
          initialIndex: index,
          onDownload: _download,
          onShare: _share,
          onDelete: _delete,
        ),
        transitionsBuilder: (_, animation, __, child) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOut),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Same "Emerald + Graphite" palette as the chat screen, scoped to
    // this screen's subtree only (Step 14 requirement 10).
    final theme = ChatPalette.themeFor(context);

    return Theme(
      data: theme,
      child: Scaffold(
        appBar: AppBar(title: const Text('AI Image Generator')),
        body: SafeArea(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IgnorePointer(
                        ignoring: _isGenerating,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: _isGenerating ? 0.45 : 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildPromptCard(theme),
                              const SizedBox(height: 14),
                              _buildOptionsCard(theme),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildGenerateButton(theme),
                      if (_isGenerating) ...[
                        const SizedBox(height: 14),
                        _buildLoadingState(theme),
                      ],
                    ],
                  ),
                ),
              ),
              if (_gallery.isEmpty && !_isGenerating)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _buildEmptyState(theme),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: _aspectRatio.ratio,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final image = _gallery[index];
                        return FadeIn(
                          duration: const Duration(milliseconds: 260),
                          child: ImageGalleryCard(
                            image: image,
                            onOpen: () => _openFullscreen(index),
                            onDownload: () => _download(image),
                            onShare: () => _share(image),
                            onRegenerate: () => _regenerate(image),
                            onDelete: () => _delete(image),
                          ),
                        );
                      },
                      childCount: _gallery.length,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPromptCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(theme, 'Describe your image'),
          const SizedBox(height: 10),
          TextField(
            controller: _promptController,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'A cozy cabin in a snowy forest at sunset...',
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in _suggestions)
                _SuggestionChip(
                  label: suggestion,
                  onTap: () => setState(() => _promptController.text = suggestion),
                ),
            ],
          ),
          const SizedBox(height: 4),
          _buildNegativePrompt(theme),
        ],
      ),
    );
  }

  Widget _buildNegativePrompt(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _negativeExpanded = !_negativeExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.block_rounded,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  'Negative prompt',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _negativeExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    Icons.expand_more_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topLeft,
          child: !_negativeExpanded
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TextField(
                    controller: _negativeController,
                    minLines: 1,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'blurry, low quality, watermark...',
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildOptionsCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(theme, 'Style'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final style in ImageStyle.values)
                _StyleChip(
                  style: style,
                  selected: style == _style,
                  onTap: () => setState(() => _style = style),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Aspect ratio'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ratio in AspectRatioOption.values)
                _OptionPill(
                  label: ratio.label,
                  selected: ratio == _aspectRatio,
                  onTap: () => setState(() => _aspectRatio = ratio),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Number of images'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final n in const [1, 2, 3, 4])
                _OptionPill(
                  label: '$n',
                  selected: n == _count,
                  onTap: () => setState(() => _count = n),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Quality'),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final quality in ImageQuality.values)
                _OptionPill(
                  label: quality.label,
                  selected: quality == _quality,
                  onTap: () => setState(() => _quality = quality),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGenerateButton(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _isGenerating ? null : _generate,
        style: ElevatedButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: _isGenerating
                  ? const SizedBox(
                      key: ValueKey('spinner'),
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.auto_awesome_rounded,
                      key: ValueKey('icon'),
                    ),
            ),
            const SizedBox(width: 10),
            Text(_isGenerating ? 'Generating…' : 'Generate'),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingState(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _count > 1 ? 'Creating your images…' : 'Creating your image…',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: _cancelGeneration,
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: _progressController,
            builder: (context, _) => ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _progressController.value,
                minHeight: 6,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _count > 1 ? 2 : 1,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: _aspectRatio.ratio,
            ),
            itemCount: _count,
            itemBuilder: (context, index) => const ImageShimmerCard(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeIn(
              duration: const Duration(milliseconds: 400),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.primary.withOpacity(0.65),
                    ],
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FadeInUp(
              duration: const Duration(milliseconds: 400),
              delay: const Duration(milliseconds: 80),
              child: Text(
                'What would you like to create?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FadeInUp(
              duration: const Duration(milliseconds: 400),
              delay: const Duration(milliseconds: 130),
              child: Text(
                'Describe your imagination and let AI bring it to life.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String label) {
    return Text(
      label,
      style: theme.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A small outlined pill used for the suggestion-prompt row — same
/// rounded-outline style as the chat screen's suggestion chips.
class _SuggestionChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SuggestionChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withOpacity(0.7),
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// A style-picker chip: a small gradient swatch (the style's own colors)
/// plus its label, with an animated border/tint when selected.
class _StyleChip extends StatelessWidget {
  final ImageStyle style;
  final bool selected;
  final VoidCallback onTap;

  const _StyleChip({
    required this.style,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: selected
                ? theme.colorScheme.primary.withOpacity(0.14)
                : theme.colorScheme.surfaceContainerHighest,
            border: Border.all(
              color: selected ? theme.colorScheme.primary : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: style.gradient),
                ),
                child: Icon(style.glyph, size: 13, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Text(
                style.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A generic selectable pill for aspect ratio / count / quality — plain
/// text, animated background swap on selection.
class _OptionPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _OptionPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
