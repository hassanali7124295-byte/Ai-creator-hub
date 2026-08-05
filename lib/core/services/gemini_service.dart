import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Thrown when the Gemini API call fails for any reason (network,
/// bad response shape, non-200 status, missing API key, etc.).
class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);

  @override
  String toString() => message;
}

/// A single inline attachment part in Gemini's wire format — a mime type
/// plus base64-encoded bytes. Produced by `AttachmentProcessorService`.
class GeminiInlinePart {
  final String mimeType;
  final String base64Data;
  const GeminiInlinePart({required this.mimeType, required this.base64Data});

  Map<String, dynamic> toJson() => {
        'inline_data': {
          'mime_type': mimeType,
          'data': base64Data,
        },
      };
}

/// Thin wrapper around Google's Gemini `generateContent` REST endpoint.
///
/// The API key is entered by the user on the Settings screen and stored
/// with [SharedPreferences] — see [getApiKey] / [setApiKey]. Nothing is
/// hardcoded here, so there's nothing to accidentally commit to git.
class GeminiService {
  GeminiService._();

  static const String _apiKeyPrefKey = 'gemini_api_key';

  // Current generally-available flagship model for text chat as of this
  // writing. If Google ships a newer default, update this one line.
  static const String _model = 'gemini-3.6-flash';
  static const String _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  // Step 12.1: a lightweight system instruction covering identity, tone,
  // and language-matching. This is the only persona/behavior logic added —
  // the request/response handling, auth, and endpoint below are untouched.
  static const String _systemInstruction = '''
You are "Pak AI", a friendly and helpful AI assistant.

Identity:
- Your name is Pak AI. If asked who you are or what your name is, answer simply, e.g. "I am Pak AI." or "My name is Pak AI."
- Never say you are Gemini, Google, or any other underlying model/company in normal conversation. Only mention the underlying model if the user specifically asks which model or technology powers the app — otherwise avoid mentioning Google or Gemini.

Language:
- Always reply in the same language and script the user just wrote in, and only that one language — never mix languages or duplicate the answer in a second language.
- If the user writes in Urdu script, reply only in Urdu script.
- If the user writes in Roman Urdu (Urdu words in English letters), reply only in Roman Urdu.
- If the user writes in English, reply only in English.
- Only switch languages if the user explicitly asks for a translation.

Tone and formatting:
- Be warm, natural, professional, and genuinely helpful — never robotic or stiff.
- Use clear formatting when it helps: short paragraphs, headings, and bullet points for lists or steps.
- Use emojis naturally where they add warmth, but never overuse them.
''';

  /// Reads the saved API key, or `null`/empty if none has been set yet.
  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiKeyPrefKey);
  }

  /// Saves the API key entered on the Settings screen.
  static Future<void> setApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiKeyPrefKey, apiKey.trim());
  }

  /// Removes the saved API key.
  static Future<void> clearApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_apiKeyPrefKey);
  }

  static Future<bool> hasApiKey() async {
    final key = await getApiKey();
    return key != null && key.trim().isNotEmpty;
  }

  /// Sends [prompt] to Gemini and returns the model's text reply.
  ///
  /// [history] is an optional list of prior turns as
  /// `{'role': 'user' | 'model', 'text': '...'}` maps, used to give the
  /// model conversational context. Pass an empty list (default) for a
  /// single-turn request.
  ///
  /// [attachments] are optional inline files (images, or small text-like
  /// files) attached to *this* turn only — prior turns in [history] are
  /// always sent as text, so previously-sent attachments aren't
  /// re-uploaded on every follow-up message. PDFs are handled differently
  /// by the caller: their text is extracted on-device and folded directly
  /// into [prompt] instead of appearing here (see
  /// `AttachmentProcessorService`), so Gemini always receives a single
  /// plain-text prompt for PDF content rather than a binary upload.
  ///
  /// [modeInstruction] (Step 16 — AI Modes) is an optional extra system
  /// instruction layered on top of the base [_systemInstruction] identity
  /// prompt — see the `AiModeX.systemPrompt` extension getter in
  /// `models/ai_mode.dart`. Pass `null` or an empty string for plain
  /// default behavior.
  static Future<String> sendMessage(
    String prompt, {
    List<Map<String, String>> history = const [],
    List<GeminiInlinePart> attachments = const [],
    String? modeInstruction,
  }) async {
    final apiKey = await getApiKey();

    if (apiKey == null || apiKey.trim().isEmpty) {
      throw GeminiException(
        'No Gemini API key configured yet. Add one in Settings → Gemini API Key.',
      );
    }

    final uri = Uri.parse('$_baseUrl/$_model:generateContent');

    final systemText =
        (modeInstruction != null && modeInstruction.trim().isNotEmpty)
            ? '$_systemInstruction\n\n${modeInstruction.trim()}'
            : _systemInstruction;

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
          {'text': prompt},
          ...attachments.map((a) => a.toJson()),
        ],
      },
    ];

    // A long-running request (an image/file attachment, or a large prompt
    // such as one carrying extracted PDF text) gets more time before we
    // give up — a plain short text turn should still fail fast.
    final isHeavyRequest = attachments.isNotEmpty || prompt.length > 4000;

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              // Current recommended auth header per Gemini API docs.
              'x-goog-api-key': apiKey.trim(),
            },
            body: jsonEncode({
              'system_instruction': {
                'parts': [
                  {'text': systemText}
                ],
              },
              'contents': contents,
            }),
          )
          .timeout(Duration(seconds: isHeavyRequest ? 60 : 30));

      if (response.statusCode == 400 || response.statusCode == 403) {
        final hint = response.statusCode == 400 && attachments.isNotEmpty
            ? 'Gemini rejected the request — it may not support this file type. '
                'Double-check the API key in Settings, or try a different file.'
            : 'Gemini rejected the request (${response.statusCode}). '
                'Double-check the API key in Settings.';
        throw GeminiException(hint);
      }

      if (response.statusCode != 200) {
        throw GeminiException(
          'Gemini API error (${response.statusCode}): ${response.body}',
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'] as List<dynamic>?;

      if (candidates == null || candidates.isEmpty) {
        final blockReason =
            (decoded['promptFeedback'] as Map<String, dynamic>?)?['blockReason'];
        if (blockReason != null) {
          throw GeminiException(
            'Gemini couldn\'t process this request (blocked: $blockReason). '
            'Try a different file or rephrase your message.',
          );
        }
        throw GeminiException('Gemini returned no candidates.');
      }

      final finishReason = candidates[0]['finishReason'] as String?;
      final parts = candidates[0]['content']?['parts'] as List<dynamic>?;
      final text = parts?.isNotEmpty == true ? parts![0]['text'] : null;

      if (text == null || (text as String).trim().isEmpty) {
        if (finishReason == 'SAFETY' || finishReason == 'PROHIBITED_CONTENT') {
          throw GeminiException(
            'Gemini couldn\'t respond to this — it may have been blocked by '
            'safety filters. Try a different file or rephrase your message.',
          );
        }
        if (finishReason == 'MAX_TOKENS') {
          throw GeminiException(
            'The response was cut off because it got too long. Try asking '
            'about a smaller part of the file.',
          );
        }
        throw GeminiException('Gemini returned an empty response.');
      }

      return text.trim();
    } on TimeoutException {
      throw GeminiException(
        'Gemini is taking too long to respond. Check your connection and '
        'try again — large files may need a smaller attachment.',
      );
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw GeminiException('Could not reach Gemini: $e');
    }
  }
}
