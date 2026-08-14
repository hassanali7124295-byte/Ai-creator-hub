import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Step 58 — Professional Network/Connection Error Handling: the coarse
/// category behind every [GeminiException], so a downstream screen (e.g.
/// `ChatBubble`) can pick the right title/copy without ever inspecting
/// exception internals itself.
///
/// - [quota]: Gemini/Google rate-limited or exhausted quota (HTTP 429, or
///   a body reporting `RESOURCE_EXHAUSTED`).
/// - [network]: the request never reached/completed with Gemini at all —
///   no internet, DNS failure, dropped/reset connection, timeout, etc.
/// - [api]: Gemini/Google responded, but with a failure (bad request,
///   rejected auth, server error, empty/blocked response, ...).
/// - [unknown]: any other unexpected failure.
enum GeminiErrorKind { quota, network, api, unknown }

/// Thrown when the Gemini API call fails for any reason (network,
/// bad response shape, non-200 status, missing API key, etc.).
///
/// Step 57 — Quota/Error Handling: [message] is always a short, plain,
/// user-safe sentence. Raw Google/Gemini API error payloads (quota JSON,
/// `RetryInfo`, stack traces, etc.) are never placed here — see
/// [GeminiService._friendlyApiError], the single place that turns a raw
/// HTTP error response into this exception. [isQuotaError] is set when
/// the failure was specifically a quota/rate-limit response (HTTP 429,
/// or a body reporting `RESOURCE_EXHAUSTED`), so callers can show a
/// dedicated "temporarily busy" retry state instead of a generic error.
///
/// Step 58 — Professional Network/Connection Error Handling: [kind]
/// generalizes [isQuotaError] into the full [GeminiErrorKind]
/// classification. [message] is, without exception, always a short,
/// user-safe sentence — never a raw exception's `toString()`, a URL/URI,
/// a model name, or an HTTP response body. See
/// [GeminiService._classifyThrownError] (thrown platform/network
/// exceptions) and [GeminiService._friendlyApiError] (non-200 HTTP
/// responses) — the only two places a [GeminiException] is constructed
/// from something outside this app's own control, so there is exactly
/// one spot for each that decides what's safe to show.
class GeminiException implements Exception {
  final String message;
  final bool isQuotaError;
  final GeminiErrorKind kind;

  GeminiException(
    this.message, {
    this.isQuotaError = false,
    GeminiErrorKind? kind,
  }) : kind = kind ?? (isQuotaError ? GeminiErrorKind.quota : GeminiErrorKind.api);

  /// True when this failure means the request never reached/completed
  /// with Gemini — no internet, DNS failure, dropped connection, timeout,
  /// etc. — as opposed to Gemini itself responding with a failure.
  bool get isNetworkError => kind == GeminiErrorKind.network;

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

// Step 24: the three stages a batched multi-image send moves through, in
// order. A caller (e.g. `ChatScreen`) renders these as a single status
// line so the person always knows what's happening, even though several
// sequential Gemini requests may be happening behind the scenes.
enum GeminiBatchStage { uploading, analyzing, generating }

/// A single progress update emitted by [GeminiService.sendMessageWithImages]
/// as a large image batch send moves through its stages. [currentBatch]
/// and [totalBatches] are only meaningful during [GeminiBatchStage.analyzing]
/// (both are `0` otherwise).
class GeminiBatchProgress {
  final GeminiBatchStage stage;
  final int currentBatch;
  final int totalBatches;
  const GeminiBatchProgress({
    required this.stage,
    this.currentBatch = 0,
    this.totalBatches = 0,
  });
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
  //
  // Step 33.1 — Live Date/Time Fix: this was a `static const String`, so
  // the model only ever had its own stale training-data notion of "today"
  // to fall back on when asked (hence the old "19 May 2024"-style wrong
  // answers). It's now a getter that rebuilds the current-date/time block
  // via [_currentDateTimeLine] — which reads `DateTime.now()` — on every
  // single call, so every request always carries the real device date/time,
  // never a cached or hardcoded one. Everything else about the prompt is
  // unchanged.
  static String get _systemInstruction => '''
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

Current date and time:
- The real current local date and time, read live from the device right now, is: ${_currentDateTimeLine()}.
- Whenever the user asks for today's date, the current day/month/year, or the current time (in any language — e.g. "aaj date kya hai", "today's date", "current date", "what day is today", "current time"), always answer using this real current date/time above. Never use a date from your own training data, never reuse an old answer, and never state any other date.
''';

