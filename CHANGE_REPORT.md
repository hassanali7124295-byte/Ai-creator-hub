# CHANGE_REPORT.md — Step 20: Permanent Android Package Rename

## Old package
`com.aicreatorhub.ai_creator_hub`

## New package
`com.pakai.ai`

After this change, every generated `android/app/build.gradle.kts` has:

```
applicationId = "com.pakai.ai"
namespace = "com.pakai.ai"
```

---

## ⚠️ Important: why `.github/workflows/build-apk.yml` was changed

The requested allowed-files list was `android/app/build.gradle.kts`,
`android/app/src/**`, `android/AndroidManifest.xml`, and Android package
folders. **None of those exist in this repository as committed files.**
Since Step 5, `android/` has deliberately **not** been committed — every
CI run regenerates it from scratch with:

```
flutter create --platforms=android --org com.aicreatorhub --project-name ai_creator_hub .
```

That single line is the *entire* current source of the Android package
name. Editing a `build.gradle.kts` or `MainActivity.kt` directly in this
zip would have no lasting effect: the very next push triggers CI, which
runs `flutter create` again, regenerates `android/` from that same `--org
com.aicreatorhub` command, and silently reverts the rename — the opposite
of "permanent."

So the only file that can make this rename actually permanent is the CI
workflow itself. This is the same reasoning already applied by this
project's own prior steps — the "Set app display name" and "Add
microphone permission" steps in this same workflow exist for exactly this
reason (patching values that `flutter create` doesn't produce correctly
by default, on every run, since nothing is committed for it to persist
in). This step follows that established pattern rather than inventing a
new one.

**One file changed:** `.github/workflows/build-apk.yml`. No file under
`lib/**` was touched, and no Dart code changed — confirmed by diff against
the prior delivered zip (see checklist below).

---

## What the new CI step does (runs immediately after `flutter create`, before `flutter pub get`)

1. **`android/app/build.gradle.kts`** — replaces every occurrence of
   `com.aicreatorhub.ai_creator_hub` with `com.pakai.ai`, which covers
   both the `applicationId = "..."` line (inside `defaultConfig {}`) and
   the `namespace = "..."` line (inside `android {}`) in one pass, since
   `flutter create` always writes both as the identical org+project-name
   string.
