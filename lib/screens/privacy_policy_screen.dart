import 'package:flutter/material.dart';

/// Static, on-device Privacy Policy (Step 17). Kept as plain in-app text
/// rather than a hosted-URL webview so the screen works with no network
/// and no external hosting to stand up — replace `_policyBody` with the
/// real published policy text before a Play Store submission.
class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  static const String _policyBody = '''
Last updated: 2026

Pak AI respects your privacy. This policy explains what data the app
handles and how.

1. Gemini API Key
Your API key is stored only on your device (local secure storage) and is
never sent anywhere except directly to Google's Gemini API to process
your chat requests.

2. Conversations
Chat messages and conversation history are stored locally on your
device. Pak AI does not upload your conversations to any server it
operates.

3. Attachments
Images, documents, and other attachments you send in a chat are
processed on-device and forwarded only to the Gemini API as part of
your request.

4. Third-Party Services
Chat requests are sent to Google's Gemini API, which is subject to
Google's own privacy policy and terms. Pak AI does not control how
Google processes that data.

5. Analytics & Ads
Pak AI does not currently collect analytics or serve ads. If that
changes in a future version, this policy will be updated first.

6. Your Choices
You can clear a conversation or delete your saved API key at any time
from Settings — this removes the data from your device immediately.

7. Contact
Questions about this policy can be sent to the developer through the
Play Store listing's support contact.
''';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            _policyBody.trim(),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}
