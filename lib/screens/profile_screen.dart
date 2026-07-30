import 'package:flutter/material.dart';
import '../widgets/coming_soon_placeholder.dart';

/// User profile screen (Phase 5 polish).
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: const ComingSoonPlaceholder(
        icon: Icons.person_outline_rounded,
        title: 'Profile',
        phaseLabel: 'a later step',
      ),
    );
  }
}
