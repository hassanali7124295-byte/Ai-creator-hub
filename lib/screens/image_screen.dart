import 'dart:io';

import 'package:animate_do/animate_do.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../core/services/gemini_image_generation_service.dart';
import '../core/services/image_generation_service.dart';
import '../core/theme/chat_palette.dart';
import '../models/image_generation_models.dart';
import '../widgets/image_fullscreen_viewer.dart';
import '../widgets/image_gallery_card.dart';
import '../widgets/image_shimmer_card.dart';
import '../widgets/image_studio_kit.dart';

/// AI Image Generator screen — prompt, style/aspect-ratio/count/quality
/// controls, a shimmering loading state, and a gallery of generated images
/// with a fullscreen pinch-zoom viewer.
///
/// Step 14.1 is a UI-only pass: the hero header, prompt box, chips,
/// settings card, generate button, loading state, and empty state were all
/// restyled to match the chat screen's premium "Emerald + Graphite"
/// language. Every generation/cancel/download/share/delete method below is
/// unchanged from Step 14 — this screen still talks only to
/// [ImageGenerationService] (see `_service`), so swapping in a real
/// provider later (Gemini Image, OpenAI Images, Stability AI, Fal AI, ...)
/// still means writing one new class and changing the single line that
/// instantiates `_service`; nothing else needs to change.
class ImageScreen extends StatefulWidget {
  const ImageScreen({super.key});

  @override
  State<ImageScreen> createState() => _ImageScreenState();
}

