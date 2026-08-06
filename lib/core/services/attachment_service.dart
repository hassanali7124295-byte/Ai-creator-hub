import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

/// A file or image the user picked as a chat attachment.
///
/// This only captures the *selection* — actual AI processing of the
/// attached content (e.g. sending it to Gemini) is not implemented yet
/// and can be added in a later step.
class AttachmentResult {
  final String name;
  final String path;
  final int? sizeBytes;

  const AttachmentResult({
    required this.name,
    required this.path,
    this.sizeBytes,
  });
}

/// Thin wrapper around `image_picker` and `file_picker` so the Chat
/// screen has one simple, testable surface for picking attachments.
class AttachmentService {
  AttachmentService._();

  static final ImagePicker _imagePicker = ImagePicker();

  /// Pick a single image from the device gallery/photo library.
  static Future<AttachmentResult?> pickFromGallery() async {
    final XFile? file = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file == null) return null;
    return AttachmentResult(
      name: file.name,
      path: file.path,
      sizeBytes: await file.length(),
    );
  }

  /// Capture a new photo with the device camera.
  static Future<AttachmentResult?> pickFromCamera() async {
    final XFile? file = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (file == null) return null;
    return AttachmentResult(
      name: file.name,
      path: file.path,
      sizeBytes: await file.length(),
    );
  }

  /// Pick a single PDF document.
  static Future<AttachmentResult?> pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final picked = result?.files.isNotEmpty == true ? result!.files.first : null;
    if (picked == null || picked.path == null) return null;
    return AttachmentResult(
      name: picked.name,
      path: picked.path!,
      sizeBytes: picked.size,
    );
  }

  /// Pick any single file from device storage.
  static Future<AttachmentResult?> pickAnyFile() async {
    final result = await FilePicker.platform.pickFiles();
    final picked = result?.files.isNotEmpty == true ? result!.files.first : null;
    if (picked == null || picked.path == null) return null;
    return AttachmentResult(
      name: picked.name,
      path: picked.path!,
      sizeBytes: picked.size,
    );
  }

  // --- Step 22B: multi-select pickers -------------------------------------
  //
  // These mirror the single-pick methods above but return every item the
  // user selected, in the order `image_picker`/`file_picker` reports them
  // (i.e. selection order) so callers can preserve that order verbatim.

  /// Pick one or more images from the device gallery/photo library.
  static Future<List<AttachmentResult>> pickMultipleFromGallery() async {
    final List<XFile> files =
        await _imagePicker.pickMultiImage(imageQuality: 90);
    if (files.isEmpty) return const [];
    final results = <AttachmentResult>[];
    for (final file in files) {
      results.add(AttachmentResult(
        name: file.name,
        path: file.path,
        sizeBytes: await file.length(),
      ));
    }
    return results;
  }

  /// Pick one or more PDF documents.
  static Future<List<AttachmentResult>> pickMultipleDocuments() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      allowMultiple: true,
    );
    final picked = result?.files ?? const [];
    return picked
        .where((f) => f.path != null)
        .map((f) =>
            AttachmentResult(name: f.name, path: f.path!, sizeBytes: f.size))
        .toList();
  }

  /// Pick one or more files of any type from device storage.
  static Future<List<AttachmentResult>> pickMultipleFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final picked = result?.files ?? const [];
    return picked
        .where((f) => f.path != null)
        .map((f) =>
            AttachmentResult(name: f.name, path: f.path!, sizeBytes: f.size))
        .toList();
  }
}
