# Step 17 — Pak AI Premium Experience: Change Report

## 1. App branding
Verified: Step 16 already replaced every user-visible "AI Creator Hub"
string with "Pak AI" (app title, window title, README, in-app text).
Nothing user-visible needed changing this step. The only remaining
occurrences of the old name are the internal Dart package name
(`ai_creator_hub`) and Android org id (`com.aicreatorhub`) — these are
non-user-visible identifiers, and changing them is a separate, riskier
change (would require updating the CI workflow's `--project-name`/`--org`
flags and could break the reproducible-`android/`-via-`flutter create`
setup this project relies on), so they were deliberately left alone, same
as documented in the existing README.

## 2. App icon
- Generated a new premium adaptive icon from scratch: black-to-emerald
  glassmorphism background, a metallic-emerald chat bubble merged with
  the letter "P", soft outer glow, glass highlight arc — `assets/icon/`
  (`icon.png` = flat/legacy icon, `icon_foreground.png` +
  `icon_background.png` = Android 8+ adaptive icon layers).
- Added `flutter_launcher_icons` as a dev dependency with a
  `flutter_launcher_icons:` config block in `pubspec.yaml` pointing at
  those three assets.
- Because `android/` isn't committed to this repo (it's generated fresh
  every CI run via `flutter create`), added a CI step
  (`dart run flutter_launcher_icons`) that runs right after `flutter
  create` + `flutter pub get`, writing the adaptive icon into the
  freshly generated `android/app/src/main/res/mipmap-*` folders.

## 3. Remove bottom navigation
- `main.dart` now boots straight into `ChatScreen` (`home: const
  ChatScreen()`) instead of `MainNavigation`.
- Deleted `lib/widgets/main_navigation.dart` entirely (no bottom
  `NavigationBar`, no `IndexedStack` of 4 tabs).
