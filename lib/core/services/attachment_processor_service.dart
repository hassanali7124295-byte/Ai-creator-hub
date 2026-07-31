import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:mime/mime.dart';
import 'package:image/image.dart' as img;

import '../../models/chat_attachment.dart';
import 'attachment_service.dart';
import 'gemini_service.dart';

/// Thrown when an attachment can't be safely prepared for sending —
/// e.g. it's unreadable, or too large even after compression.
class AttachmentException implements Exception {
  final String message;
  AttachmentException(this.message);

  @override
  String toString() => message;
}

/// The outcome of processing a picked attachment: metadata to store on the
/// [ChatMessage] plus the base64 payload ready to hand to [GeminiService].
class ProcessedAttachment {
  final ChatAttachment metadata;
  final GeminiInlinePart part;
  const ProcessedAttachment({required this.metadata, required this.part});
}

/// Turns a raw [AttachmentResult] from the picker into something that can
/// actually be sent to Gemini and stored in chat history.
///
/// This is the one place that knows how to handle each [ChatAttachmentKind].
/// Adding a new kind later (e.g. audio) means adding one branch here —
/// nothing else in the attachment pipeline needs to change.
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

  /// Reads, (if an image) compresses, and base64-encodes [result], ready
  /// to attach to a chat message and send to Gemini.
  ///
  /// Throws [AttachmentException] if the file can't be read or is too
  /// large to send safely.
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
    String mimeType;

    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      throw AttachmentException('Could not read "${result.name}".');
    }

    if (kind == ChatAttachmentKind.image) {
      // Compression is CPU-bound and can be slow for large photos, so it
      // runs off the UI isolate via `compute` to keep the chat responsive.
      final compressed = await compute(_compressImage, bytes);
      if (compressed == null) {
        throw AttachmentException(
          'Could not process "${result.name}" as an image.',
        );
      }
      bytes = compressed;
      mimeType = 'image/jpeg'; // normalized regardless of source format
    } else {
      mimeType = originalMimeType;
    }

    if (bytes.lengthInBytes > _maxRawBytes) {
      throw AttachmentException(
        '"${result.name}" is too large to send (${_formatBytes(bytes.lengthInBytes)}). '
        'Try a smaller file.',
      );
    }

    final metadata = ChatAttachment(
      name: result.name,
      mimeType: mimeType,
      sizeBytes: bytes.lengthInBytes,
      kind: kind,
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
