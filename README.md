# AI Creator Hub v1.0

An AI-powered creator assistant app built with Flutter — AI chat, image generation,
video prompt generation, script writing, and more creator tools, wrapped in a
modern Material 3 UI.

## Current status: Step 12 of the build

This repo now contains:
- `pubspec.yaml` — dependencies for state management, theming, networking,
  and the attachment pipeline
- `analysis_options.yaml` — flutter_lints config
- `lib/` — app entry point, Material 3 theme system, home dashboard, bottom
  navigation shell, AI Chat screen (Gemini-ready, with image/PDF/file
  attachments sent as part of the conversation), and placeholder screens
  for each upcoming feature
- `test/widget_test.dart` — smoke test for the home dashboard + navigation

### Chat attachments (Step 9)

The "+" button in AI Chat lets you attach a photo, camera shot, PDF, or any
other file to a message. Images are automatically downscaled and
re-compressed to JPEG (capped at 1600px on the long edge, ~3 MB target)
before upload — this keeps requests fast without a visible quality hit, and
also normalizes formats like HEIC to something Gemini reliably accepts.
PDFs and other files are sent as-is, up to 15 MB. Only the attachment on
the current message is sent to Gemini; earlier attachments in the
conversation are not re-uploaded on every follow-up turn.

### Multi-conversation chat (Step 12)

AI Chat now works like ChatGPT/Gemini instead of a single running thread:

- A **conversation drawer** (swipe from the left edge, or the hamburger icon
  the `Scaffold` shows automatically once a `drawer` is set) lists every
  saved chat, with a search field, a **Pinned** section, and a **Recent**
  section sorted by most-recently-updated.
- The **"+" icon in the AI Chat app bar** (and the "New chat" button at the
  top of the drawer) starts a new conversation — reusing the current one if
  it's still empty, so you never end up with duplicate blank chats.
- Conversation titles are **auto-generated from the first user message**
  (first line, capped at 42 characters) the moment it's sent, and can be
  overridden any time via **Rename** in a conversation's `⋮` menu.
- **Delete** asks for confirmation first and can't be undone.
- **Pin** keeps a conversation at the top of the drawer regardless of when
  it was last used.
- The **last conversation you had open is restored automatically** the next
  time the app starts.
- Everything — the conversation list, titles, pin state, and every
  message/attachment inside each one — is persisted locally with
  `shared_preferences`, the same as the rest of the app's storage.
- Upgrading from Step 11: your existing single chat history is
  automatically wrapped into a real (titled) conversation the first time
  the app opens post-update — nothing is lost.

All of Step 9–11's chat features (attachments, Markdown replies, streaming
reveal, copy/share/regenerate/read-aloud, the Emerald + Graphite chat
theme) work unchanged inside every conversation.

**`android/` is intentionally not committed.** It's generated fresh by the
CI workflow using the real `flutter create` command from Flutter **3.44.0**
(pinned, not "stable", so the output is reproducible) — nothing in that
folder is hand-written or approximated. This was a deliberate change: an
earlier version of this repo hand-authored the Gradle files, but the only
way to guarantee they're *exactly* what Flutter's own tooling produces is
to let that tooling generate them.

## Running locally (if you have Flutter 3.44 installed)

```bash
flutter create . --platforms=android --org com.aicreatorhub --project-name ai_creator_hub
flutter pub get
flutter run
```

## Building the APK via GitHub Actions

Every push to `main` (and manual runs via the **Actions** tab →
**Build Android APK** → **Run workflow**) will:

1. Set up JDK 17 and Flutter **3.44.0** (pinned)
2. Run `flutter create . --platforms=android` to generate a real `android/`
   folder from that exact SDK
3. Run `flutter pub get`
4. Run `flutter analyze` and `flutter test` (both non-blocking)
5. Build a release APK
6. Upload it as a workflow artifact named **ai-creator-hub-release-apk**

Download the APK from the workflow run's **Artifacts** section once it
finishes — no local Flutter setup required.

## Before this can talk to Gemini

`lib/core/services/gemini_service.dart` still has a placeholder API key.
See the comment at the top of that file for how to add a real one safely
(via `--dart-define`, never committed to git).

## Roadmap

- **Phase 2** — AI Chat (done), Script Writer, Image Generator, Video Prompt Generator
- **Phase 3** — Thumbnail Maker, Translator, Resume Builder, PDF Summarizer
- **Phase 4** — Google AdMob integration (banner / interstitial / reward)
- **Phase 5** — App icon, splash screen, release signing, Play Store prep
