import 'package:flutter/material.dart';
import '../widgets/coming_soon_placeholder.dart';

/// AI Script Writer screen — input + generated script + copy option (Phase 2).
class ScriptScreen extends StatelessWidget {
  const ScriptScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Script Writer')),
      body: const ComingSoonPlaceholder(
        icon: Icons.edit_note_rounded,
        title: 'AI Script Writer',
        phaseLabel: 'Phase 2',
      ),
    );
  }
}
