import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/models/message.dart';
import '../../core/models/user_attachment.dart';
import '../db/agent_state_database.dart';
import '../db/message_history_identity.dart';

/// Closed failures safe to surface without filenames, paths, or bytes.
enum AttachmentStoreErrorCode {
  unknownUpload,
  invalidChunk,
  fileTooLarge,
  sizeMismatch,
  hashMismatch,
  ownershipMismatch,
  unavailable,
}

final class AttachmentStoreException implements Exception {
  const AttachmentStoreException(this.code);

  final AttachmentStoreErrorCode code;

  @override
  String toString() => 'AttachmentStoreException(${code.name})';
}

final class AttachmentUpload {
  const AttachmentUpload._(this.id);

  final String id;
}

final class _PendingUpload {
  _PendingUpload({
    required this.file,
    required this.safeName,
    required this.expectedSize,
    required this.expectedSha256,
  });

  final File file;
  final String safeName;
  final int? expectedSize;
  final String? expectedSha256;
  int bytesWritten = 0;
}

/// Agent-owned staging, verified promotion, ownership, and path-grant boundary.
final class AttachmentStore {
  AttachmentStore(
    this._state, {
    String? stateHome,
    bool enforcePermissions = true,
  }) : _root = Directory(
         p.join(stateHome ?? getSanadStateHome(), storageDirectoryName),
       ),
       _enforcePermissions = enforcePermissions;

  static const String storageDirectoryName = 'attachments';
  static const String _partialDirectoryName = '.partial';
  static const String _payloadName = 'payload';
  static const int _maxSafeNameRunes = 120;

  final AgentStateDatabase _state;
  final Directory _root;
  final bool _enforcePermissions;
  final Map<String, _PendingUpload> _pending = {};

  Directory get _partialRoot =>
      Directory(p.join(_root.path, _partialDirectoryName));

  /// Creates the fixed private roots and removes interrupted or orphaned data.
  Future<void> initialize() async {
    await _secureDirectory(_root);
    if (await _partialRoot.exists()) {
      await _partialRoot.delete(recursive: true);
    }
    await _secureDirectory(_partialRoot);
    await cleanupOrphans();
  }

