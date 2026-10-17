import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/message.dart';
import '../models/session_state.dart';
import 'agent_state_database.dart';
import 'compaction_boundary_repository.dart';
import 'message_history_identity.dart';
import 'session_fork_copy.dart';
import 'session_history_revision_repository.dart';
import 'session_message_repository.dart';
import 'session_repository.dart';

/// Result of an atomic soft-rewind plus replacement-user commit.
class SoftRewindAdmissionCommit {
  final int historyRevision;
  final String replacementMessageId;
  final String replacementTurnId;

  const SoftRewindAdmissionCommit({
    required this.historyRevision,
    required this.replacementMessageId,
    required this.replacementTurnId,
  });
}

/// Result of atomically accepting one canonical root-user message.
class RootUserMessageCommit {
  final Message message;
  final int historyRevision;
  final bool inserted;

  const RootUserMessageCommit({
    required this.message,
    required this.historyRevision,
    required this.inserted,
  });
}

enum SessionForkOutcome {
  accepted,
  alreadyExists,
  targetNotFound,
  targetNotForkable,
  sessionNotFound,
  invalidRequest,
  failed,
}

class SessionForkCommit {
  final SessionForkOutcome outcome;
  final SessionState? child;

  const SessionForkCommit({required this.outcome, this.child});
}

/// Persistent storage for fork, soft-rewind, and root-user commit records.
class SessionForkCommitRepository {
  final AgentStateDatabase _state;
  final SessionRepository _sessions;
  final SessionMessageRepository _messages;
  final CompactionBoundaryRepository _compactionBoundaries;

  SessionForkCommitRepository({
    required AgentStateDatabase state,
    required SessionRepository sessions,
    required SessionMessageRepository messages,
    CompactionBoundaryRepository? compactionBoundaries,
  })  : _state = state,
        _sessions = sessions,
        _messages = messages,
        _compactionBoundaries = compactionBoundaries ??
            CompactionBoundaryRepository(
              state,
              SessionHistoryRevisionRepository(state),
            );

  Database get _db => _state.db;

  /// Appends one root-user message without reading or rewriting prior rows.
  /// A repeated non-empty request id returns the existing active row.
  RootUserMessageCommit appendRootUserMessage(
    String sessionId,
    Message message,
  ) {
    if (!MessageHistoryIdentity.isRootUser(message)) {
      throw ArgumentError.value(
        message.role,
        'message',
        'Must be root user input',
      );
    }
    return _state.transaction((transaction) {
      final db = transaction.db;
      final sessionRows = db.select(
        'SELECT history_revision FROM sessions WHERE session_id = ? LIMIT 1',
        [sessionId],
      );
      if (sessionRows.isEmpty) {
        throw StateError('Session does not exist: $sessionId');
      }
      final requestId = MessageHistoryIdentity.requestIdOf(message);
      if (requestId != null) {
        final existing = db.select(
          '''
          SELECT * FROM messages
          WHERE session_id = ? AND request_id = ?
            AND input_kind = ?
            AND (history_status = ? OR history_status IS NULL)
          ORDER BY id DESC LIMIT 1
          ''',
          [
            sessionId,
            requestId,
            MessageHistoryIdentity.rootTurn,
            MessageHistoryIdentity.active,
          ],
        );
        if (existing.isNotEmpty) {
          return RootUserMessageCommit(
            message: _messages.persistedMessageFromRow(existing.first).message,
            historyRevision:
                (sessionRows.first['history_revision'] as num?)?.toInt() ?? 0,
            inserted: false,
          );
        }
      }

      final committed = MessageHistoryIdentity.persist(db, sessionId, message);
      final receivedAt = _normalizeTimestampString(
        committed.metadata?['received_at']?.toString(),
      );
      final now = _normalizeDateTime(DateTime.now());
      db.execute(
        '''
        UPDATE sessions
        SET last_user_message_at = ?, updated_at = ?
        WHERE session_id = ?
        ''',
        [receivedAt ?? now, now, sessionId],
      );
      SessionHistoryRevisionRepository.bumpDatabase(db, sessionId);
      final revision = db.select(
        'SELECT history_revision FROM sessions WHERE session_id = ? LIMIT 1',
        [sessionId],
      );
      return RootUserMessageCommit(
        message: committed,
        historyRevision:
            (revision.first['history_revision'] as num?)?.toInt() ?? 0,
        inserted: true,
      );
    });
  }