  static const List<String> _weekdayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static const List<String> _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  /// Formats `DateTime.now()` (the device's live local clock — never a
  /// fixed/hardcoded value) as e.g. "Friday, 07 August 2026, 14:35", so
  /// the model always has today's real date and time grounded in the
  /// prompt itself, refreshed on every single request.
  static String _currentDateTimeLine() {
    final now = DateTime.now();
    final weekday = _weekdayNames[now.weekday - 1];
    final month = _monthNames[now.month - 1];
    final day = now.day.toString().padLeft(2, '0');
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    return '$weekday, $day $month ${now.year}, $hour:$minute';
  }

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

  // Step 57 — Quota/Error Handling: the single place that turns a raw,
  // non-200 Gemini/Google API HTTP response into a [GeminiException].
  // Used by both [sendMessage] and [sendMessageStream] so there is
  // exactly one spot that decides what's safe to show the user — the
  // raw [body] (which, on a quota/rate-limit response, contains fields
  // like `quotaMetric`, `quotaValue`, `quotaDimensions`, and `RetryInfo`)
  // is inspected only to classify the failure and is never echoed back
  // into the returned message.
  static GeminiException _friendlyApiError(int statusCode, String body) {
    // Google returns HTTP 429 for rate-limit/quota errors; some quota
    // failures also surface the gRPC status name `RESOURCE_EXHAUSTED` in
    // the body even when wrapped differently. Either signal is treated
    // as "temporarily busy" — never shown as raw JSON.
    final isQuota = statusCode == 429 || body.contains('RESOURCE_EXHAUSTED');
    if (isQuota) {
      return GeminiException(
        'Please wait a little and try again.',
        isQuotaError: true,
      );
    }

    // Step 58: every other non-200 status (400/403/500/502/503,
    // unexpected shapes, etc.) collapses to one professional, generic
    // "api" failure — never the raw status code, response body, or any
    // other hint about what Google's API rejected and why.
    return GeminiException("We couldn't complete your request. Please try again.");
  }

  // Step 58 — Professional Network/Connection Error Handling: the single
  // place that turns an arbitrary *thrown* Dart/platform exception (as
  // opposed to a non-200 HTTP response, which [_friendlyApiError] already
  // handles) into a clean, typed [GeminiException]. Used by the outer
  // `catch (e)` in both the plain and streaming request paths, so a
  // dropped connection, DNS failure, or any other transport-level error
  // never reaches the UI as `e.toString()` (which is exactly how the
  // "ClientException: Connection closed before full header was
  // received, uri=https://generativelanguage.googleapis.com/..." message
  // used to leak through).
  //
  // Classification is done by pattern-matching the *type/description* of
  // the incoming exception — never by echoing any part of it back into
  // the returned message — so the host, model name, endpoint, and
  // exception class name are never exposed, no matter what the
  // underlying error says.
  static const List<String> _networkErrorSignatures = [
    'clientexception',
    'socketexception',
    'httpexception',
    'handshakeexception',
    'connection closed',
    'connection reset',
    'connection refused',
    'connection abort',
    'connection terminated',
    'failed host lookup',
    'network is unreachable',
    'network unreachable',
    'os error',
  ];

  static GeminiException _classifyThrownError(Object error) {
    if (error is TimeoutException) return _networkConnectionError();

    final description = error.toString().toLowerCase();
    final looksLikeNetworkFailure =
        _networkErrorSignatures.any(description.contains);
    if (looksLikeNetworkFailure) return _networkConnectionError();

    // Anything else unrecognized — still never `error.toString()`.
    return GeminiException(
      'Something went wrong while processing your request. Please try again.',
      kind: GeminiErrorKind.unknown,
    );
  }