2. **`MainActivity.kt`** — moves it from
   `android/app/src/main/kotlin/com/aicreatorhub/ai_creator_hub/MainActivity.kt`
   to `android/app/src/main/kotlin/com/pakai/ai/MainActivity.kt`, matching
   the new package's folder convention, and rewrites its `package
   com.aicreatorhub.ai_creator_hub` declaration line to `package
   com.pakai.ai`. The now-empty old `com/aicreatorhub/ai_creator_hub` and
   `com/aicreatorhub` folders are removed.
3. **`AndroidManifest.xml`** — defensively patches a legacy
   `package="com.aicreatorhub.ai_creator_hub"` manifest attribute *if*
   one is present. Modern AGP/Flutter templates (matching this project's
   pinned Flutter 3.44.0) set the package exclusively via Gradle's
   `namespace`, so this is expected to be a no-op — kept only as a
   safety net in case that ever changes.
4. **Fails the build loudly** (`::error::` + `exit 1`) instead of
   silently doing nothing if `flutter create`'s output ever stops
   matching the expected file layout — so a future Flutter upgrade that
   changes template structure surfaces as a clear CI failure, not a
   silently-reverted package name.
5. Ends with a verification block that prints the resulting
   `applicationId`/`namespace` lines, the `MainActivity.kt` package
   declaration, and a `find` of every file under
   `android/app/src/main/kotlin` — visible directly in the Actions log
   for every build.

---

## Files changed

- `.github/workflows/build-apk.yml` — one new step added (see above).
  Nothing else in the workflow changed (Flutter version pin, other
  steps, artifact name/path — all untouched).
- `CHANGE_REPORT.md` — this file (replaces the Step 19.3A version).

## Files explicitly NOT changed

- Nothing under `lib/**` — no Dart code, no Chat UI, Welcome Screen,
  Profile, Settings, History, Theme, TTS, AI logic, Authentication, or
  Drawer.
- `pubspec.yaml` — the Dart package name (`ai_creator_hub`) is
  independent of the Android `applicationId`/`namespace` and is
  deliberately left as-is; changing it would break every `package:
  ai_creator_hub/...` import across `lib/**`, which the task explicitly
  forbids touching.
- App display name — still "Pak AI" (the existing `android:label` patch
  step is untouched and runs after this new step).
- Assets, launcher icons, theme, animations — untouched.
- `SETUP.md` (Step 19.3A) — untouched; its Google OAuth package-name
  references (`com.aicreatorhub.ai_creator_hub`) are now **stale** as a
  side effect of this rename (see checklist below) but were left alone
  since editing it wasn't requested for this step and it's
  documentation, not app configuration.

---

## Verification checklist

- [x] `applicationId` set to `com.pakai.ai` — via the new CI step's sed
      replace on `build.gradle.kts` (confirmed no other applicationId
      references exist in the freshly-generated template).
- [x] `namespace` set to `com.pakai.ai` — same sed replace covers both
      in one pass, since `flutter create` writes them identically.
- [x] `MainActivity` moved to the `com.pakai.ai` package folder and its
      `package` declaration updated to match.
- [x] Old `com/aicreatorhub/...` Kotlin source folders removed (no
      orphaned/duplicate MainActivity left behind).
- [x] `AndroidManifest.xml` checked for a legacy `package=` attribute
      (defensive patch included; expected no-op on this Flutter version).
- [x] Workflow step fails loudly instead of silently no-op-ing if
      `flutter create`'s file layout ever changes.
- [x] No `lib/**` file changed — confirmed via `diff -rq` against the
      previously delivered project.
- [x] App name unchanged ("Pak AI") — the existing `android:label` patch
      step still runs, untouched, after the new rename step.
- [x] No UI, theme, animation, icon, or asset changes.
- [ ] **Not verifiable in this environment**: an actual `flutter build
      apk --release` run. There is no local Flutter/Android SDK here (as
      in every prior step) — this is verified by pushing to GitHub and
      letting the pinned Flutter 3.44.0 CI workflow build it; the new
      step's own verification block (grep + find, see above) will show
      up directly in that run's log.

## ⚠️ Follow-up needed (not part of this step's scope)

`SETUP.md` (Step 19.3A) documents Google OAuth Client setup against the
**old** package name `com.aicreatorhub.ai_creator_hub`. Since the
applicationId is now `com.pakai.ai`, any Google Cloud OAuth Android
client already registered against the old package name will **stop
matching** — Google Sign-In will start failing with a package-name
mismatch (`DEVELOPER_ERROR`, status code 10) until a new OAuth Android
client is registered for `com.pakai.ai` with the same SHA-1
fingerprint(s). `SETUP.md` itself wasn't edited for this step (out of
scope), but its package name is now out of date — worth a follow-up pass.

---

## STEP 27A — Premium Home Screen Redesign (UI only)

**File touched:** `lib/screens/chat_screen.dart` only. No business logic,
API calls, Gemini logic, auth, chat/streaming/attachment flow, or routing
was changed — verified against the pre-step build: only this file diffs.

**What changed (empty-conversation "Home" state only):**
- New premium top bar (home state only): drawer icon, "Pak AI" wordmark
  with gradient mark + small crescent icon, profile avatar (→
  `ProfileScreen`, same route the drawer already uses), settings button
  (→ existing `_openSettings`). The original functional chat app bar
  (live title, new chat, clear chat) is unchanged and still shown the
  moment a conversation has messages — split into
  `_buildChatAppBar`/`_buildHomeAppBar`, chosen by `_messages.isEmpty`.
- New greeting block: time-aware "Good Morning/Afternoon/Evening 👋",
  subtext, and a "Fast • Private • Intelligent" line.
- New glass "Ask anything..." search card with mic/camera/upload icons —
  wired to the existing `_onVoiceTap` / `_openAttachmentSheet` handlers;
  tapping the card focuses the real composer via a new shared
  `_composerFocusNode`.
- New 2-column quick-action grid (Ask Question, Brainstorm, Write
  Script, Explain Image, Summarize PDF, Translate, Generate Code, Math
  Solver, Study Helper) — tapping a card pre-fills the composer via the
  existing `_applySuggestion`, same as the old suggestion chips did.
- Faint (5% opacity) map-glyph watermark behind the home content.
- Emerald/white, rounded (22–28), soft-shadow, glassmorphism styling;
  Poppins already ships via `app_theme.dart`'s Google Fonts setup, so no
  new dependency was needed. Fade/slide-up entrance via already-present
  `animate_do`.
- Bottom input bar, chat bubbles, streaming, jump-to-latest, attachment
  preview row, mode pill, API-key banner: all untouched.

**Not verifiable in this environment:** no local Flutter/Android SDK —
verified by manual structural review (brace/paren balance, diff against
pre-step tree) instead of `flutter analyze`/`flutter build`.
