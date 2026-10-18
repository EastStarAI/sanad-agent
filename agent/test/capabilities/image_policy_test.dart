import 'dart:typed_data';

import 'package:sanad_agent/capabilities/image/image_policy.dart';
import 'package:test/test.dart';

void main() {
  group('ImagePolicy', () {
    test('locks numeric boundaries and base64 edge arithmetic', () {
      expect(ImagePolicy.maxInputBytes, 20 * 1024 * 1024);
      expect(ImagePolicy.maxDecodedPixels, 40000000);
      expect(ImagePolicy.maxEdge, 7900);
      expect(ImagePolicy.maxBase64Chars, 4 * 1024 * 1024);
      expect(ImagePolicy.maxConcurrency, 2);
      expect(ImagePolicy.processingTimeout, const Duration(seconds: 15));

      expect(
        ImagePolicy.isInputWithinLimit(ImagePolicy.maxInputBytes - 1),
        isTrue,
      );
      expect(ImagePolicy.isInputWithinLimit(ImagePolicy.maxInputBytes), isTrue);
      expect(
        ImagePolicy.isInputWithinLimit(ImagePolicy.maxInputBytes + 1),
        isFalse,
      );
      expect(
        ImagePolicy.areDimensionsWithinLimits(ImagePolicy.maxEdge - 1, 1),
        isTrue,
      );
      expect(
        ImagePolicy.areDimensionsWithinLimits(ImagePolicy.maxEdge, 1),
        isTrue,
      );
      expect(
        ImagePolicy.areDimensionsWithinLimits(ImagePolicy.maxEdge + 1, 1),
        isFalse,
      );
      expect(
        ImagePolicy.isPixelCountWithinLimit(ImagePolicy.maxDecodedPixels - 1),
        isTrue,
      );
      expect(
        ImagePolicy.isPixelCountWithinLimit(ImagePolicy.maxDecodedPixels),
        isTrue,
      );
      expect(
        ImagePolicy.isPixelCountWithinLimit(ImagePolicy.maxDecodedPixels + 1),
        isFalse,
      );
      expect(ImagePolicy.areDimensionsWithinLimits(6250, 6400), isTrue);
      expect(ImagePolicy.areDimensionsWithinLimits(6250, 6401), isFalse);

      final maxBytes = (ImagePolicy.maxBase64Chars ~/ 4) * 3;
      expect(ImagePolicy.isBase64WithinLimitForBytes(maxBytes - 1), isTrue);
      expect(ImagePolicy.isBase64WithinLimitForBytes(maxBytes), isTrue);
      expect(ImagePolicy.isBase64WithinLimitForBytes(maxBytes + 1), isFalse);
      expect(
        ImagePolicy.base64LengthForBytes(maxBytes - 1),
        lessThanOrEqualTo(ImagePolicy.maxBase64Chars),
      );
      expect(
        ImagePolicy.base64LengthForBytes(maxBytes),
        ImagePolicy.maxBase64Chars,
      );
      expect(
        ImagePolicy.base64LengthForBytes(maxBytes + 1),
        greaterThan(ImagePolicy.maxBase64Chars),
      );
    });

    test('sniffs only PNG JPEG and WebP magic bytes', () {
      expect(
        ImagePolicy.sniffMimeType(
          Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        ),
        'image/png',
      );
      expect(
        ImagePolicy.sniffMimeType(Uint8List.fromList([0xff, 0xd8, 0xff])),
        'image/jpeg',
      );
      expect(
        ImagePolicy.sniffMimeType(Uint8List.fromList('RIFF1234WEBP'.codeUnits)),
        'image/webp',
      );
      expect(
        ImagePolicy.sniffMimeType(
          Uint8List.fromList('not an image.png'.codeUnits),
        ),
        isNull,
      );
    });
  });
}