  static GeminiException _networkConnectionError() => GeminiException(
        "Couldn't connect to Pak AI. Please check your internet connection "
        'and try again.',
        kind: GeminiErrorKind.network,
      );

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
    //
    // Step 23: image attachments specifically get a much longer allowance
    // (180s) than other "heavy" requests (60s) — analyzing several images
    // together is the slowest case Gemini handles here, and a shorter
    // timeout was cutting genuinely-in-progress multi-image requests off
    // before Gemini could finish.
    final hasImageAttachment =
        attachments.any((a) => a.mimeType.startsWith('image/'));
    final isHeavyRequest = attachments.isNotEmpty || prompt.length > 4000;
    final requestTimeout = hasImageAttachment
        ? const Duration(seconds: 180)
        : Duration(seconds: isHeavyRequest ? 60 : 30);

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
          .timeout(requestTimeout);

      if (response.statusCode != 200) {
        throw _friendlyApiError(response.statusCode, response.body);
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
      // Step 58: a request that never completed in time is a connectivity
      // problem from the user's point of view — same clean "Connection
      // problem" copy as any other network failure, regardless of
      // whether it carried image attachments.
      throw _networkConnectionError();
    } on GeminiException {
      rethrow;
    } catch (e) {
      throw _classifyThrownError(e);
    }
  }

  /// Streams [prompt]'s reply from Gemini as a sequence of incremental
  /// text chunks (deltas — not cumulative), using the
  /// `streamGenerateContent` SSE endpoint. This is what powers the live,
  /// word-by-word "typing" effect in the chat UI (Step 26).
  ///
  /// Cancelling the returned stream's subscription (e.g. via the chat
  /// screen's "Stop" button) aborts the underlying HTTP connection
  /// immediately — the `finally` block below always runs, even on
  /// cancellation, and closes the client.
  ///
  /// Only text-only turns go through this path; requests with image
  /// attachments keep using [sendMessageWithImages] (batched, non-stream),
  /// since merging several batches' analyses doesn't map onto a single
  /// token stream.
  static Stream<String> sendMessageStream(
    String prompt, {
    List<Map<String, String>> history = const [],
    List<GeminiInlinePart> attachments = const [],
    String? modeInstruction,
  }) {
    late StreamController<String> controller;
    http.Client? client;

    Future<void> run() async {
      final apiKey = await getApiKey();
      if (apiKey == null || apiKey.trim().isEmpty) {
        controller.addError(GeminiException(
          'No Gemini API key configured yet. Add one in Settings → Gemini API Key.',
        ));
        await controller.close();
        return;
      }

      final uri =
          Uri.parse('$_baseUrl/$_model:streamGenerateContent?alt=sse');

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

      final isHeavyRequest = attachments.isNotEmpty || prompt.length > 4000;
      final requestTimeout = Duration(seconds: isHeavyRequest ? 60 : 30);

      client = http.Client();
      try {
        final request = http.Request('POST', uri)
          ..headers['Content-Type'] = 'application/json'
          ..headers['x-goog-api-key'] = apiKey.trim()
          ..body = jsonEncode({
            'system_instruction': {
              'parts': [
                {'text': systemText}
              ],
            },
            'contents': contents,
          });

        final streamedResponse =
            await client!.send(request).timeout(requestTimeout);

        if (streamedResponse.statusCode != 200) {
          final body = await streamedResponse.stream
              .transform(utf8.decoder)
              .join()
              .timeout(requestTimeout);
          controller.addError(
            _friendlyApiError(streamedResponse.statusCode, body),
          );
          return;
        }

        var gotAnyText = false;
        String? blockReason;
        String? finishReason;

        await for (final line in streamedResponse.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          final trimmed = line.trim();
          if (!trimmed.startsWith('data:')) continue;
          final jsonStr = trimmed.substring(5).trim();
          if (jsonStr.isEmpty || jsonStr == '[DONE]') continue;

          Map<String, dynamic> decoded;
          try {
            decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
          } catch (_) {
            continue; // Ignore any malformed/partial SSE frame.
          }

          final promptFeedback =
              decoded['promptFeedback'] as Map<String, dynamic>?;
          if (promptFeedback != null && promptFeedback['blockReason'] != null) {
            blockReason = promptFeedback['blockReason'].toString();
          }

          final candidates = decoded['candidates'] as List<dynamic>?;
          if (candidates == null || candidates.isEmpty) continue;

          final candidate = candidates[0] as Map<String, dynamic>;
          finishReason = candidate['finishReason'] as String? ?? finishReason;
          final parts = candidate['content']?['parts'] as List<dynamic>?;
          if (parts == null) continue;

          for (final part in parts) {
            final text = (part as Map<String, dynamic>)['text'];
            if (text is String && text.isNotEmpty) {
              gotAnyText = true;
              controller.add(text);
            }
          }
        }

        if (!gotAnyText) {
          if (blockReason != null) {
            controller.addError(GeminiException(
              'Gemini couldn\'t process this request (blocked: $blockReason). '
              'Try a different file or rephrase your message.',
            ));
          } else if (finishReason == 'SAFETY' ||
              finishReason == 'PROHIBITED_CONTENT') {
            controller.addError(GeminiException(
              'Gemini couldn\'t respond to this — it may have been blocked by '
              'safety filters. Try rephrasing your message.',
            ));
          } else {
            controller.addError(
                GeminiException('Gemini returned an empty response.'));
          }
        }
      } on TimeoutException {
        // Step 58: same "Connection problem" classification as the
        // non-streaming path — see [GeminiService._networkConnectionError].
        controller.addError(_networkConnectionError());
      } on GeminiException catch (e) {
        controller.addError(e);
      } catch (e) {
        // A stream that's been cancelled by the listener closes the client
        // out from under this loop, which surfaces here as a generic
        // error — swallow it silently rather than reporting a spurious
        // failure for what was actually a deliberate Stop tap.
        //
        // Step 58: any other genuine failure is classified the same way
        // as the non-streaming path — never `e.toString()` — so the raw
        // stream URL (`streamGenerateContent?alt=sse`) can never reach
        // `ChatBubble`.
        if (!controller.isClosed) {
          controller.addError(_classifyThrownError(e));
        }
      } finally {
        client?.close();
        await controller.close();
      }
    }

    controller = StreamController<String>(
      onListen: () => unawaited(run()),
      onCancel: () => client?.close(),
    );
    return controller.stream;
  }

