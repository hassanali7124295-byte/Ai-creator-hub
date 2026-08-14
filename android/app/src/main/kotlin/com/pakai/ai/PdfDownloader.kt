package com.pakai.ai

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream

/**
 * STEP 61 — real "save PDF to Android Downloads".
 *
 * A small, self-contained MethodChannel handler — deliberately NOT part of
 * MainActivity.kt. This project's android/ platform folder was not part of
 * the export this file is being added to, and CHANGE_REPORT.md for an
 * earlier step records that MainActivity.kt already carries custom native
 * code (Google OAuth wiring). Overwriting/guessing at that file's content
 * here risked silently deleting unrelated functionality, which Step 61
 * explicitly prohibits — so this handler lives in its own file and is
 * registered with a single added line, documented in
 * CHANGE_REPORT_STEP61.md, instead of being wired up automatically.
 *
 * Two paths, chosen at runtime by API level — this project's existing
 * min SDK is 21 (see the `flutter_launcher_icons` config in
 * `pubspec.yaml`), so both need to be covered, not just 29+:
 *
 * - **Android 10+ (API 29+):** `MediaStore.Downloads`, scoped-storage-safe,
 *   no storage permission required at all. This is the primary,
 *   `MANAGE_EXTERNAL_STORAGE`-free path Step 61 asked for.
 * - **Android 9 and below (API ≤ 28):** a direct write into the public
 *   Downloads directory via legacy external storage. This still needs the
 *   ordinary `WRITE_EXTERNAL_STORAGE` permission declared in
 *   `AndroidManifest.xml` (and, on API 23–28, granted at runtime) for
 *   those older OS versions specifically — see the manifest note in
 *   CHANGE_REPORT_STEP61.md, since `AndroidManifest.xml` wasn't part of
 *   this export either.
 */
object PdfDownloader {
    private const val CHANNEL = "pak_ai/pdf_downloader"

    /** Call once, from `MainActivity.configureFlutterEngine` — see the
     *  CHANGE_REPORT_STEP61.md snippet for the exact one-line addition. */
    fun register(flutterEngine: FlutterEngine, context: Context) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "saveToDownloads") {
                    try {
                        val fileName = call.argument<String>("fileName")
                        val bytes = call.argument<ByteArray>("bytes")
                        val mimeType = call.argument<String>("mimeType") ?: "application/pdf"

                        if (fileName.isNullOrBlank() || bytes == null || bytes.isEmpty()) {
                            result.error("INVALID_ARGS", "fileName/bytes missing or empty", null)
                            return@setMethodCallHandler
                        }

                        val safeName = if (fileName.endsWith(".pdf")) fileName else "$fileName.pdf"

                        val savedPath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            saveViaMediaStore(context, safeName, mimeType, bytes)
                        } else {
                            saveViaLegacyDownloadsDir(safeName, bytes)
                        }

                        if (savedPath == null) {
                            result.error("SAVE_FAILED", "Downloads insert/write did not complete", null)
                        } else {
                            result.success(savedPath)
                        }
                    } catch (e: Exception) {
                        result.error("SAVE_EXCEPTION", e.message, e.stackTraceToString())
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * Android 10+ (API 29+): `MediaStore.Downloads`, `RELATIVE_PATH =
     * Environment.DIRECTORY_DOWNLOADS`, no storage permission needed.
     * Inserts as pending, writes the full byte array, then clears the
     * pending flag and re-opens the row to confirm it is actually
     * readable back before reporting success — matching Step 61's "verify
     * insertion/write succeeded" requirement rather than trusting a
     * non-null Uri alone.
     */
    private fun saveViaMediaStore(
        context: Context,
        fileName: String,
        mimeType: String,
        bytes: ByteArray
    ): String? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val itemUri: Uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: return null

        var outputStream: OutputStream? = null
        try {
            outputStream = resolver.openOutputStream(itemUri) ?: return null
            outputStream.write(bytes)
            outputStream.flush()
        } finally {
            outputStream?.close()
        }

        val clearPending = ContentValues()
        clearPending.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(itemUri, clearPending, null, null)

        // Verify: the row must actually be openable/readable after the
        // write, not just "insert() returned a Uri".
        val verified = try {
            resolver.openInputStream(itemUri)?.use { it.read() >= 0 } ?: false
        } catch (e: Exception) {
            false
        }
        if (!verified) return null

        return itemUri.toString()
    }

    /**
     * Android 9 and below (API ≤ 28): direct write into the public
     * Downloads directory (legacy external storage — still the correct
     * mechanism pre-scoped-storage). Requires `WRITE_EXTERNAL_STORAGE` to
     * be declared for these older OS versions; see
     * CHANGE_REPORT_STEP61.md.
     */
    private fun saveViaLegacyDownloadsDir(fileName: String, bytes: ByteArray): String? {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        if (!downloadsDir.exists() && !downloadsDir.mkdirs()) return null

        val file = File(downloadsDir, fileName)
        file.writeBytes(bytes)

        return if (file.exists() && file.length() == bytes.size.toLong()) {
            file.absolutePath
        } else {
            null
        }
    }
}
