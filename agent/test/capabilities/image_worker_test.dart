import 'dart:async';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sanad_agent/capabilities/image/image_policy.dart';
import 'package:sanad_agent/capabilities/image/image_worker.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:test/test.dart';

void main() {
  group('ImageWorker', () {
    test('preserves verified original bytes, MIME, and dimensions', () async {
      final source = img.Image(width: 8, height: 4, numChannels: 3);
      img.fill(source, color: img.ColorRgb8(10, 20, 30));
      final bytes = img.encodeJpg(source, quality: 90);

      final result = await ImageWorker().process(
        bytes,
        detail: ToolImageDetail.original,
      );

      expect(result, isA<ImagePolicySuccess>());
      final success = result as ImagePolicySuccess;
      expect(success.bytes, bytes);
      expect(success.mimeType, 'image/jpeg');
      expect(success.width, 8);
      expect(success.height, 4);
    });

    test(
      'does not enlarge and normalizes resized opaque images to JPEG',
      () async {
        final small = img.Image(width: 16, height: 8, numChannels: 3);
        final smallBytes = img.encodePng(small);
        final unchanged =
            await ImageWorker().process(smallBytes, detail: ToolImageDetail.low)
                as ImagePolicySuccess;
        expect(unchanged.bytes, smallBytes);
        expect(unchanged.width, 16);

        final large = img.Image(width: 800, height: 400, numChannels: 3);
        img.fill(large, color: img.ColorRgb8(20, 40, 60));
        final resized =
            await ImageWorker().process(
                  img.encodePng(large),
                  detail: ToolImageDetail.low,
                )
                as ImagePolicySuccess;
        expect(resized.width, 768);
        expect(resized.height, 384);
        expect(resized.mimeType, 'image/jpeg');
      },
    );

    test('normalizes resized transparent images to PNG', () async {
      final source = img.Image(width: 800, height: 400, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(20, 40, 60, 120));

      final result =
          await ImageWorker().process(
                img.encodePng(source),
                detail: ToolImageDetail.low,
              )
              as ImagePolicySuccess;

      expect(result.mimeType, 'image/png');
      expect(result.width, 768);
      expect(result.height, 384);
    });

    test(
      'rejects empty, deceptive, oversized, over-edge, and animated input',
      () async {
        final worker = ImageWorker();
        expect(
          await worker.process(Uint8List(0), detail: ToolImageDetail.auto),
          isA<ImagePolicyFailure>().having(
            (failure) => failure.code,
            'code',
            ToolResultErrorCode.unsupportedFormat,
          ),
        );
        expect(
          await worker.process(
            Uint8List.fromList('fake.jpg'.codeUnits),
            detail: ToolImageDetail.auto,
          ),
          isA<ImagePolicyFailure>(),
        );

        final oversized = Uint8List(ImagePolicy.maxInputBytes + 1);
        oversized.setAll(0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
        expect(
          await worker.process(oversized, detail: ToolImageDetail.auto),
          isA<ImagePolicyFailure>().having(
            (failure) => failure.code,
            'code',
            ToolResultErrorCode.tooLarge,
          ),
        );

        final overEdge = img.Image(width: ImagePolicy.maxEdge + 1, height: 1);
        expect(
          await worker.process(
            img.encodePng(overEdge),
            detail: ToolImageDetail.auto,
          ),
          isA<ImagePolicyFailure>().having(
            (failure) => failure.code,
            'code',
            ToolResultErrorCode.tooLarge,
          ),
        );

        final animated = img.Image(width: 2, height: 2)..addFrame();
        expect(
          await worker.process(
            img.encodePng(animated),
            detail: ToolImageDetail.auto,
          ),
          isA<ImagePolicyFailure>().having(
            (failure) => failure.code,
            'code',
            ToolResultErrorCode.unsupportedFormat,
          ),
        );
      },
    );

    test(
      'runs off-loop and enforces killable timeout without artifacts',
      () async {
        final source = img.Image(width: 3000, height: 2000, numChannels: 4);
        img.fill(source, color: img.ColorRgba8(1, 2, 3, 100));
        final bytes = img.encodePng(source);
        var timerFired = false;
        Timer.run(() => timerFired = true);

        final result = await ImageWorker(
          timeout: Duration.zero,
        ).process(bytes, detail: ToolImageDetail.low);

        expect(timerFired, isTrue);
        expect(
          result,
          isA<ImagePolicyFailure>().having(
            (failure) => failure.code,
            'code',
            ToolResultErrorCode.timedOut,
          ),
        );
      },
    );

    test(
      'accepts four concurrent requests through the bounded worker pool',
      () async {
        final source = img.Image(width: 32, height: 32);
        final bytes = img.encodePng(source);
        final results = await Future.wait(
          List.generate(
            4,
            (_) =>
                ImageWorker().process(bytes, detail: ToolImageDetail.original),
          ),
        );
        expect(results, everyElement(isA<ImagePolicySuccess>()));
      },
    );
  });
}
