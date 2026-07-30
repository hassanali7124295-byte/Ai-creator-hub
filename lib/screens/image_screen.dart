import 'package:flutter/material.dart';
import '../widgets/coming_soon_placeholder.dart';

/// AI Image Generator screen — prompt input + generated image grid (Phase 2).
class ImageScreen extends StatelessWidget {
  const ImageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Image Generator')),
      body: const ComingSoonPlaceholder(
        icon: Icons.image_outlined,
        title: 'AI Image Generator',
        phaseLabel: 'Phase 2',
      ),
    );
  }
}
