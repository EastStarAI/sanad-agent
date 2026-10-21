import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import '../../core/di.dart';
import '../../core/models/user_attachment.dart';
import '../../evolution/attachments/attachment_store.dart';

/// Partitioned user message attachments separating provider-safe image attachments
/// from non-image or unsafe-format file attachments requiring wire disclosure.
final class UserAttachmentPartition {
  const UserAttachmentPartition({
    required this.safeImages,
    required this.disclosedFiles,
  });

  /// Attachments eligible for wire image parts (PNG, JPEG, WebP, GIF).
  final List<UserAttachment> safeImages;

  /// Attachments that must be disclosed as file references and never projected
  /// as image parts on the wire (non-images or non-provider-safe image formats).
  final List<UserAttachment> disclosedFiles;

  bool get hasSafeImages => safeImages.isNotEmpty;
  bool get hasDisclosedFiles => disclosedFiles.isNotEmpty;
}

/// Shared wire discloser ensuring non-image (and non-provider-safe-image) user attachments
/// are disclosed to the model wire with agent-side store references and tool guidance,
/// without leaking client-side filesystem paths or transmitting unsupported image formats.
abstract final class UserAttachmentWireDiscloser {
  /// Provider-safe image MIME types admissible as wire image parts (e.g. image_url, input_image, images).
  /// Any other image MIME (e.g. image/heic, image/tiff, image/svg+xml) must be disclosed as a file
  /// reference and never projected as an image part.
  static const Set<String> providerSafeImageMimes = {
    'image/png',
    'image/jpeg',
    'image/webp',
    'image/gif',
  };

  /// Fixed English guidance sentence appended to disclosed file references.
  static const String guidanceSentence =
      'Use your tools to read this file; it is available on disk.';

  /// Maximum length for sanitized safe names in wire reference links.
  static const int maxSafeNameLength = 120;

  /// Whether [attachment] has a MIME type supported as a direct provider image part.
  ///
  /// The set is deliberately exact: anything else (including image aliases such
  /// as `image/jpg`, `image/heic`, `image/tiff` or `image/svg+xml`) is disclosed
  /// as a file reference and never projected as an image part.
  static bool isProviderSafeImage(UserAttachment attachment) =>
      providerSafeImageMimes.contains(attachment.mimeType.toLowerCase());

  /// Sanitizes a file basename for embedding in markdown links (`[<safe name>](...)`),
  /// removing every line break, control rune, backtick, and bracket character
  /// that could break or inject into the reference line.
  static String sanitizeSafeName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]'), '')
        .replaceAll('[', '_')
        .replaceAll(']', '_')
        .replaceAll('`', '_')
        .trim();
    final safe = cleaned.isEmpty ? 'attachment' : cleaned;
    return String.fromCharCodes(safe.runes.take(maxSafeNameLength));
  }

  /// Resolves the absolute on-disk path for [attachment] inside the agent-side
  /// attachment store without reading any bytes.
  ///
  /// A store-owned attachment resolves through the store jail. When no store is
  /// available, the canonical `<state home>/attachments/<id>/payload` layout is
  /// derived from the opaque attachment id only. A foreign absolute or
  /// client-side reference is therefore never echoed; the result is either an
  /// agent-side store path or null.
  static String? resolveAgentAttachmentPath(
    UserAttachment attachment, {
    AttachmentStore? attachmentStore,
  }) {
    final store =
        attachmentStore ??
        (getIt.isRegistered<AttachmentStore>()
            ? getIt<AttachmentStore>()
            : null);
    if (store != null) {
      return store.resolveAttachmentPath(attachment);
    }
    final root = p.normalize(
      p.join(getSanadStateHome(), AttachmentStore.storageDirectoryName),
    );
    final canonical = p.normalize(
      p.join(root, attachment.id, AttachmentStore.payloadFileName),
    );
    return p.isWithin(root, canonical) ? canonical : null;
  }

  /// Formats a single file disclosure reference line:
  /// `[<safe name>](file:///<agent-side absolute path>)`.
  ///
  /// The destination is a percent-encoded `file://` URI, so spaces and
  /// non-ASCII path segments cannot break the link. Returns null when no
  /// agent-side store path can be derived for [attachment]; callers must then
  /// omit the line instead of projecting an external path.
  static String? formatReferenceLine(
    UserAttachment attachment, {
    AttachmentStore? attachmentStore,
  }) {
    final path = resolveAgentAttachmentPath(
      attachment,
      attachmentStore: attachmentStore,
    );
    if (path == null) return null;
    final safeName = sanitizeSafeName(attachment.safeName);
    return '[$safeName](${Uri.file(path)})';
  }

  /// Partitions [attachments] into provider-safe images and disclosed files.
  static UserAttachmentPartition partition(
    Iterable<UserAttachment> attachments,
  ) {
    final safeImages = <UserAttachment>[];
    final disclosedFiles = <UserAttachment>[];

    for (final att in attachments) {
      if (isProviderSafeImage(att)) {
        safeImages.add(att);
      } else {
        disclosedFiles.add(att);
      }
    }

    return UserAttachmentPartition(
      safeImages: List.unmodifiable(safeImages),
      disclosedFiles: List.unmodifiable(disclosedFiles),
    );
  }

  /// Appends disclosure reference lines and the fixed guidance sentence to the
  /// user message content for any [nonSafeAttachments].
  ///
  /// If [nonSafeAttachments] is empty, returns [originalContent] or an empty string.
  static String discloseContent({
    required String? originalContent,
    required List<UserAttachment> nonSafeAttachments,
    AttachmentStore? attachmentStore,
  }) {
    if (nonSafeAttachments.isEmpty) {
      return originalContent ?? '';
    }

    final referenceLines = nonSafeAttachments
        .map(
          (att) => formatReferenceLine(att, attachmentStore: attachmentStore),
        )
        .whereType<String>()
        .toList(growable: false);

    // Never emit guidance for a reference that could not be resolved to an
    // agent-side store path.
    if (referenceLines.isEmpty) {
      return originalContent ?? '';
    }

    final buffer = StringBuffer();
    final trimmedContent = originalContent?.trim();
    if (trimmedContent != null && trimmedContent.isNotEmpty) {
      buffer.writeln(trimmedContent);
      buffer.writeln();
    }
    for (final line in referenceLines) {
      buffer.writeln(line);
    }
    buffer.writeln();
    buffer.write(guidanceSentence);

    return buffer.toString().trim();
  }
}
