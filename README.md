# AI Creator Hub v1.0

An AI-powered creator assistant app built with Flutter — AI chat, image generation,
video prompt generation, script writing, and more creator tools, wrapped in a
modern Material 3 UI.

## Current status: Step 3 of the build

This repo now contains a complete, real Flutter Android project:
- `pubspec.yaml` — dependencies for state management, theming, and networking
- `lib/` — app entry point, Material 3 theme system, home dashboard, bottom
  navigation shell, AI Chat screen (Gemini-ready), and placeholder screens
  for each upcoming feature
- `android/` — a hand-authored Gradle project (Kotlin DSL): `settings.gradle.kts`,
  `build.gradle.kts` (project + app level), `AndroidManifest.xml` (main/debug/profile),
  `MainActivity.kt`, launcher icons, and `gradle-wrapper.properties`. Confirmed
  version combo: **AGP 8.9.1 + Gradle 8.11.1 + Java 17**, compatible with
  Flutter 3.35.x. `compileSdk`/`minSdk`/`targetSdk` are read from the Flutter
  Gradle plugin itself (`flutter.compileSdkVersion` etc.), so they always
  track whichever Flutter SDK actually builds the project.

**One thing is intentionally not committed:** `android/gradle/wrapper/gradle-wrapper.jar`.
It's a compiled binary, not a text file, so instead of a hand-rolled (and
unverifiable) jar, the CI workflow generates a genuine one at build time via
`gradle wrapper --gradle-version 8.11.1`. Every other Android file here is
real and permanent.

## Running locally (if you have Flutter installed)

```bash
flutter pub get
flutter run
```

(`flutter pub get` will create `android/local.properties` for you; if you
don't already have a local Gradle wrapper jar, run `gradle wrapper
--gradle-version 8.11.1 --distribution-type all` once inside `android/`.)

## Building the APK via GitHub Actions

Every push to `main` (and manual runs via the **Actions** tab →
**Build Android APK** → **Run workflow**) will:

1. Set up JDK 17 and the Flutter stable channel
2. Set up Gradle 8.11.1 and generate the wrapper jar for `android/`
3. Run `flutter pub get`
4. Run `flutter analyze` (non-blocking)
5. Build a release APK
6. Upload it as a workflow artifact named **ai-creator-hub-release-apk**

Download the APK from the workflow run's **Artifacts** section once it
finishes — no local Flutter setup required.

## Before this can talk to Gemini

`lib/core/services/gemini_service.dart` still has a placeholder API key.
See the comment at the top of that file for how to add a real one safely
(via `--dart-define`, never committed to git).

## Roadmap

- **Phase 2** — AI Chat, Script Writer, Image Generator, Video Prompt Generator
- **Phase 3** — Thumbnail Maker, Translator, Resume Builder, PDF Summarizer
- **Phase 4** — Google AdMob integration (banner / interstitial / reward)
- **Phase 5** — App icon, splash screen, release signing, Play Store prep
