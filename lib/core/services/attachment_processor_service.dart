import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:mime/mime.dart';
import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../models/chat_attachment.dart';
import '../../widgets/attachment_sheet.dart' show AttachmentType;
import 'attachment_service.dart';
import 'gemini_service.dart';

/// Thrown when an attachment can't be safely prepared for sending —
/// e.g. it's unreadable, empty, an unsupported type, or too large even
/// after compression. The message is always written to be shown to the
/// user as-is (see `ChatScreen._reportAttachmentFailure`).
class AttachmentException implements Exception {
  final String message;
  AttachmentException(this.message);

  @override
  String toString() => message;
}

/// The outcome of processing a picked attachment: metadata to store on the
/// [ChatMessage], plus exactly one of:
///  - [part] — a base64 inline-data payload for Gemini (images and
///    generic text-like files), or
///  - [extractedText] — plain text pulled out of a PDF, meant to be
///    folded directly into the outgoing prompt rather than sent as
///    binary (see `AttachmentProcessorService._processPdf`).
class ProcessedAttachment {
  final ChatAttachment metadata;
  final GeminiInlinePart? part;
  final String? extractedText;
  const ProcessedAttachment({
    required this.metadata,
    this.part,
    this.extractedText,
  });
}

/// Turns a raw [AttachmentResult] from the picker into something that can
/// actually be sent to Gemini and stored in chat history.
///
/// This is the one place that knows how to handle each [ChatAttachmentKind]:
///  - images are downscaled/re-encoded, then sent as inline image data so
///    Gemini can see them alongside the prompt (explain/describe/solve/
///    extract text/identify objects all go through this same path — the
///    "task" lives entirely in the user's prompt text, not the file).
///  - PDFs have their text extracted on-device (in page batches, off the
///    UI isolate) and folded into the prompt as plain text instead of
///    being uploaded as a binary blob.
///  - anything else falls back to a small allow-list of plain-text mime
///    types sent as inline data; anything not on that list is rejected
///    up front with a clear "unsupported file" message instead of being
///    sent to Gemini and failing there.
class AttachmentProcessorService {
  AttachmentProcessorService._();

  /// Longest edge an image is downscaled to before sending, in pixels.
  static const int _maxImageDimension = 1600;

  /// Target size (bytes) the JPEG re-encode tries to land under.
  static const int _targetImageBytes = 3 * 1024 * 1024; // 3 MB

  /// Hard safety ceiling for any single attachment's raw bytes (applies
  /// after image compression, or as-is for PDFs/generic files). Gemini's
  /// inline-data limit is comfortably above this once base64-encoded.
  static const int _maxRawBytes = 15 * 1024 * 1024; // 15 MB

  /// Hard cap on how many characters of extracted PDF text are folded
  /// into a single prompt. Keeps very long documents from blowing past
  /// Gemini's context window (or simply making the request huge/slow) —
  /// extraction stops early once this is hit rather than reading the
  /// entire document into memory as text at once; see
  /// [_extractPdfText]'s page-batch loop.
  static const int _maxPdfTextChars = 120000;

  /// Plain-text-ish mime types allowed through the generic "Files" picker
  /// as inline data. Images and PDFs never reach this list — [classify]
  /// already routes them to their own dedicated paths above. Anything not
  /// on this list is rejected with a clear error instead of being sent to
  /// Gemini, which would otherwise fail later with a much more confusing
  /// API error.
  static const Set<String> _supportedGenericMimeTypes = {
    'text/plain',
    'text/csv',
    'text/markdown',
    'text/html',
    'application/json',
    'application/rtf',
  };

  /// Decides the [ChatAttachmentKind] for a picked result based on which
  /// picker source it came from and, for generic files, its detected mime
  /// type.
  static ChatAttachmentKind classify(AttachmentType source, String mimeType) {
    if (source == AttachmentType.gallery || source == AttachmentType.camera) {
      return ChatAttachmentKind.image;
    }
    if (source == AttachmentType.document) {
      return ChatAttachmentKind.pdf;
    }
    if (mimeType.startsWith('image/')) return ChatAttachmentKind.image;
    if (mimeType == 'application/pdf') return ChatAttachmentKind.pdf;
    return ChatAttachmentKind.file;
  }

  /// Best-effort mime type lookup by file name/extension.
  static String detectMimeType(String path) {
    return lookupMimeType(path) ?? 'application/octet-stream';
  }

