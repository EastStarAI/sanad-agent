import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'tool_execution_result.dart';

enum CanonicalMediaAvailability { available, unavailable }

/// Byte-free descriptor shared by internal completion callbacks and public
/// live/history projections. It never carries a source path or image payload.
class ViewImageMediaMetadata {
  const ViewImageMediaMetadata({
    required this.mediaId,
    required this.safeName,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.availability,
  });

  final String mediaId;
  final String safeName;
  final String mimeType;
  final int width;
  final int height;
  final CanonicalMediaAvailability availability;

  Map<String, dynamic> toPublicJson() => {
    'media_id': mediaId,
    'name': safeName,
    'mime_type': mimeType,
    'width': width,
    'height': height,
    'availability': availability.name,
  };

  static ViewImageMediaMetadata? fromPublicJson(Object? value) {
    if (value is! Map || value.keys.any((key) => !_publicKeys.contains(key))) {
      return null;
    }
    final id = value['media_id'];
    final name = value['name'];
    final mime = value['mime_type'];
    final width = value['width'];
    final height = value['height'];
    final availability = value['availability'];
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
        mime is! String ||
        !ToolImageBlock.supportedMimeTypes.contains(mime) ||
        name is! String ||
        name != _safeName(mime) ||
        width is! int ||
        width <= 0 ||
        height is! int ||
        height <= 0 ||
        (availability != 'available' && availability != 'unavailable')) {
      return null;
    }
    return ViewImageMediaMetadata(
      mediaId: id,
      safeName: name,
      mimeType: mime,
      width: width,
      height: height,
      availability: availability == 'available'
          ? CanonicalMediaAvailability.available
          : CanonicalMediaAvailability.unavailable,
    );
  }

  static const _publicKeys = {
    'media_id',
    'name',
    'mime_type',
    'width',
    'height',
    'availability',
  };
  static String _safeName(String mime) => switch (mime) {
    'image/jpeg' => 'view-image.jpg',
    'image/webp' => 'view-image.webp',
    _ => 'view-image.png',
  };

  /// Tools whose successful result may carry one projected image block and
  /// therefore publish canonical media metadata (`view_image` and the
  /// screenshot tool, which share the same media card and relay path).
  static const Set<String> mediaToolNames = {'view_image', 'system_screenshot'};

  /// Whether [toolName] is a media-bearing tool owned by this projection.
  static bool isMediaTool(String? toolName) =>
      toolName != null && mediaToolNames.contains(toolName);

  static ViewImageMediaMetadata? project({
    required String sessionId,
    required String? toolName,
    required String? toolCallId,
    required ToolExecutionResult? result,
  }) {
    if (!isMediaTool(toolName) ||
        toolCallId == null ||
        toolCallId.isEmpty ||
        result == null ||
        result.isError) {
      return null;
    }
    final index = result.blocks.indexWhere((block) => block is ToolImageBlock);
    final image = index < 0 ? null : result.blocks[index] as ToolImageBlock;
    RegExpMatch? summary;
    for (final block in result.blocks.whereType<ToolTextBlock>()) {
      summary = _summaryPattern.firstMatch(block.text);
      if (summary != null) break;
    }
    if (image == null && summary == null) return null;
    final mime = image?.mimeType ?? summary!.group(3)!;
    return ViewImageMediaMetadata(
      mediaId: sha256
          .convert(
            utf8.encode(
              '$sessionId\u0000$toolCallId\u0000${index < 0 ? 1 : index}',
            ),
          )
          .toString(),
      safeName: _safeName(mime),
      mimeType: mime,
      width: image?.width ?? int.parse(summary!.group(1)!),
      height: image?.height ?? int.parse(summary!.group(2)!),
      availability: image == null
          ? CanonicalMediaAvailability.unavailable
          : CanonicalMediaAvailability.available,
    );
  }

  static final _summaryPattern = RegExp(
    r'^Image loaded \(([1-9][0-9]*)×([1-9][0-9]*), (image/(?:png|jpeg|webp)),',
  );
}
