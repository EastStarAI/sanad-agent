import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/canonical_to_agent.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late AgentStateDatabase state;
  late AttachmentStore store;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-attachment-store-');
    state = AgentStateDatabase.inMemory();
    store = AttachmentStore(state, stateHome: home.path);
    await store.initialize();
    _insertSessionAndMessage(
      state,
      sessionId: 'session-a',
      messageId: 'message-a',
    );
    _insertSessionAndMessage(
      state,
      sessionId: 'session-b',
      messageId: 'message-b',
    );
  });

  tearDown(() async {
    state.dispose();
    if (await home.exists()) await home.delete(recursive: true);
  });

  test(
    'canonical think preserves ordered opaque IDs and rejects unsafe lists',
    () {
      final translated = CanonicalToAgent.translate({
        'command': 'think',
        'payload': {
          'session_id': 'session-a',
          'request_id': 'request-a',
          'message': 'inspect',
          'attachment_ids': ['attachment-a', 'attachment-b'],
        },
      }, 'local');
      expect(translated?.turnRequest?.metadata['attachment_ids'], [
        'attachment-a',
        'attachment-b',
      ]);
      for (final ids in [
        ['attachment-a', 'attachment-a'],
        ['../attachment-a'],
        [1],
        List<String>.filled(5, 'attachment'),
      ]) {
        expect(
          CanonicalToAgent.translate({
            'command': 'think',
            'payload': {
              'session_id': 'session-a',
              'request_id': 'request-a',
              'message': 'inspect',
              'attachment_ids': ids,
            },
          }, 'local'),
          isNull,
        );
      }
    },
  );

  test('capabilities publish versioned authoritative attachment limits', () {
    final capability =
        AgentCapabilities(displayName: 'test').toJson()['capabilities']
            as Map<String, dynamic>;
    expect(capability['attachment_media_v1'], {
      'version': 1,
      'ordered_references': true,
      'max_file_bytes': 5 * 1024 * 1024,
      'max_files_per_message': 4,
      'max_total_bytes_per_message': 20 * 1024 * 1024,
    });
  });

  test(
    'streams, inspects, hashes, promotes, and resolves exact-session grant',
    () async {
      final bytes = <int>[
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
        1,
        2,
        3,
      ];
      final upload = await store.create(
        fileName: r'../../C:\private\photo.exe',
        declaredMime: 'application/x-msdownload',
        expectedSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
      );
      await store.write(upload, bytes.sublist(0, 5));
      await store.write(upload, bytes.sublist(5));

      final attachment = await store.commit(
        upload,
        sessionId: 'session-a',
        admissionId: 'message-a',
      );

      expect(attachment.safeName, 'photo.exe');
      expect(attachment.mimeType, 'image/png');
      expect(attachment.kind.name, 'image');
      expect(attachment.agentLocalReference, isNot(contains(home.path)));
      _claim(
        store,
        sessionId: 'session-a',
        admissionId: 'message-a',
        messageId: 'message-a',
        attachmentId: attachment.id,
      );
      final path = await store.resolvePath(
        sessionId: 'session-a',
        attachmentId: attachment.id,
      );
      expect(await File(path).readAsBytes(), bytes);
      final providerProjection =
          await AgentRunner.projectUserAttachmentsForProvider(
            store: store,
            sessionId: 'session-a',
            messages: [
              Message(
                role: MessageRole.user,
                content: 'inspect this',
                attachments: [attachment],
              ),
            ],
          );
      expect(providerProjection.single.content, startsWith('inspect this\n\n'));
      expect(providerProjection.single.content, contains(path));
      expect(
        providerProjection.single.content,
        contains(
          'image inspection is not supported by the current model route',
        ),
      );
      expect(
        providerProjection.single.content,
        isNot(contains('Use view_image')),
      );
      expect(providerProjection.single.attachments, isEmpty);
      expect(
        providerProjection.single.toJson().toString(),
        isNot(contains('iVBOR')),
      );
      await expectLater(
        store.resolvePath(sessionId: 'session-b', attachmentId: attachment.id),
        throwsA(
          isA<AttachmentStoreException>().having(
            (error) => error.code,
            'code',
            AttachmentStoreErrorCode.unavailable,
          ),
        ),
      );

      if (!Platform.isWindows) {
        final result = Platform.isMacOS
            ? await Process.run('stat', ['-f', '%Lp', path])
            : await Process.run('stat', ['-c', '%a', path]);
        expect((result.stdout as String).trim(), '600');
      }
    },
  );

  test(
    'provider projection keeps non-image attachments on the message without a text projection',
    () async {
      final bytes = utf8.encode('%PDF-1.4 bounded file');
      final upload = await store.create(
        fileName: 'report.pdf',
        expectedSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
      );
      await store.write(upload, bytes);
      final attachment = await store.commit(
        upload,
        sessionId: 'session-a',
        admissionId: 'message-a',
      );
      _claim(
        store,
        sessionId: 'session-a',
        admissionId: 'message-a',
        messageId: 'message-a',
        attachmentId: attachment.id,
      );

      for (final supportsImageInput in [true, false]) {
        final projected = await AgentRunner.projectUserAttachmentsForProvider(
          store: store,
          sessionId: 'session-a',
          messages: [
            Message(
              role: MessageRole.user,
              content: 'read the report',
              attachments: [attachment],
            ),
          ],
          supportsImageInput: supportsImageInput,
        );

        expect(projected.single.content, 'read the report');
        expect(
          projected.single.content,
          isNot(contains('Agent-local attachments')),
          reason:
              'Wire disclosure owns the single reference projection; the '
              'provider history must not duplicate it as text.',
        );
        expect(projected.single.attachments, hasLength(1));
        expect(projected.single.attachments.single.id, attachment.id);
      }
    },
  );

  test(
    'rejects overflow and hash mismatch without a durable or partial file',
    () async {
      final oversized = await store.create(fileName: 'large.bin');
      await expectLater(
        store.write(oversized, List<int>.filled(5 * 1024 * 1024 + 1, 0)),
        throwsA(
          isA<AttachmentStoreException>().having(
            (error) => error.code,
            'code',
            AttachmentStoreErrorCode.fileTooLarge,
          ),
        ),
      );

      final mismatch = await store.create(
        fileName: 'hash.txt',
        expectedSha256: '0' * 64,
      );
      await store.write(mismatch, [1, 2, 3]);
      await expectLater(
        store.commit(
          mismatch,
          sessionId: 'session-a',
          admissionId: 'message-a',
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (error) => error.code,
            'code',
            AttachmentStoreErrorCode.hashMismatch,
          ),
        ),
      );

      final root = Directory(
        '${home.path}${Platform.pathSeparator}${AttachmentStore.storageDirectoryName}',
      );
      expect(
        root
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.part')),
        isEmpty,
      );
      expect(state.db.select('SELECT * FROM user_attachments'), isEmpty);
    },
  );

  test(
    'restart cleanup removes interrupted partials and unclaimed payloads',
    () async {
      final interrupted = await store.create(fileName: 'interrupted.txt');
      await store.write(interrupted, [1, 2, 3]);
      final stagedUpload = await store.create(fileName: 'retry.txt');
      await store.write(stagedUpload, 'retry'.codeUnits);
      final staged = await store.commit(
        stagedUpload,
        sessionId: 'session-a',
        admissionId: 'request-retry',
      );
      final orphan = Directory(
        '${home.path}${Platform.pathSeparator}attachments'
        '${Platform.pathSeparator}opaque-orphan',
      );
      await orphan.create(recursive: true);
      await File(
        '${orphan.path}${Platform.pathSeparator}payload',
      ).writeAsBytes([9]);

      final restarted = AttachmentStore(state, stateHome: home.path);
      await restarted.initialize();

      expect(orphan.existsSync(), isFalse);
      expect(
        () => restarted.loadAdmission(
          sessionId: 'session-a',
          admissionId: 'request-retry',
          attachmentIds: [staged.id],
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (error) => error.code,
            'code',
            AttachmentStoreErrorCode.ownershipMismatch,
          ),
        ),
      );
      expect(
        Directory(
          '${home.path}${Platform.pathSeparator}attachments'
          '${Platform.pathSeparator}${staged.id}',
        ).existsSync(),
        isFalse,
      );
      expect(
        Directory(
          '${home.path}${Platform.pathSeparator}attachments'
          '${Platform.pathSeparator}.partial',
        ).listSync(),
        isEmpty,
      );
    },
  );

  test(
    'ownership mismatch fails closed and session deletion removes bytes',
    () async {
      final wrong = await store.create(fileName: 'wrong.txt');
      await store.write(wrong, 'wrong'.codeUnits);
      final wrongAttachment = await store.commit(
        wrong,
        sessionId: 'session-a',
        admissionId: 'message-b',
      );
      expect(
        () => _claim(
          store,
          sessionId: 'session-a',
          admissionId: 'message-b',
          messageId: 'message-b',
          attachmentId: wrongAttachment.id,
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (error) => error.code,
            'code',
            AttachmentStoreErrorCode.ownershipMismatch,
          ),
        ),
      );

      final upload = await store.create(fileName: 'owned.txt');
      await store.write(upload, 'owned'.codeUnits);
      final attachment = await store.commit(
        upload,
        sessionId: 'session-a',
        admissionId: 'message-a',
      );
      _claim(
        store,
        sessionId: 'session-a',
        admissionId: 'message-a',
        messageId: 'message-a',
        attachmentId: attachment.id,
      );
      final path = await store.resolvePath(
        sessionId: 'session-a',
        attachmentId: attachment.id,
      );

      await store.deleteSession('session-a');
      await store.deleteSession('session-a');

      expect(File(path).existsSync(), isFalse);
      expect(
        state.db.select(
          'SELECT * FROM user_attachments WHERE attachment_id = ?',
          [attachment.id],
        ),
        isEmpty,
      );
    },
  );

  test(
    'message persistence and attachment claim are atomic and retry-safe',
    () async {
      final upload = await store.create(fileName: 'atomic.txt');
      await store.write(upload, 'atomic'.codeUnits);
      final attachment = await store.commit(
        upload,
        sessionId: 'session-a',
        admissionId: 'request-atomic',
      );
      final sessions = SessionDB.fromState(state);
      final candidate = Message(
        role: MessageRole.user,
        content: 'inspect',
        attachments: [attachment],
        metadata: const {'request_id': 'request-atomic'},
      );

      List<Message> persist() => store.claimAdmissionAndPersist(
        sessionId: 'session-a',
        admissionId: 'request-atomic',
        attachmentIds: [attachment.id],
        persist: (transaction, admitted) =>
            sessions.replaceMessagesInTransaction('session-a', [
              candidate.copyWith(attachments: admitted),
            ], transaction),
      );

      final first = persist();
      final replay = store.loadAdmission(
        sessionId: 'session-a',
        admissionId: 'request-atomic',
        attachmentIds: [attachment.id],
      );
      expect(first.single.attachments.single.id, attachment.id);
      expect(replay.single.id, attachment.id);
      expect(
        state.db.select(
          "SELECT status FROM user_attachments WHERE attachment_id = ?",
          [attachment.id],
        ).single['status'],
        'attached',
      );
      expect(
        state.db
            .select(
              "SELECT COUNT(*) AS count FROM messages WHERE session_id = 'session-a'",
            )
            .single['count'],
        1,
      );
    },
  );

  test('message-orphan cleanup removes metadata and bytes', () async {
    final upload = await store.create(fileName: 'message-owned.txt');
    await store.write(upload, 'owned'.codeUnits);
    final attachment = await store.commit(
      upload,
      sessionId: 'session-a',
      admissionId: 'message-a',
    );
    _claim(
      store,
      sessionId: 'session-a',
      admissionId: 'message-a',
      messageId: 'message-a',
      attachmentId: attachment.id,
    );
    final path = await store.resolvePath(
      sessionId: 'session-a',
      attachmentId: attachment.id,
    );

    state.db.execute('DELETE FROM messages WHERE message_id = ?', [
      'message-a',
    ]);
    await store.cleanupOrphans();

    expect(File(path).existsSync(), isFalse);
    expect(
      state.db.select(
        'SELECT * FROM user_attachments WHERE attachment_id = ?',
        [attachment.id],
      ),
      isEmpty,
    );
  });

  test(
    'resolveAdmissionPaths accepts attached rows when owned by active message with matching admission requestId',
    () async {
      final upload = await store.create(fileName: 'replay-test.png');
      await store.write(upload, [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      final committed = await store.commit(
        upload,
        sessionId: 'session-a',
        admissionId: 'req-replay-1',
      );

      // Simulate commitSoftRewindAdmission: row status updated to attached with message_id,
      // and active message inserted with matching request_id.
      state.db.execute('''
        INSERT INTO messages (session_id, message_id, request_id, history_status, data)
        VALUES ('session-a', 'msg-replay-1', 'req-replay-1', 'active', '{"role":"user","content":"replay"}')
        ''');
      state.db.execute(
        '''
        UPDATE user_attachments
        SET message_id = 'msg-replay-1', status = 'attached'
        WHERE attachment_id = ?
        ''',
        [committed.id],
      );

      final loaded = store.loadAdmission(
        sessionId: 'session-a',
        admissionId: 'req-replay-1',
        attachmentIds: [committed.id],
      );
      expect(loaded, hasLength(1));
      expect(loaded.single.id, committed.id);

      final paths = await store.resolveAdmissionPaths(
        sessionId: 'session-a',
        admissionId: 'req-replay-1',
        attachmentIds: [committed.id],
      );
      expect(paths, hasLength(1));
      expect(File(paths.single).existsSync(), isTrue);

      // Negative: fails closed if message is superseded
      state.db.execute(
        "UPDATE messages SET history_status = 'superseded' WHERE message_id = 'msg-replay-1'",
      );
      expect(
        () => store.resolveAdmissionPaths(
          sessionId: 'session-a',
          admissionId: 'req-replay-1',
          attachmentIds: [committed.id],
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (e) => e.code,
            'code',
            AttachmentStoreErrorCode.ownershipMismatch,
          ),
        ),
      );

      // Negative: fails closed on mismatched session_id
      state.db.execute(
        "UPDATE messages SET history_status = 'active' WHERE message_id = 'msg-replay-1'",
      );
      expect(
        () => store.resolveAdmissionPaths(
          sessionId: 'session-b',
          admissionId: 'req-replay-1',
          attachmentIds: [committed.id],
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (e) => e.code,
            'code',
            AttachmentStoreErrorCode.ownershipMismatch,
          ),
        ),
      );

      // Negative: fails closed on mismatched admission_id
      expect(
        () => store.resolveAdmissionPaths(
          sessionId: 'session-a',
          admissionId: 'req-wrong-id',
          attachmentIds: [committed.id],
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (e) => e.code,
            'code',
            AttachmentStoreErrorCode.ownershipMismatch,
          ),
        ),
      );

      // Negative: fails closed when file is deleted on disk
      await File(paths.single).delete();
      expect(
        () => store.resolveAdmissionPaths(
          sessionId: 'session-a',
          admissionId: 'req-replay-1',
          attachmentIds: [committed.id],
        ),
        throwsA(
          isA<AttachmentStoreException>().having(
            (e) => e.code,
            'code',
            AttachmentStoreErrorCode.unavailable,
          ),
        ),
      );
    },
  );

  test(
    'safe-name logic is separator-neutral for Windows, macOS, and Linux',
    () {
      expect(
        AttachmentStore.sanitizeFileName(r'C:\Users\me\image.png'),
        'image.png',
      );
      expect(
        AttachmentStore.sanitizeFileName('/Users/me/image.png'),
        'image.png',
      );
      expect(AttachmentStore.sanitizeFileName('../../etc/passwd'), 'passwd');
      expect(
        AttachmentStore.sanitizeFileName(r'..\..\CON:*?.txt'),
        'CON___.txt',
      );
      expect(AttachmentStore.sanitizeFileName('\u0000'), 'attachment');
    },
  );
}

void _claim(
  AttachmentStore store, {
  required String sessionId,
  required String admissionId,
  required String messageId,
  required String attachmentId,
}) {
  store.claimAdmissionAndPersist(
    sessionId: sessionId,
    admissionId: admissionId,
    attachmentIds: [attachmentId],
    persist: (_, attachments) => [
      Message(
        role: MessageRole.user,
        content: 'test',
        attachments: attachments,
        metadata: {
          'request_id': admissionId,
          'message_id': messageId,
          'turn_id': 'turn-$messageId',
        },
      ),
    ],
  );
}

void _insertSessionAndMessage(
  AgentStateDatabase state, {
  required String sessionId,
  required String messageId,
}) {
  final now = DateTime.now().toUtc().toIso8601String();
  state.db.execute(
    '''
    INSERT INTO sessions (session_id, model, created_at, updated_at)
    VALUES (?, 'test-model', ?, ?)
    ''',
    [sessionId, now, now],
  );
  state.db.execute(
    '''
    INSERT INTO messages (session_id, data, message_id)
    VALUES (?, '{"role":"user","content":"test","attachments":[]}', ?)
    ''',
    [sessionId, messageId],
  );
}
