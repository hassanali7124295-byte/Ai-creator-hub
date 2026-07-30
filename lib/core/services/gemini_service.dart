import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thrown when the Gemini API call fails for any reason (network,
/// bad response shape, non-200 status, missing API key, etc.).
class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);

  @override
  String toString() => message;
}

/// Thin wrapper around Google's Gemini `generateContent` REST endpoint.
///
/// ⚠️ SETUP REQUIRED before this can actually talk to Gemini:
/// 1. Get a free API key at https://aistudio.google.com/app/apikey
/// 2. Replace [apiKey] below, OR (recommended, safer) pass it in at build
///    time and read it via `--dart-define=GEMINI_API_KEY=xxxx`:
///
///      static const apiKey =
///          String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
///
///    Never commit a real API key to a public GitHub repo.
class GeminiService {
  GeminiService._();

  /// Placeholder — swap for a real key (see class doc above) before Phase 2
  /// features actually go live. Left blank on purpose so it fails loudly
  /// and clearly instead of silently calling Google with a fake key.
  static const String apiKey = 'YOUR_GEMINI_API_KEY_HERE';

  static const String _model = 'gemini-1.5-flash';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Sends [prompt] to Gemini and returns the model's text reply.
  ///
  /// [history] is an optional list of prior turns as
  /// `{'role': 'user' | 'model', 'text': '...'}` maps, used to give the
  /// model conversational context. Pass an empty list (default) for a
  /// single-turn request.
  static Future<String> sendMessage(
    String prompt, {
    List<Map<String, String>> history = const [],
  }) async {
    if (apiKey.isEmpty || apiKey == 'YOUR_GEMINI_API_KEY_HERE') {
      throw GeminiException(
        'Gemini API key not configured yet. Add your key in gemini_service.dart.',
      );
    }

    final uri = Uri.parse('$_baseUrl/$_model:generateContent?key=$apiKey');

    final contents = [
      ...history.map(
        (turn) => {
          'role': turn['role'],
          'parts': [
            {'text': turn['text']}
          ],
        },
      ),
      {
        'role': 'user',
        'parts': [
          {'text': prompt}
        ],
      },
    ];

    try {
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'contents': contents}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw GeminiException(
          'Gemini API error (${response.statusCode}): ${response.body}',
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'] as List<dynamic>?;

      if (candidates == null || candidates.isEmpty) {
        throw GeminiException('Gemini returned no candidates.');
      }

      final parts = candidates[0]['content']?['parts'] as List<dynamic>?;
      final text = parts?.isNotEmpty == true ? parts![0]['text'] : null;

      if (text == null || (text as String).trim().isEmpty) {
        throw GeminiException('Gemini returned an empty response.');
      }

      return text.trim();
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Could not reach Gemini: $e');
    }
  }
}