  // Step 24: how many images go into a single `sendMessage` request when
  // sending through [sendMessageWithImages]. Keeping each request at this
  // size is what keeps every individual batch fast and reliable — see the
  // note on `_kMaxImagesPerRequest` in `chat_screen.dart`, which caps the
  // *total* images a person can attach at once (20) well above this.
  static const int _kBatchSize = 5;

  /// Sends [prompt] together with [images] to Gemini, automatically
  /// splitting more than [_kBatchSize] images into batches of
  /// [_kBatchSize] and sending ALL batches simultaneously (Step 25 —
  /// Parallel Batch Processing), then merging every successful batch's
  /// reply into one final answer.
  ///
  /// This is the entry point [ChatScreen] uses for any send that includes
  /// one or more image attachments. [images] must already be
  /// compressed — this method makes no changes to the bytes themselves,
  /// it only groups and dispatches the requests. [otherAttachments] (e.g.
  /// a small generic text file sent alongside images) always rides along
  /// with the first batch only, same as before batching existed.
  ///
  /// Image order is preserved exactly: images are split into batches in
  /// the order given, each batch's own images stay in order within it,
  /// and batch replies are merged back together in that same original
  /// batch order regardless of which batch's network request happens to
  /// finish first.
  ///
  /// All batches are dispatched at once via [Future.wait] instead of one
  /// after another — with several images this cuts total wait time down
  /// to roughly the slowest single batch instead of the sum of all of
  /// them. If a batch's request fails, it is retried automatically
  /// exactly once. If it still fails, that batch is dropped and the
  /// remaining batches' results are still used — a single bad/oversized
  /// image (or a transient network hiccup) never sinks the whole request.
  /// Only if *every* batch ultimately fails does this throw
  /// [GeminiException].
  ///
  /// [onProgress], if given, is called as processing moves through each
  /// stage — uploading, analyzing (updated as each in-flight batch
  /// completes, reporting how many of the total are done), then
  /// generating the merged final answer — so the caller can show an
  /// accurate, professional status line the whole time. It is never
  /// called for a plain no-image send (when [images] is empty), since
  /// there's nothing to batch.
  static Future<String> sendMessageWithImages(
    String prompt, {
    List<Map<String, String>> history = const [],
    required List<GeminiInlinePart> images,
    List<GeminiInlinePart> otherAttachments = const [],
    String? modeInstruction,
    void Function(GeminiBatchProgress progress)? onProgress,
  }) async {
    if (images.isEmpty) {
      return sendMessage(
        prompt,
        history: history,
        attachments: otherAttachments,
        modeInstruction: modeInstruction,
      );
    }

    // Split into fixed-size batches, preserving order.
    final batches = <List<GeminiInlinePart>>[];
    for (var start = 0; start < images.length; start += _kBatchSize) {
      final end = (start + _kBatchSize < images.length)
          ? start + _kBatchSize
          : images.length;
      batches.add(images.sublist(start, end));
    }
    final totalBatches = batches.length;

    onProgress?.call(
      GeminiBatchProgress(
        stage: GeminiBatchStage.uploading,
        totalBatches: totalBatches,
      ),
    );
    onProgress?.call(
      GeminiBatchProgress(
        stage: GeminiBatchStage.analyzing,
        currentBatch: 0,
        totalBatches: totalBatches,
      ),
    );

    // Results are written into a fixed-size, index-aligned slot per batch
    // so the original image/batch order survives no matter which batch's
    // request actually completes first — only the merge step below reads
    // this list, and it always reads it front-to-back.
    final results = List<String?>.filled(totalBatches, null);
    GeminiException? lastFailure;
    var completedBatches = 0;

    // Step 25: every batch's request (including its own automatic retry)
    // is wrapped in its own `Future` and they're all started here, up
    // front, then awaited together via `Future.wait` — so all batches are
    // genuinely in flight at the same time instead of one finishing
    // before the next starts. `async`/`await` never blocks the UI thread
    // either way; this only changes *when* each batch's HTTP request is
    // fired off.
    // Track which slice of the original, globally-ordered image list each
    // batch corresponds to (1-based, inclusive) — used below purely to
    // help the merge step number images in their original order. This
    // never surfaces any "batch" language to the model or the user; it's
    // just an index range.
    final batchRanges = <List<int>>[];
    for (final batch in batches) {
      final start = (batchRanges.isEmpty ? 0 : batchRanges.last[1]) + 1;
      batchRanges.add([start, start + batch.length - 1]);
    }

    Future<void> runBatch(int index) async {
      final batchAttachments = [
        ...batches[index],
        // Only the first batch carries any non-image attachment (e.g. a
        // small text file), and only the first batch is asked to also
        // account for it — same as the pre-Step-24 single-request
        // behavior.
        if (index == 0) ...otherAttachments,
      ];
      // Step 25.1: this per-image-group prompt is intentionally free of
      // any "batch"/"group"/"part X of Y" framing — whatever comes back
      // here may end up quoted directly into the final merge prompt (or,
      // if every other group fails, returned to the user as-is), so
      // nothing about the internal split should be something the model
      // learns to talk about.
      final batchPrompt = totalBatches > 1
          ? 'Analyze only the image(s) attached to this message, in order. '
              'Be thorough and specific about what is visible in each one — '
              'this analysis will later be combined with analysis of other '
              'images from the same request into one seamless answer, so '
              'write plainly and factually with no meta-commentary about '
              'this being a partial analysis.\n\n'
              'User\'s request: $prompt'
          : prompt;

      String? reply;
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          reply = await sendMessage(
            batchPrompt,
            history: history,
            attachments: batchAttachments,
            modeInstruction: modeInstruction,
          );
          break;
        } on GeminiException catch (e) {
          lastFailure = e;
          // First failure: retry this same batch once automatically.
          // Second failure: fall through and move on — the other
          // batches, running in parallel, are unaffected.
        }
      }

