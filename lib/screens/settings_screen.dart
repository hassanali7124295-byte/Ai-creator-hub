import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/providers/theme_provider.dart';
import '../core/services/gemini_service.dart';
import 'about_screen.dart';
import 'privacy_policy_screen.dart';

/// Settings screen — theme switcher, Gemini API key management, and about.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _apiKeyController = TextEditingController();
  bool _obscureKey = true;
  bool _isLoadingKey = true;
  bool _hasSavedKey = false;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final key = await GeminiService.getApiKey();
    if (!mounted) return;
    setState(() {
      _apiKeyController.text = key ?? '';
      _hasSavedKey = key != null && key.trim().isNotEmpty;
      _isLoadingKey = false;
    });
  }

  Future<void> _saveApiKey() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) {
      await GeminiService.clearApiKey();
    } else {
      await GeminiService.setApiKey(key);
    }
    if (!mounted) return;
    setState(() => _hasSavedKey = key.isNotEmpty);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(key.isEmpty ? 'API key removed' : 'API key saved'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  static String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System default';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeProvider = context.watch<ThemeProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _SectionLabel('Gemini API Key'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: _isLoadingKey
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _hasSavedKey
                                  ? Icons.check_circle_rounded
                                  : Icons.info_outline_rounded,
                              size: 18,
                              color: _hasSavedKey
                                  ? Colors.green
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _hasSavedKey ? 'Key saved on this device' : 'No key saved yet',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _apiKeyController,
                          obscureText: _obscureKey,
                          decoration: InputDecoration(
                            hintText: 'Paste your Gemini API key',
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureKey
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscureKey = !_obscureKey),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Get a free key at aistudio.google.com/app/apikey. '
                          'It\'s stored only on this device and used solely to '
                          'talk to Gemini from the AI Chat screen.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _saveApiKey,
                            child: const Text('Save API Key'),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('Appearance'),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Column(
                children: [
                  for (final mode in ThemeMode.values)
                    RadioListTile<ThemeMode>(
                      title: Text(_themeModeLabel(mode)),
                      value: mode,
                      groupValue: themeProvider.themeMode,
                      onChanged: (selected) {
                        if (selected != null) {
                          themeProvider.setThemeMode(selected);
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          const _SectionLabel('About'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About Pak AI'),
                  subtitle: const Text('Version 1.0.0'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutScreen()),
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
