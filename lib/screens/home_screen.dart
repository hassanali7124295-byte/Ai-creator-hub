import 'package:flutter/material.dart';
import 'package:animate_do/animate_do.dart';

import 'chat_screen.dart';
import 'image_screen.dart';
import 'video_screen.dart';
import 'script_screen.dart';
import 'tools_screen.dart';

/// Home Dashboard — entry point of the app.
/// Shows a greeting header and a grid of feature cards that deep-link
/// into each AI tool.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static final List<_FeatureItem> _features = [
    _FeatureItem(
      icon: Icons.chat_bubble_rounded,
      label: 'AI Chat',
      subtitle: 'Talk with your AI assistant',
      color: const Color(0xFF6C5CE7),
      builder: (_) => const ChatScreen(),
    ),
    _FeatureItem(
      icon: Icons.image_rounded,
      label: 'Image Generator',
      subtitle: 'Turn prompts into visuals',
      color: const Color(0xFFE17055),
      builder: (_) => const ImageScreen(),
    ),
    _FeatureItem(
      icon: Icons.movie_creation_rounded,
      label: 'Video Prompts',
      subtitle: 'Cinematic scene ideas',
      color: const Color(0xFF00B894),
      builder: (_) => const VideoScreen(),
    ),
    _FeatureItem(
      icon: Icons.edit_note_rounded,
      label: 'Script Writer',
      subtitle: 'Draft scripts in seconds',
      color: const Color(0xFF0984E3),
      builder: (_) => const ScriptScreen(),
    ),
    _FeatureItem(
      icon: Icons.auto_awesome_rounded,
      label: 'Creator Tools',
      subtitle: 'Thumbnails, translate & more',
      color: const Color(0xFFFDCB6E),
      builder: (_) => const ToolsScreen(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: FadeInDown(
                duration: const Duration(milliseconds: 400),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Welcome back 👋',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'AI Creator Hub',
                              style: theme.textTheme.headlineSmall,
                            ),
                          ],
                        ),
                      ),
                      CircleAvatar(
                        radius: 24,
                        backgroundColor:
                            theme.colorScheme.primary.withOpacity(0.15),
                        child: Icon(
                          Icons.auto_awesome,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  'Create something amazing',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 0.95,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = _features[index];
                    return FadeInUp(
                      delay: Duration(milliseconds: 80 * index),
                      duration: const Duration(milliseconds: 400),
                      child: _FeatureCard(item: item),
                    );
                  },
                  childCount: _features.length,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureItem {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final WidgetBuilder builder;

  _FeatureItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.builder,
  });
}

class _FeatureCard extends StatelessWidget {
  final _FeatureItem item;
  const _FeatureCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: item.builder),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: item.color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(item.icon, color: item.color, size: 26),
              ),
              const Spacer(),
              Text(
                item.label,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                item.subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