  /// Reads, validates, and (per-kind) prepares [result] for both display
  /// in chat history and sending to Gemini.
  ///
  /// Throws [AttachmentException] — with a message safe to show directly
  /// to the user — if the file can't be read, is empty, is an unsupported
  /// type, is too large to send safely, or (for PDFs) has no extractable
  /// text. Never throws anything else; every failure path funnels through
  /// this one exception type so the caller has a single `catch` to handle.
  static Future<ProcessedAttachment> process(
    AttachmentResult result,
    AttachmentType source,
  ) async {
    final file = File(result.path);
    if (!await file.exists()) {
      throw AttachmentException('That file could no longer be found.');
    }

    final originalMimeType = detectMimeType(result.path);
    final kind = classify(source, originalMimeType);

    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw AttachmentException('Could not read "${result.name}".');
    }

    if (bytes.isEmpty) {
      throw AttachmentException('"${result.name}" is empty.');
    }

    if (bytes.lengthInBytes > _maxRawBytes) {
      throw AttachmentException(
        '"${result.name}" is too large to send (${_formatBytes(bytes.lengthInBytes)}, '
        'max ${_formatBytes(_maxRawBytes)}). Try a smaller file.',
      );
    }

    switch (kind) {
      case ChatAttachmentKind.image:
        return _processImage(result, bytes);
      case ChatAttachmentKind.pdf:
        return _processPdf(result, bytes);
      case ChatAttachmentKind.file:
        return _processGenericFile(result, bytes, originalMimeType);
    }
  }

  /// Compresses and inline-encodes an image attachment. Compression is
  /// CPU-bound and can be slow for large photos, so it runs off the UI
  /// isolate via `compute` to keep the chat responsive.
  static Future<ProcessedAttachment> _processImage(
    AttachmentResult result,
    Uint8List bytes,
  ) async {
    final compressed = await compute(_compressImage, bytes);
    if (compressed == null) {
      throw AttachmentException(
        'Could not process "${result.name}" as an image — it may be '
        'corrupted or in an unsupported format.',
      );
    }

    const mimeType = 'image/jpeg'; // normalized regardless of source format
    final metadata = ChatAttachment(
      name: result.name,
      mimeType: mimeType,
      sizeBytes: compressed.lengthInBytes,
      kind: ChatAttachmentKind.image,
      path: result.path,
    );
    final part = GeminiInlinePart(
      mimeType: mimeType,
      base64Data: base64Encode(compressed),
    );
    return ProcessedAttachment(metadata: metadata, part: part);
  }

  /// Extracts text from a PDF attachment (in a background isolate, in
  /// page batches — see [_extractPdfText]) and returns it as
  /// [ProcessedAttachment.extractedText] instead of a binary [part]. The
  /// caller is expected to fold this text directly into the prompt sent
  /// to Gemini for the current turn only.
  static Future<ProcessedAttachment> _processPdf(
    AttachmentResult result,
    Uint8List bytes,
  ) async {
    Map<String, dynamic> outcome;
    try {
      outcome = await compute(_extractPdfText, bytes);
    } catch (_) {
      // The extraction isolate itself failed to run — never let this
      // crash the app; surface it as an ordinary attachment failure.
      throw AttachmentException(
        'Could not read "${result.name}" as a PDF.',
      );
    }

    final error = outcome['error'] as String?;
    if (error != null) {
      throw AttachmentException(error);
    }

    final text = (outcome['text'] as String? ?? '').trim();
    if (text.isEmpty) {
      throw AttachmentException(
        '"${result.name}" has no readable text — it may be a scanned or '
        'image-only PDF.',
      );
    }

    final truncated = outcome['truncated'] as bool? ?? false;
    final pageCount = outcome['pageCount'] as int? ?? 0;

    final metadata = ChatAttachment(
      name: result.name,
      mimeType: 'application/pdf',
      sizeBytes: bytes.lengthInBytes,
      kind: ChatAttachmentKind.pdf,
      path: result.path,
    );

    final buffer = StringBuffer()
      ..writeln(
        '--- Content extracted from PDF "${result.name}"'
        '${pageCount > 0 ? ' ($pageCount page${pageCount == 1 ? '' : 's'})' : ''} ---',
      )
      ..writeln(text);
    if (truncated) {
      buffer.writeln(
        '\n[Note: this PDF is long — only the first ~$_maxPdfTextChars '
        'characters of extracted text were included.]',
      );
    }
    buffer.writeln('--- End of PDF content ---');

    return ProcessedAttachment(
      metadata: metadata,
      extractedText: buffer.toString(),
    );
  }

  /// Inline-encodes a generic (non-image, non-PDF) file, after checking
  /// its mime type against [_supportedGenericMimeTypes]. Anything not on
  /// that list is rejected up front with a clear message.
  static ProcessedAttachment _processGenericFile(
    AttachmentResult result,
    Uint8List bytes,
    String mimeType,
  ) {
    if (!_supportedGenericMimeTypes.contains(mimeType)) {
      throw AttachmentException(
        'Unsupported file type. Pak AI can read images, PDFs, and plain '
        'text files (.txt, .csv, .md, .html, .json) — try one of those.',
      );
    }

    final metadata = ChatAttachment(
      name: result.name,
      mimeType: mimeType,
      sizeBytes: bytes.lengthInBytes,
      kind: ChatAttachmentKind.file,
      path: result.path,
    );
    final part = GeminiInlinePart(
      mimeType: mimeType,
      base64Data: base64Encode(bytes),
    );
    return ProcessedAttachment(metadata: metadata, part: part);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Top-level so it can run in a background isolate via `compute`.
///
/// Downscales to [AttachmentProcessorService._maxImageDimension] on the
/// longest edge (no-op if already smaller), then re-encodes as JPEG,
/// stepping quality down until under the target size or the quality floor
/// is hit — preserving as much quality as possible while keeping requests
/// fast and reliable. Returns `null` if the bytes aren't a decodable image.
Uint8List? _compressImage(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  img.Image working = decoded;
  final longestEdge =
      working.width > working.height ? working.width : working.height;
  if (longestEdge > AttachmentProcessorService._maxImageDimension) {
    working = working.width >= working.height
        ? img.copyResize(working,
            width: AttachmentProcessorService._maxImageDimension)
        : img.copyResize(working,
            height: AttachmentProcessorService._maxImageDimension);
  }

  const qualitySteps = [90, 80, 65, 50];
  Uint8List? best;
  for (final quality in qualitySteps) {
    final encoded = img.encodeJpg(working, quality: quality);
    best = encoded;
    if (encoded.lengthInBytes <= AttachmentProcessorService._targetImageBytes) {
      return encoded;
    }
  }
  // Every step tried; return the smallest (last/lowest-quality) attempt.
  return best;
}

/// Top-level so it can run in a background isolate via `compute`.
///
/// Decoding and extracting text from a PDF is CPU-heavy and would
/// otherwise freeze the chat UI for anything but the smallest documents.
/// Text is pulled out page-by-page in batches so a very long document
/// never has to be fully materialized as text in memory in one shot, and
/// extraction stops as soon as
/// [AttachmentProcessorService._maxPdfTextChars] is reached rather than
/// reading every remaining page for nothing.
///
/// Always returns a plain, isolate-safe `Map` — never throws a custom
/// exception type across the isolate boundary (a raw `Map` guarantees
/// clean message-passing regardless of Dart/Flutter version). On success
/// it holds `'text'` (and optionally `'truncated'`/`'pageCount'`); on
/// failure it holds an `'error'` message ready to show the user as-is.
/// This function itself can never crash the app — every failure mode
/// (corrupt file, encrypted PDF, a single unreadable page, an empty
/// document) is caught and turned into that `'error'` entry instead.
Map<String, dynamic> _extractPdfText(Uint8List bytes) {
  PdfDocument? document;
  try {
    document = PdfDocument(inputBytes: bytes);
    final pageCount = document.pages.count;
    if (pageCount <= 0) {
      return {'error': 'This PDF has no pages to read.'};
    }

    final extractor = PdfTextExtractor(document);
    final buffer = StringBuffer();
    const batchSize = 20;
    bool truncated = false;

    for (int start = 0; start < pageCount; start += batchSize) {
      final end = (start + batchSize - 1) < pageCount
          ? start + batchSize - 1
          : pageCount - 1;
      String chunk;
      try {
        chunk = extractor.extractText(startPageIndex: start, endPageIndex: end);
      } catch (_) {
        // A single unreadable batch (e.g. one malformed page) shouldn't
        // sink the whole document — skip it and keep going.
        continue;
      }
      final trimmedChunk = chunk.trim();
      if (trimmedChunk.isNotEmpty) {
        buffer.writeln(trimmedChunk);
      }
      if (buffer.length >= AttachmentProcessorService._maxPdfTextChars) {
        truncated = true;
        break;
      }
    }

    var text = buffer.toString();
    if (text.length > AttachmentProcessorService._maxPdfTextChars) {
      text = text.substring(0, AttachmentProcessorService._maxPdfTextChars);
      truncated = true;
    }

    return {'text': text, 'truncated': truncated, 'pageCount': pageCount};
  } catch (_) {
    return {
      'error': 'Could not read this PDF — it may be corrupted, '
          'password-protected, or in an unsupported format.',
    };
  } finally {
    try {
      document?.dispose();
    } catch (_) {
      // Best-effort cleanup only — nothing more we can safely do here.
    }
  }
}