class _ImageScreenState extends State<ImageScreen>
    with SingleTickerProviderStateMixin {
  // Step 14.3: real Gemini image generation. Still the one line to change
  // if a different provider is ever plugged in.
  final ImageGenerationService _service = const GeminiImageGenerationService();

  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _negativeController = TextEditingController();
  final FocusNode _promptFocusNode = FocusNode();
  bool _negativeExpanded = false;
  bool _promptFocused = false;

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

  // Step 14.1: renamed/restyled as small "quick style" prompt chips per the
  // premium suggestion-row spec — same tap-to-fill behavior as Step 14's
  // suggestion chips, just a new label set + an icon per chip.
  static const List<SuggestionItem> _suggestions = [
    SuggestionItem('Realistic', Icons.camera_alt_rounded),
    SuggestionItem('Anime', Icons.emoji_emotions_rounded),
    SuggestionItem('Portrait', Icons.face_rounded),
    SuggestionItem('Logo', Icons.workspace_premium_rounded),
    SuggestionItem('Fantasy', Icons.auto_awesome_rounded),
    SuggestionItem('3D Render', Icons.view_in_ar_rounded),
    SuggestionItem('Cinematic', Icons.movie_creation_rounded),
    SuggestionItem('Wallpaper', Icons.wallpaper_rounded),
    SuggestionItem('Minimal', Icons.crop_square_rounded),
    SuggestionItem('Pixel Art', Icons.grid_view_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _promptFocusNode.addListener(_onFocusChanged);
    // Only drives the suggestion row's "selected" highlight (Step 14.1) —
    // purely cosmetic, no business state depends on this.
    _promptController.addListener(_onPromptChanged);
  }

  void _onFocusChanged() {
    setState(() => _promptFocused = _promptFocusNode.hasFocus);
  }

  void _onPromptChanged() => setState(() {});

  @override
  void dispose() {
    _promptFocusNode.removeListener(_onFocusChanged);
    _promptController.removeListener(_onPromptChanged);
    _promptController.dispose();
    _negativeController.dispose();
    _promptFocusNode.dispose();
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
    } on ImageGenerationException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return null;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong generating your image. Please try again.')),
        );
      }
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
  /// (deliberately not added; new pubspec dependencies aren't allowed),
  /// routing "Download" through the same native share sheet lets the
  /// person pick "Save Image"/"Save to Files" themselves.
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
    // this screen's subtree only (visual-consistency requirement).
    final theme = ChatPalette.themeFor(context);

    return Theme(
      data: theme,
      child: Scaffold(
        // Step 14.1: the large "AI Image Generator" title now lives in the
        // hero header below, so the app bar itself stays quiet — just a
        // transparent back-navigation surface, matching the chat screen's
        // `scrolledUnderElevation: 0` treatment.
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        body: SafeArea(
          top: false,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                sliver: SliverToBoxAdapter(child: _buildHeroHeader(theme)),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
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
                              const SizedBox(height: 16),
                              _buildOptionsCard(theme),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildGenerateButton(theme),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: child,
                        ),
                        child: _isGenerating
                            ? Padding(
                                key: const ValueKey('loading'),
                                padding: const EdgeInsets.only(top: 16),
                                child: _buildLoadingState(theme),
                              )
                            : const SizedBox.shrink(key: ValueKey('idle')),
                      ),
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
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
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
                          duration: const Duration(milliseconds: 280),
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

  /// Hero header (requirement 1): a large title, a short subtitle, and a
  /// soft emerald gradient glyph — the screen's visual anchor, replacing
  /// the old plain app-bar title.
  Widget _buildHeroHeader(ThemeData theme) {
    return FadeInDown(
      duration: const Duration(milliseconds: 420),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  theme.colorScheme.primary,
                  theme.colorScheme.primary.withOpacity(0.65),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: theme.colorScheme.primary.withOpacity(0.28),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
              size: 26,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI Image Generator',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Turn your imagination into stunning AI artwork',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The prompt box (requirement 2): one rounded container with a magic-
  /// wand glyph, a borderless multiline field, and an animated emerald
  /// glow/border/shadow that eases in on focus.
  Widget _buildPromptCard(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _promptFocused
              ? theme.colorScheme.primary.withOpacity(0.55)
              : theme.colorScheme.outlineVariant.withOpacity(0.0),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: (_promptFocused
                    ? theme.colorScheme.primary
                    : theme.colorScheme.shadow)
                .withOpacity(isDark ? 0.05 : (_promptFocused ? 0.16 : 0.06)),
            blurRadius: _promptFocused ? 24 : 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.auto_fix_high_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Describe your image',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _promptController,
            focusNode: _promptFocusNode,
            minLines: 3,
            maxLines: 6,
            style: theme.textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: 'Describe the image you want to create...',
              hintStyle: TextStyle(
                color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
              ),
              border: InputBorder.none,
              isCollapsed: true,
            ),
          ),
          const SizedBox(height: 16),
          _buildSuggestionRow(theme),
          const SizedBox(height: 4),
          _buildNegativePrompt(theme),
        ],
      ),
    );
  }

  /// Suggestion chip row (requirement 3): horizontally scrollable, each
  /// chip carrying its own glyph, with a smooth (no-bounce) selected
  /// animation driven by whether the prompt field currently matches it.
  Widget _buildSuggestionRow(ThemeData theme) {
    final current = _promptController.text.trim().toLowerCase();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: _suggestions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final item = _suggestions[i];
          final selected = current == item.label.toLowerCase();
          return SuggestionChip(
            label: item.label,
            icon: item.icon,
            selected: selected,
            onTap: () => _promptController.text = item.label,
          );
        },
      ),
    );
  }

  Widget _buildNegativePrompt(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
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
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// AI Settings card (requirement 4): the 14-way style choice stays a
  /// scrollable chip row (a segmented control doesn't read well past a
  /// handful of options), while aspect ratio / quality / count — all
  /// small, fixed option sets — become animated segmented controls with a
  /// sliding highlight.
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
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: ImageStyle.values.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final style = ImageStyle.values[i];
                return StyleChip(
                  style: style,
                  selected: style == _style,
                  onTap: () => setState(() => _style = style),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Aspect ratio'),
          const SizedBox(height: 10),
          SegmentedControl<AspectRatioOption>(
            options: AspectRatioOption.values,
            selected: _aspectRatio,
            labelOf: (option) => option.label,
            onSelect: (option) => setState(() => _aspectRatio = option),
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Quality'),
          const SizedBox(height: 10),
          SegmentedControl<ImageQuality>(
            options: ImageQuality.values,
            selected: _quality,
            labelOf: (option) => option.label,
            onSelect: (option) => setState(() => _quality = option),
          ),
          const SizedBox(height: 20),
          _sectionLabel(theme, 'Number of images'),
          const SizedBox(height: 10),
          SegmentedControl<int>(
            options: const [1, 2, 3, 4],
            selected: _count,
            labelOf: (option) => '$option',
            onSelect: (option) => setState(() => _count = option),
          ),
        ],
      ),
    );
  }

  /// Generate button (requirement 5): full-width emerald gradient, a
  /// sparkles glyph that swaps for a spinner while generating, and a
  /// gentle press-scale via [PressableScale].
  Widget _buildGenerateButton(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return PressableScale(
      onTap: _isGenerating ? null : _generate,
      child: Container(
        width: double.infinity,
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary,
              Color.lerp(theme.colorScheme.primary, Colors.black, isDark ? 0.0 : 0.16)!,
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withOpacity(isDark ? 0.20 : 0.32),
              blurRadius: 22,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) => ScaleTransition(
                scale: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: _isGenerating
                  ? const SizedBox(
                      key: ValueKey('spinner'),
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(
                      Icons.auto_awesome_rounded,
                      key: ValueKey('icon'),
                      color: Colors.white,
                      size: 22,
                    ),
            ),
            const SizedBox(width: 12),
            Text(
              _isGenerating ? 'Generating…' : 'Generate',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Loading experience (requirement 6): a gently pulsing AI glyph (no
  /// bounce), "Creating your masterpiece…", the real progress bar, a
  /// Cancel button, and the shimmer grid — all inside one fade-only card.
  Widget _buildLoadingState(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(24),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: theme.colorScheme.shadow.withOpacity(0.05),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PulsingIcon(color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Creating your masterpiece…',
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
          const SizedBox(height: 12),
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

  /// Empty state (requirement 8): large illustration, the required
  /// headline/subtitle copy, and generous premium spacing.
  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeIn(
              duration: const Duration(milliseconds: 420),
              child: Container(
                padding: const EdgeInsets.all(26),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      theme.colorScheme.primary,
                      theme.colorScheme.primary.withOpacity(0.65),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withOpacity(0.24),
                      blurRadius: 28,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 44,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 28),
            FadeInUp(
              duration: const Duration(milliseconds: 420),
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
            const SizedBox(height: 10),
            FadeInUp(
              duration: const Duration(milliseconds: 420),
              delay: const Duration(milliseconds: 130),
              child: Text(
                'Describe anything and let AI transform your imagination into beautiful artwork.',
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