- `ConversationDrawer` (opened via the ☰ icon in Chat's app bar) is now
  the single navigation surface, with: **New Chat**, the conversation
  list itself, then a footer nav block with **History, Settings,
  Profile, Rate App, Privacy Policy, About Pak AI**.
- Fixed `HistoryScreen`, which previously called into
  `MainNavigation.jumpToChat()` (now deleted) to return to the Chat tab.
  It now calls a new `ChatScreen.switchToConversation(context, id)`
  static helper — which finds the underlying `ChatScreen`'s state and
  calls its own `_switchConversation` (the same path the drawer's
  conversation list already used) — then pops back to it. This is also
  a correctness fix: previously, opening a conversation from the History
  tab only updated `ConversationProvider.currentId`, not `ChatScreen`'s
  local `_messages` list, so the tab-switch didn't actually reload the
  visible conversation. It does now.

## 4. Chat experience
Unchanged in shape: AI Modes, New Chat, Attachments, Voice-input
placeholder, and History access were all preserved — only *how* you
reach History/Settings/Profile changed (drawer instead of tabs).

## 5. Action icons
In `chat_bubble.dart`'s AI-reply action row:
- Copy, Share, Regenerate, and Read Aloud now use **outlined** icons by
  default (`copy_outlined`, `ios_share_outlined`, `refresh_outlined`,
  `volume_up_outlined`), switching to a **filled** icon only while
  active (e.g. Read Aloud shows a filled stop icon while speaking) —
  the same outlined→filled pattern used by most premium AI chat apps.
  Like/Dislike already followed this pattern and are unchanged.
- Touch target grew from ~30dp to a proper 40dp (18dp icon + 11dp
  padding on all sides).
- Added a soft primary-color glow (`BoxShadow`) around the icon only
  while its action is active (e.g. while speaking).
- Added a tinted `splashColor`/`highlightColor` on each icon's `InkWell`
  so the ripple reads as "premium emerald" rather than default grey.
- Small gap added between icons in the pill (`Wrap` spacing 0 → 2) now
  that each has a bigger tap target.

## 6. Text to speech
New `lib/core/services/tts_voice_service.dart`, wired into
`ChatScreen.initState`:
- Sets `awaitSpeakCompletion(true)`, a natural pitch (1.0), and a
  natural (not default/robotic) speech rate (0.48).
- Enumerates the device's available voices (`FlutterTts.getVoices`),
  filters to English, and picks the best match in priority order:
  1. A voice whose name matches a known **male** signal (`male`,
     `#male`, common Android/iOS male voice codenames like
     `en-us-x-iom`, `daniel`, etc.) and isn't also flagged female.
  2. A higher-quality **"network"** voice over a legacy **"local"** one
     (network voices sound noticeably less robotic), if nothing is
     explicitly gender-tagged.
  3. Any English voice not explicitly flagged female, as a last resort.
- Every step is independently wrapped in try/catch — if a device/engine
  doesn't support voice enumeration or a given setter, that call is
  skipped and the engine's own default is used, so **offline and older
  devices keep working exactly as before** (this only ever upgrades the
  voice when a clearly better one is available).
- The existing instant-stop behavior (`_tts.stop()`) was already
  correct and untouched.

## 7. Drawer
- Header rewritten: rounded-square emerald gradient mark with a glow,
  "Pak AI" title, and app version (`v1.0.0`) — replacing the old plain
  "Chats" text row.
- New footer nav section (`_DrawerNavSection`) below the conversation
  list: History, Settings, Profile, Rate App, Privacy Policy, About
  Pak AI — each a rounded, ripple-enabled row that closes the drawer and
  pushes the target screen (or opens the Play Store listing for Rate
  App).
- New Chat button, search field, pinned/recent conversation list, and
  all existing rename/delete/pin logic are unchanged.

## 8. Chat screen
Empty state, quick suggestions, spacing, and the loading indicator were
already premium going into this step (Step 11) and were left as-is —
no regressions introduced by the navigation/icon/TTS changes.

## 9. Settings
- The Privacy Policy row is now wired to a real `PrivacyPolicyScreen`
  (previously a `// TODO` stub that did nothing on tap).
- The static "Pak AI / Version 1.0.0" row is now tappable and opens the
  new `AboutScreen`.

## 10. History
Unchanged visually — search, rounded cards, pin, rename, delete were
already in place from Step 16. Only its Chat-tab hand-off logic changed
(see section 3).

## 11. Performance / dead code
- Deleted `lib/widgets/main_navigation.dart` (fully unused after the
  bottom nav removal — verified with a repo-wide grep before deleting).
- Fixed two stale doc comments (in `main.dart` and
  `conversation_provider.dart`) that still referenced the removed
  `MainNavigation`/`IndexedStack`.
- No new unused imports were introduced; every new import was verified
  against actual usage in its file.

## 12. Kept working (untouched this step)
Gemini API integration, chat send/regenerate/streaming, attachments,
Markdown rendering, conversation storage, and Settings' API-key
management are all architecturally untouched — this was a navigation,
icon, action-icon, and TTS pass, not a rewrite of any of those systems.

## New files
- `assets/icon/icon.png`, `icon_foreground.png`, `icon_background.png`
- `lib/core/services/tts_voice_service.dart`
- `lib/screens/about_screen.dart`
- `lib/screens/privacy_policy_screen.dart`

## Deleted files
- `lib/widgets/main_navigation.dart`

## Dependencies added
- `url_launcher: ^6.3.1` (Rate App / outbound links)
- `flutter_launcher_icons: ^0.14.3` (dev dependency, icon generation)

## CI workflow changes (`.github/workflows/build-apk.yml`)
Added two steps between `flutter pub get` and `flutter build apk
--release`:
1. Patch `android:label` in the freshly generated
   `AndroidManifest.xml` to `"Pak AI"` (since `flutter create` always
   derives it from `--project-name`).
2. Run `dart run flutter_launcher_icons` to write the adaptive icon into
   the freshly generated `android/` resource folders.

Artifact name changed from `ai-creator-hub-release-apk` to
`pak-ai-release-apk` to match the current branding.
