import 'package:flutter/material.dart';

import '../core/theme/chat_palette.dart';

/// Three small, pulsing emerald dots shown while the AI is "typing" —
/// ChatGPT-style: no bubble, no card, no background behind the dots, just
/// the dots directly on the chat background, left-aligned like an incoming
/// message. Each dot uses the exact same size, color, and ease-in-out pulse
/// curve as before; a single 900ms controller drives all three, staggered
/// so they pulse in sequence instead of together.
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

  Widget _buildDot(double phaseOffset) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final double t = (_controller.value + phaseOffset) % 1.0;
        final double eased = Curves.easeInOutSine.transform(t);
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildDot(0.0),
            const SizedBox(width: 6),
            _buildDot(0.15),
            const SizedBox(width: 6),
            _buildDot(0.3),
          ],
        ),
      ),
    );
  }
}
