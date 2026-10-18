import 'dart:convert';

import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:test/test.dart';

void main() {
  group('ToolExecutionResult', () {
    test('text result preserves text and derives its display projection', () {
      const text = 'first line\nsecond line';

      final result = ToolExecutionResult.text(text);

      expect(result.schemaVersion, toolExecutionResultSchemaVersion);
      expect(result.blocks, hasLength(1));
      expect(result.displayText, text);
      expect(result.isError, isFalse);
      expect(result.errorCode, isNull);
    });

    test('mixed blocks round trip in order with closed wire values', () {
      final result = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'inspect pixels'),
          ToolImageBlock(
            dataBase64: base64.encode(const [0, 1, 2, 3]),
            mimeType: 'image/png',
            width: 2,
            height: 2,
            detail: ToolImageDetail.original,
          ),
          ToolTextBlock(text: 'done'),
        ],
        isError: true,
        errorCode: ToolResultErrorCode.processingFailed,
      );

      final json = result.toJson();
      final restored = ToolExecutionResult.fromJson(json);

      expect(json['schemaVersion'], 1);
      expect(json['errorCode'], 'processing_failed');
      expect((json['blocks'] as List).map((block) => block['type']), [
        'text',
        'image',
        'text',
      ]);
      expect(restored.blocks[0], isA<ToolTextBlock>());
      expect(restored.blocks[1], isA<ToolImageBlock>());
      expect(restored.blocks[2], isA<ToolTextBlock>());
      expect(restored.displayText, 'inspect pixels\ndone');
      expect(restored.errorCode, ToolResultErrorCode.processingFailed);
    });

    test('blocks cannot be mutated after construction', () {
      final source = <ToolResultBlock>[ToolTextBlock(text: 'stable')];
      final result = ToolExecutionResult(blocks: source);
      source.add(ToolTextBlock(text: 'late mutation'));

      expect(result.displayText, 'stable');
      expect(
        () => result.blocks.add(ToolTextBlock(text: 'mutation')),
        throwsUnsupportedError,
      );
    });

    test('requires a non-empty text block', () {
      expect(() => ToolTextBlock(text: '  '), throwsArgumentError);
      expect(
        () => ToolExecutionResult(
          blocks: [
            ToolImageBlock(
              dataBase64: base64.encode(const [1]),
              mimeType: 'image/jpeg',
              width: 1,
              height: 1,
              detail: ToolImageDetail.auto,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('rejects unsupported schema, block, detail, and error values', () {
      final base = ToolExecutionResult.text('valid').toJson();

      expect(
        () => ToolExecutionResult.fromJson({...base, 'schemaVersion': 2}),
        throwsFormatException,
      );
      expect(
        () => ToolExecutionResult.fromJson({
          ...base,
          'blocks': [
            {'type': 'audio', 'data': 'AA=='},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => ToolExecutionResult.fromJson({
          ...base,
          'blocks': [
            {'type': 'text', 'text': 'valid'},
            {
              'type': 'image',
              'dataBase64': 'AA==',
              'mimeType': 'image/png',
              'width': 1,
              'height': 1,
              'detail': 'future',
            },
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => ToolExecutionResult.fromJson({
          ...base,
          'isError': true,
          'errorCode': 'future_error',
        }),
        throwsFormatException,
      );
    });

    test('rejects malformed image metadata and payloads', () {
      ToolImageBlock create({
        String dataBase64 = 'AA==',
        String mimeType = 'image/webp',
        int width = 1,
        int height = 1,
      }) {
        return ToolImageBlock(
          dataBase64: dataBase64,
          mimeType: mimeType,
          width: width,
          height: height,
          detail: ToolImageDetail.high,
        );
      }

      expect(() => create(dataBase64: ''), throwsArgumentError);
      expect(() => create(dataBase64: 'not base64'), throwsArgumentError);
      expect(() => create(dataBase64: 'AB=='), throwsArgumentError);
      expect(() => create(mimeType: 'image/gif'), throwsArgumentError);
      expect(() => create(width: 0), throwsArgumentError);
      expect(() => create(height: -1), throwsArgumentError);
    });

    test('error code is valid only for an error result', () {
      expect(
        () => ToolExecutionResult.text(
          'not an error',
          errorCode: ToolResultErrorCode.executionFailed,
        ),
        throwsArgumentError,
      );
      expect(
        ToolExecutionResult.text(
          'failed',
          isError: true,
          errorCode: ToolResultErrorCode.executionFailed,
        ).toJson()['errorCode'],
        'execution_failed',
      );
    });
  });
}
