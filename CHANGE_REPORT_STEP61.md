# CHANGE_REPORT_STEP61.md

## Scope
Step 61 covered the two things the brief called still-unsolved: (A) the
Unicode PDF text-rendering fix from Step 60 re-verified, and (B) a real
Android Downloads save to replace Step 60's `file_saver`-based one. Light
Mode, Dark Mode, chat UI/input bar/bubbles/navigation/settings, PDF
reading/extraction, PDF intent detection, the PDF Ready card's visual
design, and the Share action's behavior were not changed.

---

## DOWNLOAD FIX

### Why the Step 60 download failed
Step 60 added `file_saver` and called `FileSaver.instance.saveFile(...)`,
which returned without throwing — but returning without an exception is
not the same as the bytes actually landing in Android's Downloads, and
that's exactly the gap the brief describes. Two things could not be
verified from this environment (no Android device, no network access to
inspect the package's Android implementation source or changelog for the
exact resolved version): whether the installed `file_saver` release's
Android code path was actually targeting `MediaStore.Downloads`, and
whether its parameter contract (`name`/`ext`/`mimeType`) matched what was
called. Rather than keep trusting an unverifiable third-party
implementation, per requirement #18 it was removed and replaced.

### What exact implementation was used
`file_saver` was **removed**. In its place: a small, project-owned
MethodChannel, `pak_ai/pdf_downloader`, with one method,
`saveToDownloads`, taking `fileName`, `bytes`, `mimeType`. Two new pieces:

- **Dart side** — `lib/core/services/pdf_download_service.dart`
  (`PdfDownloadService.saveToDownloads`): invokes the channel, guards
  against overlapping calls, and turns any failure (missing native
  handler, a platform exception, anything else) into a
  `PdfDownloadException` with the exact clean message the brief specifies
  — never a false success.
- **Native side (new file)** — `android/app/src/main/kotlin/com/pakai/ai/
  PdfDownloader.kt`: a self-contained `object` that registers the
  MethodChannel and implements the save, described below.

### Why `MainActivity.kt` itself was not modified
This project export did not include an `android/` folder before this
step, so `MainActivity.kt`'s actual current content is unknown here — and
an earlier report in this project (`CHANGE_REPORT.md`) records that
`MainActivity.kt` already carries custom native code (Google OAuth
wiring). Writing a fresh `MainActivity.kt` from scratch would risk
silently deleting that unrelated functionality the moment this zip is
merged into the real project — precisely what Step 61 prohibits. Instead,
`PdfDownloader.kt` is fully self-contained and additive, and registration
is one line to be added by hand to the real `MainActivity.kt`'s
`configureFlutterEngine`:

```kotlin
import com.pakai.ai.PdfDownloader
// ...
override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    PdfDownloader.register(flutterEngine, applicationContext)
}
```

If `MainActivity.kt` doesn't yet override `configureFlutterEngine`, add
the whole override; if it already does (e.g. for the existing OAuth
setup), just add the `PdfDownloader.register(...)` line inside the
existing override, after `super.configureFlutterEngine(flutterEngine)`.

**Until that line is added, the Download button will show "Couldn't save
PDF. Please try again."** (a `MissingPluginException`, logged as
`[PdfDownload] ERROR: native channel not registered`) — it will not
silently do nothing or claim success. This is intentional per requirement
#6; it is a one-line manual step rather than a blind file overwrite.

### How Android Downloads is accessed
`PdfDownloader.kt`, by API level:

- **Android 10+ (API 29+, the primary path):** `MediaStore.Downloads`.
  Inserts a row with `DISPLAY_NAME` = the PDF's filename, `MIME_TYPE` =
  `application/pdf`, `RELATIVE_PATH` = `Environment.DIRECTORY_DOWNLOADS`,
  and `IS_PENDING = 1`; opens the resulting `Uri`'s output stream and
  writes the complete byte array; clears `IS_PENDING`; then re-opens the
  same `Uri` for input and reads from it to confirm the row is actually
  readable back before ever reporting success. **No storage permission of
  any kind is requested** — this is exactly the scoped-storage path the
  brief asked for, with no `MANAGE_EXTERNAL_STORAGE`.
