import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'privacy_policy_screen.dart';

/// "About Pak AI" — reached from the drawer (Step 17). Static content:
/// app mark, name, version, a short description, and links out to the
/// Privacy Policy screen and the Play Store listing (best-effort; see
/// [_openStoreListing]).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const String _appVersion = '1.0.0';
  static const String _playStoreUrl =
      'https://play.google.com/store/apps/details?id=com.aicreatorhub.ai_creator_hub';

  Future<void> _openStoreListing(BuildContext context) async {
    final uri = Uri.parse(_playStoreUrl);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication)
        .catchError((_) => false);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the Play Store.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('About Pak AI')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF064E3B), Color(0xFF10B981)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF10B981).withOpacity(0.35),
                    blurRadius: 24,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: const Icon(
                Icons.forum_rounded,
                color: Colors.white,
                size: 40,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Pak AI',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Version $_appVersion',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Pak AI is a premium Gemini-powered chat assistant — '
                'selectable AI Modes, Markdown-formatted replies, natural '
                'read-aloud, and full conversation history, all on your '
                'device.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('Privacy Policy'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const PrivacyPolicyScreen(),
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  leading: const Icon(Icons.star_outline_rounded),
                  title: const Text('Rate Pak AI'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _openStoreListing(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
