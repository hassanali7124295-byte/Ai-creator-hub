import 'package:flutter/material.dart';
import '../widgets/coming_soon_placeholder.dart';

/// AI Video Prompt Generator screen — cinematic, scene-based prompts (Phase 2).
class VideoScreen extends StatelessWidget {
  const VideoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Video Prompt Generator')),
      body: const ComingSoonPlaceholder(
        icon: Icons.movie_creation_outlined,
        title: 'AI Video Prompt Generator',
        phaseLabel: 'Phase 2',
      ),
    );
  }
}
