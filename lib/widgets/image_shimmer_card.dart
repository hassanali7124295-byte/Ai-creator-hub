import 'package:flutter/material.dart';

/// A premium loading placeholder for one in-progress generated image: a
/// soft base color with a diagonal highlight band that sweeps across on
/// a loop. Fills whatever box its parent gives it (a grid cell sized to
/// the requested aspect ratio), so no aspect ratio is needed here.
class ImageShimmerCard extends StatefulWidget {
  const ImageShimmerCard({super.key});

  @override
  State<ImageShimmerCard> createState() => _ImageShimmerCardState();
}

class _ImageShimmerCardState extends State<ImageShimmerCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.colorScheme.surfaceContainerHighest;
    final highlight = theme.colorScheme.surfaceContainerHigh.withOpacity(0.9);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(-1 + 3 * t, -0.3),
              end: Alignment(0 + 3 * t, 0.3),
              colors: [base, highlight, base],
              stops: const [0.35, 0.5, 0.65],
            ).createShader(bounds),
            child: Container(color: base),
          );
        },
      ),
    );
  }
}