      if (reply != null) {
        results[index] = reply;
      }

      completedBatches++;
      onProgress?.call(
        GeminiBatchProgress(
          stage: GeminiBatchStage.analyzing,
          currentBatch: completedBatches,
          totalBatches: totalBatches,
        ),
      );
    }

    await Future.wait(
      List.generate(totalBatches, (index) => runBatch(index)),
    );

    // Keep successful results paired with their original image-index
    // range so the merge prompt below can present them in true image
    // order even when one or more groups failed and were dropped.
    final successfulSections = <MapEntry<List<int>, String>>[];
    for (var i = 0; i < totalBatches; i++) {
      final reply = results[i];
      if (reply != null) {
        successfulSections.add(MapEntry(batchRanges[i], reply));
      }
    }
    final batchReplies =
        successfulSections.map((e) => e.value).toList(growable: false);

    if (batchReplies.isEmpty) {
      throw lastFailure ??
          GeminiException('Could not analyze any of the images.');
    }

    if (batchReplies.length == 1) {
      return batchReplies.first;
    }

    onProgress?.call(
      GeminiBatchProgress(
        stage: GeminiBatchStage.generating,
        totalBatches: totalBatches,
      ),
    );

    // Step 25.1 — Premium Vision Merge: turn the separate per-group notes
    // above into ONE natural, professional answer, written the way a
    // careful assistant (ChatGPT-style) would respond after looking at
    // every image at once — never as a report on how the request was
    // processed internally.
    final mergePrompt = StringBuffer()
      ..writeln(
        'Below are factual notes describing a set of images, covering all '
        'of them in their original order. The notes were gathered in '
        'separate passes purely as an internal implementation detail — '
        'that detail is not relevant to the final answer and must never '
        'be mentioned, hinted at, or alluded to.',
      );
    for (final section in successfulSections) {
      final range = section.key;
      final label = range[0] == range[1]
          ? 'Image ${range[0]}'
          : 'Images ${range[0]}-${range[1]}';
      mergePrompt
        ..writeln()
        ..writeln('$label notes:')
        ..writeln(section.value);
    }
    mergePrompt
      ..writeln()
      ..writeln('User\'s request: $prompt')
      ..writeln()
      ..writeln(
        'Write your reply as a single, natural, well-organized answer, as '
        'if you had looked at every image together in one pass:\n'
        '- Never mention batches, groups, parts, passes, internal notes, '
        'or any other detail about how this was processed — the notes '
        'above are only for your reference, not something to describe or '
        'quote from.\n'
        '- Remove duplicate information and combine overlapping or '
        'similar descriptions instead of repeating them.\n'
        '- If the user asked a specific question or gave a specific '
        'instruction (for example: explain, solve, identify, compare, '
        'or extract something), answer that request directly and '
        'concisely — do not default to a generic description of every '
        'image if that is not what was asked.\n'
        '- Otherwise, structure the reply as: a short "Summary" first, '
        'then a numbered walkthrough of the images in their original '
        'order (Image 1, Image 2, ...), each with a concise, useful '
        'description.\n'
        '- Use clear, professional formatting (short paragraphs, '
        'headings, or bullet points as appropriate) and natural language '
        'throughout — no repeated sentences, and no filler about the '
        'process behind the answer.',
      );

    try {
      return await sendMessage(
        mergePrompt.toString(),
        modeInstruction: modeInstruction,
      );
    } on GeminiException {
      // Merging is a best-effort polish step — if it fails, still return a
      // useful single answer rather than losing everything already
      // gathered above.
      return batchReplies.join('\n\n');
    }
  }
}
