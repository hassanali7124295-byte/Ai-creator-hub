import 'package:flutter/material.dart';

import '../models/image_generation_models.dart';

/// Shared, presentation-only building blocks for the Image Generator
/// screens (Step 14.2). Extracted out of `image_screen.dart`,
/// `image_gallery_card.dart`, and `image_fullscreen_viewer.dart` so the
/// same premium controls — and their exact animation curves/durations —
/// are defined once instead of three slightly-different times.
///
/// Nothing in this file talks to a service, model class beyond the plain
/// data in [ImageStyle]/etc., or persistence layer — it's pure UI.

/// A gentle, non-bouncy press-scale wrapper used by the Generate button
/// and (Step 14.2) also available anywhere else a "premium tap" feel is
/// wanted, instead of every screen re-implementing its own
/// GestureDetector + AnimatedScale.
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const PressableScale({super.key, required this.child, required this.onTap});

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (widget.onTap == null) return;
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapCancel: () => _setPressed(false),
      onTapUp: (_) => _setPressed(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A reusable animated segmented control — one sliding-highlight bar in
/// place of a row of always-visible option pills. Used for aspect ratio,
/// quality, and image-count on the main screen.
class SegmentedControl<T> extends StatelessWidget {
  final List<T> options;
  final T selected;
  final String Function(T option) labelOf;
  final ValueChanged<T> onSelect;

  const SegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var index = options.indexOf(selected);
    if (index < 0) index = 0;
    if (index > options.length - 1) index = options.length - 1;

    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / options.length;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                left: segmentWidth * index,
                width: segmentWidth,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final option in options)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelect(option),
                        child: Center(
                          child: Text(
                            labelOf(option),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: option == selected
                                  ? theme.colorScheme.onPrimary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A softly "breathing" AI glyph for loading states — scale + opacity
/// ease in and out on a slow loop. No bounce/overshoot, matching the
/// chat screen's typing-indicator philosophy.
class PulsingIcon extends StatefulWidget {
  final Color color;
  const PulsingIcon({super.key, required this.color});

  @override
  State<PulsingIcon> createState() => _PulsingIconState();
}

class _PulsingIconState extends State<PulsingIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.scale(
          scale: 0.92 + t * 0.16,
          child: Opacity(opacity: 0.75 + t * 0.25, child: child),
        );
      },
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withOpacity(0.15),
        ),
        child: Icon(Icons.auto_awesome_rounded, color: widget.color, size: 18),
      ),
    );
  }
}

/// A small icon button for use over an image (gallery card hover bar,
/// fullscreen viewer bottom bar) — always white so it reads on photos of
/// any color, optionally with a caption label and/or a translucent
/// "glass" backdrop circle/pill. One definition replaces what used to be
/// two near-identical private widgets (`_CardIcon` and `_ViewerAction`).
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? label;
  final double iconSize;
  final bool filled;

  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.iconSize = 16,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasLabel = label != null;
    final shape = hasLabel
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
        : const CircleBorder();

    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ? Colors.white.withOpacity(0.14) : Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(hasLabel ? 12 : 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: iconSize, color: Colors.white),
                if (hasLabel) ...[
                  const SizedBox(height: 4),
                  Text(
                    label!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A style-picker chip: a small gradient swatch (the style's own colors)
/// plus its label, with an animated border/tint when selected.
class StyleChip extends StatelessWidget {
  final ImageStyle style;
  final bool selected;
  final VoidCallback onTap;

  const StyleChip({
    super.key,
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
          duration: const Duration(milliseconds: 200),
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

/// A prompt suggestion's label + glyph pair.
class SuggestionItem {
  final String label;
  final IconData icon;
  const SuggestionItem(this.label, this.icon);
}

/// A small pill for the prompt suggestion row — filled + bordered when
/// selected, with the glyph gently scaling in (no bounce/overshoot).
class SuggestionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const SuggestionChip({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHighest,
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant.withOpacity(0.6),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: selected ? 1.15 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: Icon(
                  icon,
                  size: 15,
                  color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