  /// Compare-and-swaps [expectedHistoryRevision], revalidates the target as
  /// the latest active root turn, soft-rewinds that tail, and inserts
  /// [replacement] in one transaction. Returns `null` when the session is
  /// missing, the revision does not match, or the target is no longer the
  /// latest active root.
  SoftRewindAdmissionCommit? commitSoftRewindAdmission({
    required String sessionId,
    required int expectedHistoryRevision,
    required String targetMessageId,
    required String targetTurnId,
    required String targetRequestId,
    required Message replacement,
  }) {
    _db.execute('BEGIN IMMEDIATE TRANSACTION');
    try {
      final row = _db.select(
        'SELECT history_revision FROM sessions WHERE session_id = ? LIMIT 1',
        [sessionId],
      );
      if (row.isEmpty) {
        _db.execute('ROLLBACK');
        return null;
      }
      final current = (row.first['history_revision'] as num?)?.toInt() ?? 0;
      if (current != expectedHistoryRevision) {
        _db.execute('ROLLBACK');
        return null;
      }
      final active = _messages.getMessages(sessionId);
      final targetIndex = _latestReplayableRootIndex(
        active,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        targetRequestId: targetRequestId,
      );
      if (targetIndex < 0) {
        _db.execute('ROLLBACK');
        return null;
      }
      final assignedReplacement = MessageHistoryIdentity.assignIdentities([
        replacement,
      ]).single;
      final replacementIdentity = MessageHistoryIdentity.read(
        assignedReplacement,
      );
      final superseded = [
        for (final message in active.skip(targetIndex))
          MessageHistoryIdentity.markSuperseded(
            message,
            byTurnId: replacementIdentity.turnId,
          ),
      ];
      _messages.upsertMessageList(sessionId, [
        ...active.take(targetIndex),
        assignedReplacement,
        ...superseded,
      ]);
      for (final attachment in assignedReplacement.attachments) {
        _db.execute(
          '''
          UPDATE user_attachments
          SET message_id = ?, status = 'attached'
          WHERE attachment_id = ? AND session_id = ?
            AND (status = 'staged' OR message_id = ?)
          ''',
          [
            replacementIdentity.messageId,
            attachment.id,
            sessionId,
            targetMessageId,
          ],
        );
        if (_db.updatedRows != 1) {
          _db.execute('ROLLBACK');
          return null;
        }
      }
      final next = current + 1;
      _db.execute(
        'UPDATE sessions SET history_revision = ?, updated_at = ? WHERE session_id = ?',
        [next, _normalizeDateTime(DateTime.now()), sessionId],
      );
      _db.execute('COMMIT');
      return SoftRewindAdmissionCommit(
        historyRevision: next,
        replacementMessageId: replacementIdentity.messageId,
        replacementTurnId: replacementIdentity.turnId,
      );
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static int _latestReplayableRootIndex(
    List<Message> messages, {
    required String targetMessageId,
    required String targetTurnId,
    required String targetRequestId,
  }) {
    final latestRootIndex = messages.lastIndexWhere(
      MessageHistoryIdentity.isRootUser,
    );
    if (latestRootIndex < 0) return -1;
    final target = messages[latestRootIndex];
    final identity = MessageHistoryIdentity.read(target);
    if (!identity.replayEligible ||
        identity.messageId != targetMessageId ||
        identity.turnId != targetTurnId ||
        identity.requestId != targetRequestId) {
      return -1;
    }
    return latestRootIndex;
  }

  /// Creates a child session and copies the active prefix through [targetTurnId]
  /// in one write transaction. Runtime work is not copied.
  SessionForkCommit commitFork({
    required String sourceSessionId,
    required String requestId,
    required String targetMessageId,
    required String targetTurnId,
  }) {
    if (sourceSessionId.isEmpty ||
        requestId.isEmpty ||
        targetMessageId.isEmpty ||
        targetTurnId.isEmpty) {
      return const SessionForkCommit(
        outcome: SessionForkOutcome.invalidRequest,
      );
    }

    const maxAttempts = 8;
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      _db.execute('BEGIN IMMEDIATE TRANSACTION');
      try {
        final existing = _db.select(
          '''
          SELECT session_id, parent_session_id,
                 forked_from_message_id, forked_from_turn_id
          FROM sessions
          WHERE fork_request_id = ?
          LIMIT 1
          ''',
          [requestId],
        );
        if (existing.isNotEmpty) {
          final row = existing.first;
          final matchesCommand =
              row['parent_session_id'] == sourceSessionId &&
              row['forked_from_message_id'] == targetMessageId &&
              row['forked_from_turn_id'] == targetTurnId;
          if (!matchesCommand) {
            _db.execute('ROLLBACK');
            return const SessionForkCommit(
              outcome: SessionForkOutcome.invalidRequest,
            );
          }
          final childId = row['session_id'] as String;
          _db.execute('COMMIT');
          return SessionForkCommit(
            outcome: SessionForkOutcome.alreadyExists,
            child: _sessions.getSession(childId),
          );
        }

        final parent = _sessions.getSession(sourceSessionId);
        if (parent == null) {
          _db.execute('ROLLBACK');
          return const SessionForkCommit(
            outcome: SessionForkOutcome.sessionNotFound,
          );
        }

        final activePersisted = _messages.getPersistedMessages(sourceSessionId);
        final active = activePersisted
            .map((entry) => entry.message)
            .toList(growable: false);
        final target = _findActive(
          active,
          messageId: targetMessageId,
          turnId: targetTurnId,
        );
        if (target == null) {
          final stored = _messages.getMessages(
            sourceSessionId,
            includeSuperseded: true,
          );
          final found = _findActive(
            stored,
            messageId: targetMessageId,
            turnId: targetTurnId,
            ignoreStatus: true,
          );
          _db.execute('ROLLBACK');
          return SessionForkCommit(
            outcome: found == null
                ? SessionForkOutcome.targetNotFound
                : SessionForkOutcome.targetNotForkable,
          );
        }
        if (!SessionForkCopy.isForkableFinalAnswer(target)) {
          _db.execute('ROLLBACK');
          return const SessionForkCommit(
            outcome: SessionForkOutcome.targetNotForkable,
          );
        }

        final prefix = SessionForkCopy.activePrefixThroughTurn(
          activeMessages: active,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
        );
        if (prefix.isEmpty) {
          _db.execute('ROLLBACK');
          return const SessionForkCommit(
            outcome: SessionForkOutcome.targetNotFound,
          );
        }
        final sourcePrefix = activePersisted
            .take(prefix.length)
            .toList(growable: false);

        final lineageId = parent.lineageId;
        final sequence = _nextForkSequence(lineageId);
        final baseTitle = SessionForkCopy.baseTitleOf(
          parent.lineageBaseTitle,
          parent.title,
        );
        final now = DateTime.now().toUtc();
        final child = SessionState(
          sessionId: const Uuid().v4(),
          model: parent.model,
          providerId: parent.providerId,
          thinkingMode: parent.thinkingMode,
          title: SessionForkCopy.forkTitle(sequence, baseTitle),
          titleStatus: SessionTitleStatus.finalized,
          workspaceId: parent.workspaceId,
          createdAt: now,
          updatedAt: now,
          // Fork creation is new sidebar activity even though the materialized
          // user rows preserve their historical timestamps.
          lastUserMessageAt: now,
          routeRevision: parent.routeRevision,
          routeUpdatedAt: parent.routeUpdatedAt,
          historyRevision: 0,
          lineageId: lineageId,
          parentSessionId: parent.sessionId,
          forkedFromMessageId: targetMessageId,
          forkedFromTurnId: targetTurnId,
          forkSequence: sequence,
          lineageBaseTitle: baseTitle,
          forkRequestId: requestId,
        );
        _sessions.saveSession(child);
        if (parent.lineageBaseTitle == null ||
            parent.lineageBaseTitle!.trim().isEmpty) {
          _db.execute(
            '''
            UPDATE sessions
            SET lineage_base_title = ?
            WHERE session_id = ?
              AND (lineage_base_title IS NULL OR TRIM(lineage_base_title) = '')
            ''',
            [baseTitle, parent.sessionId],
          );
        }
        final rewrittenPrefix = SessionForkCopy.rewritePrefix(prefix);
        final childRowIdBySourceRowId = <int, int>{};
        for (var index = 0; index < rewrittenPrefix.length; index++) {
          MessageHistoryIdentity.persist(
            _db,
            child.sessionId,
            rewrittenPrefix[index],
          );
          childRowIdBySourceRowId[sourcePrefix[index].rowId] =
              _db.lastInsertRowId;
        }
        _compactionBoundaries.cloneTerminalOperationsForFork(
          sourceSessionId: sourceSessionId,
          childSessionId: child.sessionId,
          childRowIdBySourceRowId: childRowIdBySourceRowId,
          sourcePrefixEndRowId: sourcePrefix.last.rowId,
          childHistoryRevision: child.historyRevision,
        );
        _db.execute('COMMIT');
        return SessionForkCommit(
          outcome: SessionForkOutcome.accepted,
          child: _sessions.getSession(child.sessionId),
        );
      } catch (error) {
        _db.execute('ROLLBACK');
        lastError = error;
        if (error is SqliteException && _isLineageSequenceConflict(error)) {
          continue;
        }
        return const SessionForkCommit(outcome: SessionForkOutcome.failed);
      }
    }
    if (lastError != null) {
      return const SessionForkCommit(outcome: SessionForkOutcome.failed);
    }
    return const SessionForkCommit(outcome: SessionForkOutcome.failed);
  }

  int _nextForkSequence(String lineageId) {
    final row = _db.select(
      'SELECT MAX(fork_sequence) AS max_seq FROM sessions WHERE lineage_id = ?',
      [lineageId],
    );
    final current = (row.first['max_seq'] as num?)?.toInt() ?? 0;
    return current + 1;
  }

  static Message? _findActive(
    List<Message> messages, {
    required String messageId,
    required String turnId,
    bool ignoreStatus = false,
  }) {
    for (final message in messages) {
      final identity = MessageHistoryIdentity.read(message);
      if (identity.messageId != messageId || identity.turnId != turnId) {
        continue;
      }
      if (!ignoreStatus &&
          identity.historyStatus != MessageHistoryIdentity.active) {
        continue;
      }
      return message;
    }
    return null;
  }

  static bool _isLineageSequenceConflict(SqliteException error) {
    final text = error.message;
    return text.contains('idx_sessions_lineage_sequence') ||
        text.contains('UNIQUE constraint failed');
  }

  static String _normalizeDateTime(DateTime value) =>
      value.toUtc().toIso8601String();

  static String? _normalizeTimestampString(String? value) {
    if (value == null) {
      return null;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return null;
    }
    return _normalizeDateTime(parsed);
  }
}
