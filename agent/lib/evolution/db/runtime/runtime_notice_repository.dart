import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../persisted_runtime_state_repository.dart';

/// Notice persistence and hydration for the
/// `session_runtime_notices` table — the durable mirror of the active
/// `RuntimeNotice` from `RuntimeRecoveryService`.
///
/// Secrets never live here: only message text, request ids, provider/model
/// route ids, and the already-redacted notice message.
class RuntimeNoticeRepository {
  final Database _db;

  RuntimeNoticeRepository(Database db) : _db = db;

  /// Inserts or replaces the active runtime notice for [sessionId].
  void upsertNotice({
    required String sessionId,
    String? requestId,
    String? runId,
    required String status,
    required String reason,
    String severity = 'warning',
    required String title,
    required String message,
    String? providerInstanceId,
    String? providerDisplayName,
    int? retryAfterMs,
    String? resumeAt,
    int? limitRpm,
    int? retryAttempt,
    int? retryBudget,
    List<String> actions = const [],
    DateTime? createdAt,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    _db.execute(
      '''
      INSERT INTO session_runtime_notices (
        session_id, request_id, run_id, status, reason, severity,
        title, message, provider_instance_id, provider_display_name,
        retry_after_ms, resume_at, limit_rpm, retry_attempt, retry_budget,
        actions, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        request_id = excluded.request_id,
        run_id = excluded.run_id,
        status = excluded.status,
        reason = excluded.reason,
        severity = excluded.severity,
        title = excluded.title,
        message = excluded.message,
        provider_instance_id = excluded.provider_instance_id,
        provider_display_name = excluded.provider_display_name,
        retry_after_ms = excluded.retry_after_ms,
        resume_at = excluded.resume_at,
        limit_rpm = excluded.limit_rpm,
        retry_attempt = excluded.retry_attempt,
        retry_budget = excluded.retry_budget,
        actions = excluded.actions,
        updated_at = excluded.updated_at
      ''',
      [
        sessionId,
        requestId,
        runId,
        status,
        reason,
        severity,
        title,
        message,
        providerInstanceId,
        providerDisplayName,
        retryAfterMs,
        resumeAt,
        limitRpm,
        retryAttempt,
        retryBudget,
        jsonEncode(actions),
        createdAt?.toUtc().toIso8601String() ?? now,
        now,
      ],
    );
  }

  PersistedRuntimeNotice? findNotice(String sessionId) {
    final rows = _db.select(
      'SELECT * FROM session_runtime_notices WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    return PersistedRuntimeNotice.fromRow(rows.first);
  }

  Map<String, PersistedRuntimeNotice> findAllNotices() {
    final rows = _db.select('SELECT * FROM session_runtime_notices');
    final result = <String, PersistedRuntimeNotice>{};
    for (final row in rows) {
      final notice = PersistedRuntimeNotice.fromRow(row);
      result[notice.sessionId] = notice;
    }
    return result;
  }

  /// Deletes the active notice for [sessionId].
  void deleteNotice(String sessionId) {
    _db.execute('DELETE FROM session_runtime_notices WHERE session_id = ?', [
      sessionId,
    ]);
  }
}
