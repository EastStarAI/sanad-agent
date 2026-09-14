import 'dart:typed_data';

import '../../core/models/tool_execution_result.dart';

abstract final class ImagePolicy {
  static const int maxInputBytes = 20 * 1024 * 1024;
  static const int maxDecodedPixels = 40000000;
  static const int maxEdge = 7900;
  static const int maxBase64Chars = 4 * 1024 * 1024;
  static const int maxConcurrency = 2;
  static const Duration processingTimeout = Duration(seconds: 15);
  static const int jpegQuality = 85;
  static const int pngCompression = 6;

  static int detailMaxEdge(ToolImageDetail detail) => switch (detail) {
    ToolImageDetail.low => 768,
    ToolImageDetail.auto => 2048,
    ToolImageDetail.high => 4096,
    ToolImageDetail.original => maxEdge,
  };

  static int base64LengthForBytes(int byteLength) =>
      ((byteLength + 2) ~/ 3) * 4;

  static bool isInputWithinLimit(int byteLength) =>
      byteLength >= 0 && byteLength <= maxInputBytes;

  static bool isBase64WithinLimitForBytes(int byteLength) =>
      byteLength >= 0 && base64LengthForBytes(byteLength) <= maxBase64Chars;

  static bool isPixelCountWithinLimit(int pixelCount) =>
      pixelCount > 0 && pixelCount <= maxDecodedPixels;

  static bool areDimensionsWithinLimits(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width <= maxEdge &&
      height <= maxEdge &&
      isPixelCountWithinLimit(width * height);

  static String? sniffMimeType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }
}

sealed class ImagePolicyResult {
  const ImagePolicyResult();
}

final class ImagePolicySuccess extends ImagePolicyResult {
  const ImagePolicySuccess({
    required this.bytes,
    required this.mimeType,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mimeType;
  final int width;
  final int height;
}

final class ImagePolicyFailure extends ImagePolicyResult {
  const ImagePolicyFailure({required this.code, required this.message});

  final ToolResultErrorCode code;
  final String message;
}
