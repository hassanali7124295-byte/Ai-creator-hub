import 'package:flutter/material.dart';

/// Three bouncing dots shown inside a bubble while the AI is "typing".
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
          ),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (index) {
                final double delay = index * 0.18;
                final double raw = _controller.value - delay;
                // Fractional part of `raw`, always between 0 (inclusive)
                // and 1 (exclusive) — works for negative `raw` too (early
                // frames before a dot's delay has elapsed).
                final double t = raw - raw.floorToDouble();
                // Smooth ease-in-out bounce instead of a linear ramp, so
                // each dot glides up and settles rather than ticking.
                final double wave = t < 0.5 ? t * 2 : (1 - t) * 2;
                final double eased = Curves.easeInOutSine.transform(wave);
                final double lift = eased * 5;
                final double scale = 0.75 + (eased * 0.35);
                double opacity = 0.45 + (eased * 0.55);
                if (opacity > 1.0) opacity = 1.0;
                if (opacity < 0.0) opacity = 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.5),
                  child: Transform.translate(
                    offset: Offset(0, -lift),
                    child: Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary.withOpacity(opacity),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
