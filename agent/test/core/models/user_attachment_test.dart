import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:test/test.dart';

UserAttachment attachment({
  String id = 'attachment-1',
  String safeName = 'diagram.png',
  String mimeType = 'image/png',
  int sizeBytes = 42,
  String? sha256,
  UserAttachmentKind kind = UserAttachmentKind.image,
  String agentLocalReference = '/agent-owned/opaque-1',
  String mediaId = 'media-1',
  UserAttachmentStatus status = UserAttachmentStatus.available,
}) => UserAttachment(
  id: id,
  safeName: safeName,
  mimeType: mimeType,
  sizeBytes: sizeBytes,
  sha256: sha256 ?? 'a' * 64,
  kind: kind,
  agentLocalReference: agentLocalReference,
  mediaId: mediaId,
  status: status,
);

void main() {
  group('UserAttachment', () {
    test('durable JSON round trip preserves every closed field', () {
      final original = attachment();

      final restored = UserAttachment.fromJson(original.toJson());

      expect(restored.toJson(), original.toJson());
      expect(restored.schemaVersion, userAttachmentSchemaVersion);
    });

    test('public projection omits only the Agent-local reference', () {
      final original = attachment();

      final public = original.toPublicJson();

      expect(public.keys, isNot(contains('agentLocalReference')));
      expect(public, containsPair('id', original.id));
      expect(public, containsPair('mediaId', original.mediaId));
      expect(public, containsPair('sha256', original.sha256));
      expect(() => public['extra'] = true, throwsUnsupportedError);
    });

    test('rejects unknown fields and malformed closed values', () {
      final valid = attachment().toJson();
      expect(
        () => UserAttachment.fromJson({...valid, 'bytes': 'forbidden'}),
        throwsFormatException,
      );

      for (final mutation in <Map<String, dynamic>>[
        {...valid, 'schemaVersion': 2},
        {...valid, 'id': '../attachment'},
        {...valid, 'safeName': '../diagram.png'},
        {...valid, 'mimeType': 'IMAGE/PNG'},
        {...valid, 'sizeBytes': -1},
        {...valid, 'sha256': 'not-a-hash'},
        {...valid, 'kind': 'file'},
        {...valid, 'agentLocalReference': 'https://example.test/file'},
        {...valid, 'mediaId': ''},
        {...valid, 'status': 'uploading'},
      ]) {
        expect(
          () => UserAttachment.fromJson(mutation),
          throwsFormatException,
          reason: '$mutation',
        );
      }
    });
  });

  group('UserAttachmentPolicy', () {
    UserAttachment sized(int bytes, int index, {bool image = false}) =>
        attachment(
          id: 'attachment-$index',
          safeName: image ? 'image-$index.png' : 'file-$index.bin',
          mimeType: image ? 'image/png' : 'application/octet-stream',
          sizeBytes: bytes,
          sha256: index.toRadixString(16).padLeft(64, '0'),
          kind: image ? UserAttachmentKind.image : UserAttachmentKind.file,
          agentLocalReference: '/agent-owned/item-$index',
          mediaId: 'media-$index',
        );

    test('accepts per-file boundary-1 and boundary for every kind', () {
      for (final candidate in [
        sized(UserAttachmentPolicy.maxFileBytes - 1, 1),
        sized(UserAttachmentPolicy.maxFileBytes, 2, image: true),
      ]) {
        expect(
          UserAttachmentPolicy.validate([candidate]),
          isA<AttachmentAdmissionSuccess>(),
        );
      }
    });

    test('rejects per-file boundary+1 regardless of MIME', () {
      for (final candidate in [
        sized(UserAttachmentPolicy.maxFileBytes + 1, 3),
        sized(UserAttachmentPolicy.maxFileBytes + 1, 4, image: true),
      ]) {
        final result = UserAttachmentPolicy.validate([candidate]);
        expect(result, isA<AttachmentAdmissionFailure>());
        expect(
          (result as AttachmentAdmissionFailure).code,
          AttachmentAdmissionErrorCode.fileTooLarge,
        );
      }
    });

    test('enforces count and aggregate boundaries deterministically', () {
      final four = [
        for (var index = 0; index < 4; index++)
          sized(UserAttachmentPolicy.maxFileBytes, index + 10),
      ];
      expect(
        UserAttachmentPolicy.validate(four),
        isA<AttachmentAdmissionSuccess>(),
      );

      final fifth = sized(0, 20);
      final countFailure = UserAttachmentPolicy.validate([...four, fifth]);
      expect(
        (countFailure as AttachmentAdmissionFailure).code,
        AttachmentAdmissionErrorCode.tooManyFiles,
      );

      final aboveAggregate = [...four];
      aboveAggregate[3] = sized(UserAttachmentPolicy.maxFileBytes + 1, 13);
      final aggregateFailure = UserAttachmentPolicy.validate(aboveAggregate);
      expect(aggregateFailure, isA<AttachmentAdmissionFailure>());
    });

    test('public list projection is ordered, immutable, and path-free', () {
      final projected = UserAttachmentPolicy.publicProjection([
        attachment(),
        attachment(id: 'attachment-2', mediaId: 'media-2', sha256: 'b' * 64),
      ]);
      final serialized = projected.toString();

      expect(projected.map((item) => item['id']), [
        'attachment-1',
        'attachment-2',
      ]);
      expect(serialized, isNot(contains('agentLocalReference')));
      expect(serialized, isNot(contains('/agent-owned/')));
      expect(serialized, isNot(contains('base64')));
      expect(() => projected.clear(), throwsUnsupportedError);
    });

    test('maps malformed untrusted metadata to one safe error code', () {
      final result = UserAttachmentPolicy.parseAndValidate([
        {...attachment().toJson(), 'bytes': 'not-allowed'},
      ]);

      expect(result, isA<AttachmentAdmissionFailure>());
      expect(
        (result as AttachmentAdmissionFailure).code,
        AttachmentAdmissionErrorCode.invalidMetadata,
      );
      expect(result.message, 'Attachment metadata is invalid.');
    });
  });

  group('Message attachments', () {
    test('user JSON preserves attachment order and immutable association', () {
      final first = attachment();
      final second = attachment(
        id: 'attachment-2',
        safeName: 'notes.txt',
        mimeType: 'text/plain',
        kind: UserAttachmentKind.file,
        agentLocalReference: r'C:\agent-owned\opaque-2',
        mediaId: 'media-2',
        sha256: 'b' * 64,
      );
      final source = [first, second];
      final message = Message(
        role: MessageRole.user,
        content: 'Review these in order.',
        attachments: source,
      );
      source.clear();

      final restored = Message.fromJson(message.toJson());

      expect(restored.attachments.map((item) => item.id), [
        'attachment-1',
        'attachment-2',
      ]);
      expect(() => restored.attachments.clear(), throwsUnsupportedError);
      expect(restored.content, 'Review these in order.');
    });

    test('rejects attachments on every non-user role', () {
      for (final role in [
        MessageRole.system,
        MessageRole.assistant,
        MessageRole.tool,
      ]) {
        expect(
          () => Message(
            role: role,
            content: 'invalid',
            attachments: [attachment()],
          ),
          throwsArgumentError,
        );
      }
    });

    test('legacy JSON without attachments remains readable', () {
      final legacy = Message.fromJson({
        'role': 'user',
        'content': 'legacy message',
        'finishReason': 'unknown',
      });

      expect(legacy.attachments, isEmpty);
      expect(legacy.content, 'legacy message');
    });
  });
}