  Future<AttachmentUpload> create({
    required String fileName,
    String? declaredMime,
    int? expectedSize,
    String? expectedSha256,
  }) async {
    if (expectedSize != null &&
        (expectedSize < 0 ||
            expectedSize > UserAttachmentPolicy.maxFileBytes)) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.fileTooLarge,
      );
    }
    if (expectedSha256 != null &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha256)) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.hashMismatch,
      );
    }
    await _secureDirectory(_partialRoot);
    final id = const Uuid().v4();
    final file = File(p.join(_partialRoot.path, '$id.part'));
    await file.create(exclusive: true);
    await _secureFile(file);
    _pending[id] = _PendingUpload(
      file: file,
      safeName: sanitizeFileName(fileName),
      expectedSize: expectedSize,
      expectedSha256: expectedSha256,
    );
    return AttachmentUpload._(id);
  }

  Future<void> write(AttachmentUpload upload, List<int> chunk) async {
    final pending = _pending[upload.id];
    if (pending == null) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.unknownUpload,
      );
    }
    if (chunk.any((byte) => byte < 0 || byte > 255)) {
      await cancel(upload);
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.invalidChunk,
      );
    }
    final nextSize = pending.bytesWritten + chunk.length;
    if (nextSize > UserAttachmentPolicy.maxFileBytes) {
      await cancel(upload);
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.fileTooLarge,
      );
    }
    await pending.file.writeAsBytes(chunk, mode: FileMode.append, flush: true);
    pending.bytesWritten = nextSize;
  }

  /// Verifies bytes and atomically promotes them before inserting ownership.
  /// A database failure removes the promoted file, so no approved orphan is
  /// left by a failed message/session ownership check.
  Future<UserAttachment> commit(
    AttachmentUpload upload, {
    required String sessionId,
    required String admissionId,
  }) async {
    if (admissionId.trim().isEmpty ||
        admissionId.contains('/') ||
        admissionId.contains(r'\')) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.ownershipMismatch,
      );
    }
    final pending = _pending.remove(upload.id);
    if (pending == null) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.unknownUpload,
      );
    }
    final size = await pending.file.length();
    if (pending.expectedSize != null && pending.expectedSize != size) {
      await _deleteIfPresent(pending.file);
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.sizeMismatch,
      );
    }
    final digest = await sha256.bind(pending.file.openRead()).first;
    final hash = digest.toString();
    if (pending.expectedSha256 != null && pending.expectedSha256 != hash) {
      await _deleteIfPresent(pending.file);
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.hashMismatch,
      );
    }
    final prefix = await _readPrefix(pending.file);
    final mime = _inspectMime(prefix);
    final attachmentId = const Uuid().v4();
    final mediaId = const Uuid().v4();
    final relativePath = p.join(attachmentId, _payloadName);
    final targetDirectory = Directory(p.join(_root.path, attachmentId));
    final target = File(p.join(_root.path, relativePath));
    await _secureDirectory(targetDirectory);
    try {
      await pending.file.rename(target.path);
      await _secureFile(target);
      _state.transaction((transaction) {
        transaction.db.execute(
          '''
          INSERT INTO user_attachments (
            attachment_id, media_id, session_id, admission_id, status,
            safe_name, mime_type, byte_size, sha256, kind, relative_path,
            created_at
          ) VALUES (?, ?, ?, ?, 'staged', ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            attachmentId,
            mediaId,
            sessionId,
            admissionId,
            pending.safeName,
            mime,
            size,
            hash,
            mime.startsWith('image/') ? 'image' : 'file',
            relativePath,
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      });
    } on Object {
      await _deleteDirectoryIfPresent(targetDirectory);
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.ownershipMismatch,
      );
    }
    return UserAttachment(
      id: attachmentId,
      safeName: pending.safeName,
      mimeType: mime,
      sizeBytes: size,
      sha256: hash,
      kind: mime.startsWith('image/')
          ? UserAttachmentKind.image
          : UserAttachmentKind.file,
      agentLocalReference: p.join(storageDirectoryName, relativePath),
      mediaId: mediaId,
    );
  }

  Future<void> cancel(AttachmentUpload upload) async {
    final pending = _pending.remove(upload.id);
    if (pending != null) await _deleteIfPresent(pending.file);
  }

  /// Loads an ordered admission owned by exactly one session/request.
  List<UserAttachment> loadAdmission({
    required String sessionId,
    required String admissionId,
    required List<String> attachmentIds,
  }) {
    if (attachmentIds.toSet().length != attachmentIds.length ||
        attachmentIds.length > UserAttachmentPolicy.maxFilesPerMessage) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.ownershipMismatch,
      );
    }
    final attachments = <UserAttachment>[];
    for (final attachmentId in attachmentIds) {
      final rows = _state.db.select(
        '''
        SELECT * FROM user_attachments
        WHERE attachment_id = ? AND session_id = ? AND admission_id = ?
        ''',
        [attachmentId, sessionId, admissionId],
      );
      if (rows.length != 1) {
        throw const AttachmentStoreException(
          AttachmentStoreErrorCode.ownershipMismatch,
        );
      }
      attachments.add(_attachmentFromRow(rows.single));
    }
    final validation = UserAttachmentPolicy.validate(attachments);
    if (validation is AttachmentAdmissionFailure) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.ownershipMismatch,
      );
    }
    return List<UserAttachment>.unmodifiable(attachments);
  }

  /// Persists the user history and claims staged rows in one state transaction.
  List<Message> claimAdmissionAndPersist({
    required String sessionId,
    required String admissionId,
    required List<String> attachmentIds,
    required List<Message> Function(
      AgentStateTransaction transaction,
      List<UserAttachment> attachments,
    )
    persist,
  }) {
    final attachments = loadAdmission(
      sessionId: sessionId,
      admissionId: admissionId,
      attachmentIds: attachmentIds,
    );
    try {
      return _state.transaction((transaction) {
        final persisted = persist(transaction, attachments);
        final userMessages = persisted.where(
          (message) =>
              message.role == MessageRole.user &&
              MessageHistoryIdentity.requestIdOf(message) == admissionId,
        );
        if (userMessages.length != 1) {
          throw const AttachmentStoreException(
            AttachmentStoreErrorCode.ownershipMismatch,
          );
        }
        final messageId = MessageHistoryIdentity.read(
          userMessages.single,
        ).messageId;
        if (messageId.isEmpty) {
          throw const AttachmentStoreException(
            AttachmentStoreErrorCode.ownershipMismatch,
          );
        }
        for (final attachmentId in attachmentIds) {
          transaction.db.execute(
            '''
          UPDATE user_attachments
          SET message_id = ?, status = 'attached'
          WHERE attachment_id = ? AND session_id = ? AND admission_id = ?
            AND (status = 'staged' OR message_id = ?)
          ''',
            [messageId, attachmentId, sessionId, admissionId, messageId],
          );
          if (transaction.db.updatedRows != 1) {
            throw const AttachmentStoreException(
              AttachmentStoreErrorCode.ownershipMismatch,
            );
          }
        }
        return persisted;
      });
    } on AttachmentStoreException {
      rethrow;
    } on Object {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.ownershipMismatch,
      );
    }
  }

  Future<List<String>> resolveAttachedPaths(String sessionId) async {
    final rows = _state.db.select(
      "SELECT attachment_id FROM user_attachments WHERE session_id = ? AND status = 'attached' ORDER BY created_at, attachment_id",
      [sessionId],
    );
    final paths = <String>[];
    for (final row in rows) {
      try {
        paths.add(
          await resolvePath(
            sessionId: sessionId,
            attachmentId: row['attachment_id'] as String,
          ),
        );
      } on AttachmentStoreException {
        // A missing owned file is unavailable, never broadened to another path.
      }
    }
    return List<String>.unmodifiable(paths);
  }

  /// Resolves an exact-session grant; attachment references alone confer no
  /// access and callers never choose or concatenate a filesystem path.
  Future<String> resolvePath({
    required String sessionId,
    required String attachmentId,
  }) async {
    final rows = _state.db.select(
      '''
      SELECT relative_path FROM user_attachments
      WHERE attachment_id = ? AND session_id = ? AND status = 'attached'
      ''',
      [attachmentId, sessionId],
    );
    if (rows.isEmpty) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.unavailable,
      );
    }
    final candidate = p.normalize(
      p.join(_root.path, rows.first['relative_path'] as String),
    );
    if (!p.isWithin(_root.path, candidate) || !await File(candidate).exists()) {
      throw const AttachmentStoreException(
        AttachmentStoreErrorCode.unavailable,
      );
    }
    return candidate;
  }

  /// Deletes database ownership atomically, then owned bytes idempotently.
  Future<void> deleteSession(String sessionId) async =>
      deleteSessionSync(sessionId);

  /// Synchronous deletion hook used by the existing synchronous session API.
  void deleteSessionSync(String sessionId) {
    final rows = _state.db.select(
      'SELECT relative_path FROM user_attachments WHERE session_id = ?',
      [sessionId],
    );
    _state.transaction((transaction) {
      transaction.db.execute(
        'UPDATE sessions SET parent_session_id = NULL WHERE parent_session_id = ?',
        [sessionId],
      );
      transaction.db.execute('DELETE FROM sessions WHERE session_id = ?', [
        sessionId,
      ]);
    });
    for (final row in rows) {
      final relativePath = row['relative_path'] as String;
      final directory = Directory(p.join(_root.path, p.dirname(relativePath)));
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  }

  /// Deletes promoted directories that have no durable metadata owner.
  Future<void> cleanupOrphans() async {
    if (!await _root.exists()) return;
    final staleRows = _state.db.select('''
      SELECT attachment_id, relative_path FROM user_attachments AS attachment
      WHERE attachment.status = 'attached' AND NOT EXISTS (
        SELECT 1 FROM messages AS message
        WHERE message.message_id = attachment.message_id
          AND message.session_id = attachment.session_id
      )
    ''');
    if (staleRows.isNotEmpty) {
      _state.transaction((transaction) {
        for (final row in staleRows) {
          transaction.db.execute(
            'DELETE FROM user_attachments WHERE attachment_id = ?',
            [row['attachment_id']],
          );
        }
      });
      for (final row in staleRows) {
        await _deleteDirectoryIfPresent(
          Directory(
            p.join(_root.path, p.dirname(row['relative_path'] as String)),
          ),
        );
      }
    }
    final owned = _state.db
        .select('SELECT relative_path FROM user_attachments')
        .map((row) => p.dirname(row['relative_path'] as String))
        .toSet();
    await for (final entity in _root.list(followLinks: false)) {
      if (entity is! Directory ||
          p.basename(entity.path) == _partialDirectoryName) {
        continue;
      }
      if (!owned.contains(p.basename(entity.path))) {
        await entity.delete(recursive: true);
      }
    }
  }

  static UserAttachment _attachmentFromRow(dynamic row) => UserAttachment(
    id: row['attachment_id'] as String,
    safeName: row['safe_name'] as String,
    mimeType: row['mime_type'] as String,
    sizeBytes: row['byte_size'] as int,
    sha256: row['sha256'] as String,
    kind: row['kind'] == 'image'
        ? UserAttachmentKind.image
        : UserAttachmentKind.file,
    agentLocalReference: p.join(
      storageDirectoryName,
      row['relative_path'] as String,
    ),
    mediaId: row['media_id'] as String,
  );

  static String sanitizeFileName(String input) {
    final basename = input.split(RegExp(r'[/\\]')).last;
    final cleaned = basename
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '')
        .replaceAll(RegExp(r'[:*?"<>|]'), '_')
        .trim();
    final safe = cleaned.isEmpty || cleaned == '.' || cleaned == '..'
        ? 'attachment'
        : cleaned;
    return String.fromCharCodes(safe.runes.take(_maxSafeNameRunes));
  }

  static Future<Uint8List> _readPrefix(File file) async {
    final handle = await file.open();
    try {
      return Uint8List.fromList(await handle.read(512));
    } finally {
      await handle.close();
    }
  }

  static String _inspectMime(Uint8List bytes) {
    bool starts(List<int> magic) =>
        bytes.length >= magic.length &&
        List.generate(magic.length, (index) => bytes[index]).join(',') ==
            magic.join(',');
    if (starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return 'image/png';
    }
    if (starts([0xff, 0xd8, 0xff])) return 'image/jpeg';
    if (starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        starts(ascii.encode('RIFF')) &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    if (starts(ascii.encode('%PDF-'))) return 'application/pdf';
    try {
      final text = utf8.decode(bytes);
      if (!text.runes.any(
        (rune) => rune < 0x09 || (rune > 0x0d && rune < 0x20),
      )) {
        return 'text/plain';
      }
    } on FormatException {
      // Binary data remains generic.
    }
    return 'application/octet-stream';
  }

  Future<void> _secureDirectory(Directory directory) async {
    await directory.create(recursive: true);
    if (_enforcePermissions && !Platform.isWindows) {
      final result = await Process.run('chmod', ['700', directory.path]);
      if (result.exitCode != 0) {
        throw FileSystemException('Could not secure attachment directory.');
      }
    }
  }

  Future<void> _secureFile(File file) async {
    if (_enforcePermissions && !Platform.isWindows) {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw FileSystemException('Could not secure attachment file.');
      }
    }
  }

  static Future<void> _deleteIfPresent(File file) async {
    if (await file.exists()) await file.delete();
  }

  static Future<void> _deleteDirectoryIfPresent(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
