# Pak AI

A clean, modern AI chat assistant built with Flutter — one focused chat
experience with selectable **AI Modes**, full conversation history, and
Gemini-powered replies, wrapped in a premium Material 3 UI.

## Step 16: refocused into a single chat app

Pak AI (formerly "AI Creator Hub") has been trimmed down from a multi-tool
dashboard into one thing, done well: chat. The Image Generator, Video
Prompt Generator, Script Writer, and Tools hub — all placeholder or
secondary screens — have been removed, along with the Pollinations image
API integration and every image-generation model/widget/service that only
existed to support them. Chat is now the app's main feature and its
default screen.

## Step 17: premium pass — icon, drawer-only nav, action icons, voice

Pak AI now looks and feels closer to a flagship AI app:

- **App icon**: a custom black + emerald glassmorphism adaptive icon (chat
  bubble merged with "P", metallic gradient, soft glow) replaces the
  default Flutter icon — see `assets/icon/` and the
  `flutter_launcher_icons` config in `pubspec.yaml`.
- **No more bottom nav bar.** `ChatScreen` is now the app's single root
  screen. Its drawer is the only navigation surface: New Chat, the
  conversation list, then History, Settings, Profile, Rate App, Privacy
  Policy, and About Pak AI.
- **Premium action icons**: Copy/Share/Regenerate/Read Aloud now render
  outlined by default and switch to a filled/glowing state only while
  active (e.g. Read Aloud while speaking), matching the pattern most
  AI chat apps use — plus larger (40dp) touch targets and a softer ripple.
- **Natural male voice for Read Aloud**: `TtsVoiceService` (in
  `lib/core/services/tts_voice_service.dart`) scans the device's
  available voices for an English male voice (or the best untagged
  fallback), and sets a natural, non-default speech rate and pitch —
  falling back to the engine default voice on devices that don't expose
  voice enumeration, so offline/older devices keep working.
- **New screens**: `AboutScreen` and `PrivacyPolicyScreen` (fully
  on-device static content, no hosting required).

Four tabs became "Chat is the only screen; everything else is a drawer
destination" — the History/Settings/Profile screens themselves are
unchanged, only how you reach them changed.

## Four tabs → drawer destinations

- **Chat** — the heart of the app. Talk to Pak AI (powered by Gemini),
  with Markdown replies, streaming reveal, copy/share/regenerate/read
  aloud, photo/PDF/file attachments, and a conversation drawer for
  switching chats without leaving the screen.
- **History** — every saved conversation as a full page: search, pin,
  rename, and delete. Tapping one opens it directly in Chat.
- **Settings** — Gemini API key management, light/dark/system theme,
  About Pak AI, and Privacy Policy.
- **Profile** — placeholder, ready for future account features.

### AI Modes

Tap the mode pill in the Chat app bar (🤖 General AI by default) to open
a glass bottom-sheet picker with 9 focused personas:

🤖 General AI · 💻 Coding Expert · 🖼 Image Prompt Expert ·
🎬 Video Prompt Expert · ✍ Script Writer · 📚 Study Assistant ·
📈 Business Advisor · 🌍 Translator · 🧠 Prompt Optimizer

Picking a mode doesn't open a new screen or change how you send
messages — it just layers an extra system instruction onto the next
request sent to Gemini (see `AiModeX.systemPrompt` in
`lib/models/ai_mode.dart` and the `modeInstruction` parameter on
`GeminiService.sendMessage`), so e.g. "Coding Expert" answers as an
expert engineer and "Translator" focuses on accurate translation —
all inside the same chat thread.

### Everything else, unchanged

Multi-conversation history, attachments (photo/camera/PDF/file, with
images auto-downscaled and re-compressed before upload), Markdown
rendering, streaming reveal, copy/share/regenerate/read-aloud, the
Emerald + Graphite chat theme, and light/dark/system theming all work
exactly as before — this was a feature-removal and rebrand, not a
rewrite. `ConversationProvider`, `ThemeProvider`, `GeminiService`, and
local persistence via `shared_preferences` are untouched architecturally.

**`android/` is intentionally not committed.** It's generated fresh by
the CI workflow using the real `flutter create` command from Flutter
**3.44.0** (pinned, not "stable", so the output is reproducible) —
nothing in that folder is hand-written or approximated.

## Running locally (if you have Flutter 3.44 installed)

```bash
flutter create . --platforms=android --org com.aicreatorhub --project-name ai_creator_hub
flutter pub get
sed -i 's/android:label="[^"]*"/android:label="Pak AI"/' android/app/src/main/AndroidManifest.xml
dart run flutter_launcher_icons
flutter run
```

(The underlying Dart/Android project identifier — `ai_creator_hub` /
`com.aicreatorhub` — is unchanged from before the rebrand; only the
user-facing app name, title, and in-app branding are "Pak AI". Renaming
the package identifier itself is a separate, riskier change this pass
deliberately left alone so the existing CI workflow keeps working
without modification.)

## Building the APK via GitHub Actions

Every push to `main` (and manual runs via the **Actions** tab →
**Build Android APK** → **Run workflow**) will:

1. Set up JDK 17 and Flutter **3.44.0** (pinned)
2. Run `flutter create . --platforms=android` to generate a real
   `android/` folder from that exact SDK
3. Run `flutter pub get`
4. Patch `android:label` to "Pak AI" (step 2 always writes the label
   from `--project-name`, so this runs on every fresh `android/`)
5. Generate the adaptive launcher icon via `flutter_launcher_icons`
6. Build a release APK
7. Upload it as a workflow artifact

Download the APK from the workflow run's **Artifacts** section once it
finishes — no local Flutter setup required.

## Before this can talk to Gemini

Open the app → **Settings** → paste a Gemini API key (get a free one at
[aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey)).
It's stored only on-device via `shared_preferences` and used solely to
talk to Gemini from the Chat screen — see
`lib/core/services/gemini_service.dart`.
