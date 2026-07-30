import 'package:flutter/material.dart';
import '../widgets/coming_soon_placeholder.dart';

/// Extra Creator Tools hub — Thumbnail Maker, Translator, Resume Builder,
/// PDF Summarizer (Phase 3).
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Creator Tools')),
      body: const ComingSoonPlaceholder(
        icon: Icons.auto_awesome_outlined,
        title: 'Creator Tools',
        phaseLabel: 'Phase 3',
      ),
    );
  }
}
