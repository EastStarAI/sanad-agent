import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
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
        messageId: 'message-a',
      );

      expect(attachment.safeName, 'photo.exe');
      expect(attachment.mimeType, 'image/png');
      expect(attachment.kind.name, 'image');
      expect(attachment.agentLocalReference, isNot(contains(home.path)));
      final path = await store.resolvePath(
        sessionId: 'session-a',
        attachmentId: attachment.id,
      );
      expect(await File(path).readAsBytes(), bytes);
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
        store.commit(mismatch, sessionId: 'session-a', messageId: 'message-a'),
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
    'restart cleanup removes interrupted partials and promoted orphans',
    () async {
      final interrupted = await store.create(fileName: 'interrupted.txt');
      await store.write(interrupted, [1, 2, 3]);
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
      await expectLater(
        store.commit(wrong, sessionId: 'session-a', messageId: 'message-b'),
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
        messageId: 'message-a',
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

  test('message-orphan cleanup removes metadata and bytes', () async {
    final upload = await store.create(fileName: 'message-owned.txt');
    await store.write(upload, 'owned'.codeUnits);
    final attachment = await store.commit(
      upload,
      sessionId: 'session-a',
      messageId: 'message-a',
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
    VALUES (?, '{}', ?)
    ''',
    [sessionId, messageId],
  );
}
