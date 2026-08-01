import 'package:flutter/material.dart';

import '../core/theme/chat_palette.dart';

/// A single soft, pulsing emerald dot shown inside a bubble while the AI
/// is "typing" (Step 12.4) — replaces the previous three-dot fade with
/// one dot that gently grows/shrinks while its opacity breathes in and
/// out. No bounce, no spring — just a slow, smooth ease.
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
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
          boxShadow: isDark
              ? null
              : [
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
            final double eased =
                Curves.easeInOutSine.transform(_controller.value);
            final double scale = 0.75 + (eased * 0.5); // 0.75 -> 1.25
            final double opacity = 0.35 + (eased * 0.65); // 0.35 -> 1.0
            return Transform.scale(
              scale: scale,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ChatPalette.userBubble.withOpacity(opacity),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
