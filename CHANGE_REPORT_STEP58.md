# CHANGE REPORT — STEP 58
## Pak AI — Professional Network/Connection Error Handling

Baseline: Step 57 (verified — Gemini quota/error handling + credit refunds intact).
No UI redesign. No changes to the composer, send button, Pak AI header/logo, credits UI,
Profile screen, Upgrade Plan, PDF/document features, voice features, or model selector.

---

## 1. Files changed (4 total)

1. `lib/core/services/gemini_service.dart`
2. `lib/models/chat_message.dart`
3. `lib/widgets/chat_bubble.dart`
4. `lib/screens/chat_screen.dart`

Verified with `diff -rq` against the untouched Step 57 baseline — no other file changed.

---

## 2. The bug

The screenshot in the brief came from `GeminiService`'s outer `catch (e)` blocks, which built
the exception message by string-interpolating the raw caught object directly:

```dart
throw GeminiException('Could not reach Gemini: $e');
```

When `e` was a dropped/failed HTTP connection (`http.ClientException`), `$e` expanded to the
full `ClientException` `toString()` — including the exception class name, the reason
("Connection closed before full header was received"), and the **full request URI**
(`https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:streamGenerateContent?alt=sse`).
This string flowed, untouched, all the way to `ChatBubble` because every downstream catch site
(`chat_screen.dart`, `TextRecognitionService`, `DocumentIntelligenceService`) just displays
`GeminiException.message` verbatim — so the fix had to happen at the source, once.

The same pattern existed in `sendMessageStream`'s outer catch.

---

## 3. Centralized classification (`GeminiService`)

**`GeminiErrorKind` (new enum):** `quota | network | api | unknown`. `GeminiException` now
carries a `kind` (auto-derived from `isQuotaError` when not passed explicitly, so every existing
call site keeps working unchanged) plus a new `isNetworkError` getter. `isQuotaError` itself is
untouched — Step 57's quota behavior is preserved exactly.

**`GeminiService._classifyThrownError(Object error)` (new, private):** the single place that
turns an arbitrary *thrown* exception into a clean `GeminiException`. It never echoes any part
of the caught error into the message — it only pattern-matches the error's type/description
against a fixed list of network-failure signatures (`ClientException`, `SocketException`,
`HttpException`, `HandshakeException`, "connection closed/reset/refused/aborted", "failed host
lookup", "network unreachable", "OS error") to decide the `kind`:
- Matches (or a `TimeoutException`) → `GeminiErrorKind.network`, with the standard copy below.
- No match → `GeminiErrorKind.unknown`, with a generic "Something went wrong while processing
  your request. Please try again." — still never `error.toString()`.

**`GeminiService._networkConnectionError()` (new, private):** returns the one standard
connection-problem exception:
> "Couldn't connect to Pak AI. Please check your internet connection and try again."

**`GeminiService._friendlyApiError(statusCode, body)` (updated):** quota detection (HTTP 429 /
`RESOURCE_EXHAUSTED`) is unchanged from Step 57. Every other non-200 status (400/403/500/502/503,
unexpected shapes, etc.) now collapses to one generic, professional message — "We couldn't
complete your request. Please try again." — instead of the previous status-code-specific text,
so no status code, endpoint, or API-rejection detail is ever implied to the user.

**Applied in both request paths**, so both are covered per the Step 58 brief:
- `sendMessage` (non-streaming `generateContent`): its `on TimeoutException` and trailing
  `catch (e)` now call `_networkConnectionError()` / `_classifyThrownError(e)` instead of
  interpolating `$e`.
- `sendMessageStream` (`streamGenerateContent?alt=sse`): same two catch sites updated the same
  way. The raw stream URL can no longer reach `controller.addError(...)`, and therefore never
  reaches `ChatBubble`.

Content-level failures that were already safe (Gemini responding but with a blocked/safety/
empty/`MAX_TOKENS` result) were left as-is — they don't expose exception names, stack traces, or
URLs, and keeping their specific wording ("blocked by safety filters", etc.) is more useful to
the user than collapsing them to the generic copy.

---

## 4. UI layer (`ChatMessage` + `ChatBubble`)

- `ChatMessage` gained an `isNetworkError` field (defaults to `false`; safe default for old
  saved history, same pattern as Step 57's `isQuotaError`).
- `ChatBubble`'s existing error-bubble header — same container, icon slot, and typography as
  before — now picks its title from three states instead of two:
  - `isQuotaError` → **"Pak AI is temporarily busy"** (unchanged, hourglass icon, unchanged).
  - `isNetworkError` → **"Connection problem"** (new; reuses the existing error icon).
  - otherwise → **"Something went wrong"** (unchanged).
- Only the title text branch was touched. No new widget, no new styling, no icon changes beyond
  what Step 57 already had.

---

## 5. `chat_screen.dart`

Every site that turns a caught `GeminiException` (or, in the streaming path, an `Object`) into
an error `ChatMessage` now also passes `isNetworkError` through:

- Main image/attachment send (`_sendMessage`'s `on GeminiException catch (e)`).
- `_streamAiReply`'s outer `catch (e)` — also updated its non-`GeminiException` fallback message
  to the same "Something went wrong while processing your request. Please try again." wording
  used elsewhere, since (now that `GeminiService` always throws/emits a classified
  `GeminiException`) that branch only exists as a last-resort safety net.
- Voice AI reply (`_appendVoiceReplyError`, plus its `on GeminiException catch (e)` call site).

No other logic in these methods changed.

---

## 6. Credit refund behavior (unchanged, verified)

Step 58 introduces no new failure *paths* — only reclassifies the message text/kind of
failures that already threw/emitted a `GeminiException`. `_resolvePendingCreditRefund` and its
three call sites (main send, streaming, voice reply) are untouched:
- A network failure still refunds exactly once, the same way a quota or other API failure
  already did in Step 57 (the credit deduction happens before the Gemini request; refund is
  keyed off `_pendingCreditRefund`, cleared the instant it's resolved either way).
- A successful reply is never refunded.
- Rewarded-ad credits and the subscription/credit architecture are untouched.

---

## 7. What a user sees now

| Failure | Title | Message |
|---|---|---|
| Dropped connection / no internet / DNS failure / timeout (either request path) | Connection problem | Couldn't connect to Pak AI. Please check your internet connection and try again. |
| HTTP 429 / `RESOURCE_EXHAUSTED` | Pak AI is temporarily busy | Please wait a little and try again. |
| Any other non-200 Gemini/API response | Something went wrong | We couldn't complete your request. Please try again. |
| Any other unclassified exception | Something went wrong | Something went wrong while processing your request. Please try again. |

No raw exception class name, URI/URL, endpoint, model name, or stack trace can reach any of
these bubbles — verified by tracing every `GeminiException` construction site in
`gemini_service.dart` (the only file that builds one from something outside the app's control).