- **Android 9 and below (API ≤ 28):** this project's existing min SDK is
  21 (per the `flutter_launcher_icons` config in `pubspec.yaml`), so the
  9-and-below case still needs to be handled. Falls back to a direct
  write into the public Downloads directory
  (`Environment.getExternalStoragePublicDirectory(DIRECTORY_DOWNLOADS)`),
  which is the correct legacy mechanism for those OS versions (scoped
  storage doesn't apply below API 29). **This legacy path needs
  `WRITE_EXTERNAL_STORAGE` declared in `AndroidManifest.xml`** for devices
  on API 21–28 specifically; `AndroidManifest.xml` wasn't part of this
  export either, so this permission line needs to be added by hand the
  same way as the `MainActivity.kt` line above:

  ```xml
  <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
      android:maxSdkVersion="28" />
  ```

  (`maxSdkVersion="28"` scopes the permission to only the OS versions that
  actually need it, so it has no effect at all on Android 10+.) On API
  23–28 this also needs to be *granted at runtime*, which is not yet
  implemented — Android 10+ devices (the large majority in real-world use
  today) need no permission and no runtime prompt at all, since they use
  the MediaStore path above.

### How success is verified
The native handler never reports success on a non-null `Uri`/insert alone
— for the MediaStore path it re-opens and reads from the saved item after
writing; for the legacy path it re-checks `file.exists()` and that
`file.length()` matches the exact byte count written. Only then does it
return the saved path/URI string to Dart, which is the only thing that
triggers "PDF saved to Downloads" in the UI. Any other outcome — insert
failure, write failure, verify failure, or any exception — returns a
Flutter `PlatformException` from the native side, which
`PdfDownloadService` turns into `PdfDownloadException` and the UI shows as
"Couldn't save PDF. Please try again."

### How failure is reported
Every stage logs on both sides, matching the requested tags:

- Dart (`[PdfDownload]` prefix, `pdf_download_service.dart`): `START`,
  `FILE_NAME`, `BYTE_LENGTH`, `SAVE_METHOD`, then either
  `INSERT_SUCCESS` + `WRITE_SUCCESS` + `DOWNLOAD_COMPLETE`, or `ERROR` +
  `STACKTRACE` with the real exception.
- Native (`PdfDownloader.kt`): any exception during insert/write/verify is
  caught and returned as a `PlatformException` carrying
  `e.message`/`e.stackTraceToString()`, which the Dart side logs verbatim
  under `ERROR`/`STACKTRACE` — the real Android-side exception is never
  discarded.

The user-facing message is always exactly one of "PDF saved to Downloads"
(only after verified success) or "Couldn't save PDF. Please try again."
(everything else) — never anything in between, and never a false
positive.

### Android version compatibility
- `minSdkVersion` is unchanged (21, per the existing
  `flutter_launcher_icons` config — no Gradle/Kotlin/`compileSdk`/AGP
  version was touched).
- API 29+ (Android 10+): MediaStore path, no permission needed. This is
  the primary, fully-covered case.
- API 21–28 (Android 5–9): legacy Downloads-directory path, needs the
  manifest permission line above added by hand (not yet runtime-requested
  for API 23–28 — flagged above as a known gap, not silently glossed
  over).
- No `MANAGE_EXTERNAL_STORAGE` anywhere.

### Duplicate-tap protection (requirement #11)
Two layers: the card's existing `_busy` flag disables the button the
moment a save starts (unchanged UI behavior from Step 60), and
`PdfDownloadService.saveToDownloads` also refuses to start a second native
call while one is already in flight, throwing a clean "A download is
already in progress" message if it's ever invoked twice regardless of the
UI state.

### Same bytes, no regeneration (requirement #10)
`_downloadPdf()` reads bytes from `widget.result.filePath` — the exact
file `PdfExportService.generate` already wrote to the app's documents
directory — and passes those bytes straight to
`PdfDownloadService.saveToDownloads`. Nothing calls
`PdfExportService.generate` again.

---

## Unicode PDF text fix — re-verified
Re-inspected `pdf_export_service.dart` from Step 60 as part of this step's
required final check. No changes were made to it — the sfnt validation
(`_looksLikeUsableSfnt`, rejecting TrueType Collections and variable
fonts), the measured-width sanity check (`_tryBuildAndVerifyFont`), and
the per-block draw fallback (`_drawTextSafely`) from Step 60 are all still
in place and untouched. Nothing in Step 61 identified a reason to change
that logic.

---

## Files changed
- `pubspec.yaml` (removed `file_saver`; no other dependency touched)
- `lib/widgets/pdf_export_result_card.dart` (Download action now calls
  `PdfDownloadService` instead of `file_saver`; design, layout, and the
  Share action's behavior unchanged)
- **New:** `lib/core/services/pdf_download_service.dart`
- **New:** `android/app/src/main/kotlin/com/pakai/ai/PdfDownloader.kt`

Not touched: `pdf_export_service.dart` (Unicode fix re-verified only, no
edits), `chat_screen.dart`, PDF intent detection, Dark/Light Mode, chat
UI/input bar/bubbles/navigation/settings, existing PDF read/extraction,
`AndroidManifest.xml` (see the manual step above), `MainActivity.kt` (see
the manual step above), Gradle/Kotlin/`compileSdk`/AGP configuration.

## Verification performed
Static only — no Android device/emulator/network available in this
environment, same limitation as Steps 59 and 60:
- Re-read `PdfDownloader.kt` against the documented `MediaStore.Downloads`
  API shape (column names, `RELATIVE_PATH`/`IS_PENDING` usage,
  insert-then-open-output-stream-then-clear-pending sequence) and Android
  version gating (`Build.VERSION_CODES.Q`).
- Re-read `pdf_download_service.dart` and `pdf_export_result_card.dart`
  for brace/paren balance, control flow, and that every failure path logs
  before showing the clean message.
- Confirmed `file_saver` has zero remaining imports/usages anywhere in
  `lib/` (only explanatory comments mention the old package name).
- Confirmed the MethodChannel name/method/argument keys match exactly
  between `pdf_download_service.dart` and `PdfDownloader.kt`
  (`pak_ai/pdf_downloader`, `saveToDownloads`, `fileName`/`bytes`/
  `mimeType`).
- Traced the full path from a completed `PdfExportResult` through
  `_downloadPdf()` → `PdfDownloadService.saveToDownloads` →
  `MethodChannel.invokeMethod` → `PdfDownloader.saveViaMediaStore`/
  `saveViaLegacyDownloadsDir` → verification → the returned path → the UI
  snackbar, confirming no branch returns success without the native
  verification step having actually passed.

**This has not been confirmed by running the compiled app on a device.**
Two things specifically still need a real-device pass and cannot be
claimed as done here: (1) the one manual `MainActivity.kt` line described
above, without which the channel isn't registered at all, and (2) the
`WRITE_EXTERNAL_STORAGE` manifest line for API ≤28 devices. Both are
flagged explicitly rather than assumed. The `[PdfDownload]` logging added
in this step is what will confirm the fix (or show the exact next problem)
once those two manual steps are done and this runs on the device that
showed the original bug.

## Confirmations
- **PDF intent detection**: not opened.
- **Dark Mode / Light Mode**: not opened.
- **Existing PDF read/extract feature**: not opened.
- **Chat UI, input bar, chat bubbles, navigation, settings**: not opened.
- **PDF Ready card design**: unchanged — same layout, icon, text, and
  button styling as Step 60; only the Download button's `onPressed` logic
  changed.
- **Share action**: unchanged in behavior.
- **No fake share-as-download remains**: `_downloadPdf()` no longer calls
  `Share.shareXFiles` anywhere in its path; that call now only exists in
  `_sharePdf()`.
- **Gradle/Kotlin/compileSdk/AGP**: not touched; no dependency version
  other than removing `file_saver` was changed.
- **No paid API / network / server**: `PdfDownloader.kt` only calls local
  Android `ContentResolver`/`MediaStore`/filesystem APIs; nothing in this
  step makes a network call.
