import 'package:sanad_agent/core/models/modality_declaration.dart';
import 'package:test/test.dart';

void main() {
  group('declaredModalityTokens', () {
    test('normalizes a non-empty string list', () {
      expect(declaredModalityTokens(['TEXT', 'image/JPEG']), {
        'text',
        'image/jpeg',
      });
      expect(declaredModalityTokens([' text ', ' image/webp ']), {
        'text',
        'image/webp',
      });
    });

    test('rejects malformed declarations', () {
      expect(declaredModalityTokens(null), isNull);
      expect(declaredModalityTokens('text'), isNull);
      expect(declaredModalityTokens(42), isNull);
      expect(declaredModalityTokens(<String, Object?>{}), isNull);
      expect(declaredModalityTokens(<Object?>[]), isNull);
      expect(declaredModalityTokens(['text', 42]), isNull);
      expect(declaredModalityTokens(['  ']), isNull);
      expect(declaredModalityTokens(['text', '']), isNull);
    });
  });

  group('declaresImageModality', () {
    test('recognizes the bare modality and every MIME subtype', () {
      for (final token in [
        'image',
        'IMAGE',
        ' image ',
        'image/jpeg',
        'image/png',
        'image/gif',
        'image/webp',
        'image/bmp',
        'image/svg+xml',
        'image/*',
      ]) {
        expect(declaresImageModality(token), isTrue, reason: token);
      }
    });

    test('does not recognize other modalities or near matches', () {
      for (final token in [
        'text',
        'vision',
        'pdf',
        'application/pdf',
        'audio/wav',
        'video/mp4',
        'file',
        '*',
        '*/*',
        'imagex',
        'x/image',
        '',
      ]) {
        expect(declaresImageModality(token), isFalse, reason: token);
      }
    });
  });

  group('declaresVisionOrImageModality', () {
    test('accepts the native vision name and MIME subtypes', () {
      expect(declaresVisionOrImageModality('vision'), isTrue);
      expect(declaresVisionOrImageModality('VISION'), isTrue);
      expect(declaresVisionOrImageModality('image/png'), isTrue);
      expect(declaresVisionOrImageModality('completion'), isFalse);
      expect(declaresVisionOrImageModality('tools'), isFalse);
    });
  });

  group('declaredImageModalitySupport', () {
    test('declares image input for bare and MIME-typed entries', () {
      expect(declaredImageModalitySupport(['text', 'image']), isTrue);
      expect(declaredImageModalitySupport(['text', 'image/webp']), isTrue);
      expect(declaredImageModalitySupport(['image/png']), isTrue);
      expect(declaredImageModalitySupport(['TEXT', 'IMAGE/JPEG']), isTrue);
    });

    test('declares text-only when no entry names image input', () {
      expect(declaredImageModalitySupport(['text']), isFalse);
      expect(
        declaredImageModalitySupport([
          'text',
          'application/pdf',
          'audio/wav',
          'video/mp4',
        ]),
        isFalse,
      );
      expect(declaredImageModalitySupport(['text', 'imagex']), isFalse);
    });

    test('establishes neither state for malformed declarations', () {
      expect(declaredImageModalitySupport(null), isNull);
      expect(declaredImageModalitySupport(<Object?>[]), isNull);
      expect(declaredImageModalitySupport(['text', 42]), isNull);
      expect(declaredImageModalitySupport(['  ', 'text']), isNull);
    });

    test('a modality wildcard is not image input and not text-only', () {
      expect(declaredImageModalitySupport(['*/*']), isNull);
      expect(declaredImageModalitySupport(['text', '*/*']), isNull);
      expect(declaredImageModalitySupport(['*']), isNull);
      expect(declaredImageModalitySupport(['text', '*/*', 'image']), isTrue);
    });
  });
}
