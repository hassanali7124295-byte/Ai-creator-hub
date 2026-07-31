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
}
