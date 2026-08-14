import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// STEP 61 — real "save to Android Downloads", replacing Step 60's
/// `file_saver` dependency, which could not be confirmed to actually write
/// into Downloads on the real device this was tested on.
///
/// This talks to a small, project-owned native handler
/// (`PdfDownloader.kt`, registered from `MainActivity.kt`) over a
/// MethodChannel, rather than a third-party file-saving package — so the
/// exact Android call being made (`MediaStore.Downloads`,
/// `RELATIVE_PATH = Environment.DIRECTORY_DOWNLOADS`) is fully inspectable
/// in this project instead of living inside an opaque dependency. No
/// broad storage permission, no `MANAGE_EXTERNAL_STORAGE`, no server, no
/// paid API. See `CHANGE_REPORT_STEP61.md` for the native side and the one
/// manual wiring step it still needs in `MainActivity.kt`.
class PdfDownloadException implements Exception {
  final String message;
  const PdfDownloadException(this.message);

  @override
  String toString() => message;
}

class PdfDownloadService {
  PdfDownloadService._();

  static const MethodChannel _channel = MethodChannel('pak_ai/pdf_downloader');

  /// Guards against a second save starting while one is already in
  /// flight (Step 61 requirement #11 — no duplicate/conflicting downloads
  /// from a fast double-tap). The UI's own `_busy` flag in
  /// `PdfExportResultCard` already disables the button while saving; this
  /// is a second, service-level guard so the same protection holds even if
  /// this method is ever called from somewhere else.
  static bool _busy = false;

  static void _log(String tag, [Object? detail]) {
    debugPrint(detail == null ? '[PdfDownload] $tag' : '[PdfDownload] $tag: $detail');
  }

  /// Saves [bytes] as [fileName] (must already end in `.pdf`) into the
  /// device's public Downloads location, via native MediaStore code, and
  /// returns the resulting content URI/path on success.
  ///
  /// Always throws [PdfDownloadException] with an already user-friendly
  /// message on any failure — the real platform exception and stack trace
  /// are logged first (`[PdfDownload] ERROR` / `STACKTRACE`). Never
  /// returns/claims success unless the native save actually completed.
  static Future<String> saveToDownloads({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (_busy) {
      throw const PdfDownloadException(
        'A download is already in progress. Please wait a moment.',
      );
    }
    _busy = true;
    _log('START');
    _log('FILE_NAME', fileName);
    _log('BYTE_LENGTH', bytes.length);
    _log('SAVE_METHOD', 'MediaStore');
    try {
      final String? savedPath = await _channel.invokeMethod<String>(
        'saveToDownloads',
        {
          'fileName': fileName,
          'bytes': bytes,
          'mimeType': 'application/pdf',
        },
      );

      if (savedPath == null || savedPath.isEmpty) {
        // The native side returned without an exception but also without
        // a real result — treat this as a failure, not a success, per
        // Step 61 requirement #6.
        throw const PdfDownloadException("Couldn't save PDF. Please try again.");
      }

      _log('INSERT_SUCCESS');
      _log('WRITE_SUCCESS');
      _log('DOWNLOAD_COMPLETE', savedPath);
      return savedPath;
    } on MissingPluginException catch (e, stackTrace) {
      // The native handler isn't registered yet — see the "manual step"
      // called out in CHANGE_REPORT_STEP61.md. Reported the same honest
      // way as any other failure; never shown to the user as if it were a
      // generic app bug with no clear fix.
      _log('ERROR', 'native channel not registered ($e)');
      _log('STACKTRACE', stackTrace);
      throw const PdfDownloadException("Couldn't save PDF. Please try again.");
    } on PlatformException catch (e, stackTrace) {
      _log('ERROR', '${e.code}: ${e.message}');
      _log('STACKTRACE', stackTrace);
      throw const PdfDownloadException("Couldn't save PDF. Please try again.");
    } on PdfDownloadException {
      rethrow;
    } catch (e, stackTrace) {
      _log('ERROR', e.toString());
      _log('STACKTRACE', stackTrace);
      throw const PdfDownloadException("Couldn't save PDF. Please try again.");
    } finally {
      _busy = false;
    }
  }
}
