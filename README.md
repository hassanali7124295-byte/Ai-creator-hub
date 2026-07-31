# AI Creator Hub v1.0

An AI-powered creator assistant app built with Flutter — AI chat, image generation,
video prompt generation, script writing, and more creator tools, wrapped in a
modern Material 3 UI.

## Current status: Step 5 of the build

This repo now contains:
- `pubspec.yaml` — dependencies for state management, theming, and networking
- `analysis_options.yaml` — flutter_lints config
- `lib/` — app entry point, Material 3 theme system, home dashboard, bottom
  navigation shell, AI Chat screen (Gemini-ready), and placeholder screens
  for each upcoming feature
- `test/widget_test.dart` — smoke test for the home dashboard + navigation

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
