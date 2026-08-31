import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import 'compaction_operation_record.dart';

/// Maps compaction rows to domain records and applies redaction before persistence.
abstract final class CompactionOperationCodec {
  CompactionOperationCodec._();

  static const SecretsRedactor _redactor = SecretsRedactor();

  static CompactionOperationRecord fromRow(ResultSet rows) {
    return fromSingleRow(rows.first);
  }

  static CompactionOperationRecord fromSingleRow(Row row) {
    final trigger = CompactionTrigger.values.firstWhere(
      (value) => value.wireValue == row['trigger'],
    );
    final status = CompactionStatus.values.firstWhere(
      (value) => value.wireValue == row['status'],
    );
    final route = RouteSignature(
      providerInstanceId: row['provider_instance_id'] as String,
      templateId: row['template_id'] as String,
      protocol: row['protocol'] as String,
      normalizedBaseUrl: row['normalized_base_url'] as String,
      modelId: row['model_id'] as String,
      configRevision: row['config_revision'] as int,
      credentialRevision: row['credential_revision'] as int,
    );
    final sourceRange = CompactionMessageRange(
      start: CompactionMessageIdentity(row['source_start_message_id'] as int),
      end: CompactionMessageIdentity(row['source_end_message_id'] as int),
    );
    final tailRange = CompactionMessageRange(
      start: CompactionMessageIdentity(row['tail_start_message_id'] as int),
      end: CompactionMessageIdentity(row['tail_end_message_id'] as int),
    );
    CompactionInternalSummary? summary;
    final summaryJson = row['internal_summary_json'] as String?;
    if (summaryJson != null && summaryJson.isNotEmpty) {
      summary = decodeSummary(summaryJson);
    }
    CompactionMetrics? metrics;
    final before = row['estimated_request_tokens_before'] as int?;
    if (before != null) {
      metrics = CompactionMetrics(
        contextWindowTokens: row['context_window_tokens'] as int,
        estimatedRequestTokensBefore: before,
        estimatedRequestTokensAfter:
            row['estimated_request_tokens_after'] as int,
        beforeMeasurementKind: CompactionMeasurementKind.values.firstWhere(
          (value) => value.wireValue == row['before_measurement_kind'],
        ),
        providerConfirmedRequestTokensAfter:
            row['provider_confirmed_request_tokens_after'] as int?,
        retainedTailTokens: row['retained_tail_tokens'] as int,
        duration: _durationFromMs(row['duration_ms'] as int?),
      );
    }
    CompactionFailureReason? failureReason;
    final failureWire = row['failure_reason'] as String?;
    if (failureWire != null) {
      failureReason = CompactionFailureReason.values.firstWhere(
        (value) => value.wireValue == failureWire,
      );
    }
    return CompactionOperationRecord(
      compactionId: row['compaction_id'] as String,
      sessionId: row['session_id'] as String,
      trigger: trigger,
      status: status,
      sourceHistoryRevision: CompactionHistoryRevision(
        row['source_history_revision'] as int,
      ),
      sourceRange: sourceRange,
      retainedTailRange: tailRange,
      retainedTailEndFingerprint: row['tail_end_anchor_fingerprint'] as String?,
      retainedTailEndOccurrence: row['tail_end_anchor_ordinal'] as int?,
      routeSignature: route,
      metrics: metrics,
      internalSummary: summary,
      failureReason: failureReason,
      failureDetailJson: row['failure_detail_json'] as String?,
      startedAt: DateTime.parse(row['started_at'] as String),
      completedAt: row['completed_at'] == null
          ? null
          : DateTime.parse(row['completed_at'] as String),
    );
  }

  static List<Object?> insertStartedParams({
    required CompactionOperationRecord record,
  }) {
    final route = record.routeSignature;
    return [
      record.compactionId,
      record.sessionId,
      record.trigger.wireValue,
      record.status.wireValue,
      record.sourceHistoryRevision.value,
      record.sourceRange.start.rowId,
      record.sourceRange.end.rowId,
      record.retainedTailRange.start.rowId,
      record.retainedTailRange.end.rowId,
      record.retainedTailEndFingerprint,
      record.retainedTailEndOccurrence,
      route.providerInstanceId,
      route.modelId,
      route.templateId,
      route.protocol,
      route.normalizedBaseUrl,
      route.configRevision,
      route.credentialRevision,
      record.startedAt.toUtc().toIso8601String(),
    ];
  }

  static String encodeSummary(CompactionInternalSummary summary) {
    final encoded = jsonEncode({
      'previousSummaryAnchor': summary.previousSummaryAnchor,
      'currentGoal': summary.currentGoal,
      'successCriteria': summary.successCriteria,
      'constraints': summary.constraints,
      'completedWork': summary.completedWork,
      'activeState': summary.activeState,
      'decisions': summary.decisions,
      'blockers': summary.blockers,
      'filesAndPaths': summary.filesAndPaths,
      'pendingAsks': summary.pendingAsks,
      'remainingWork': summary.remainingWork,
    });
    return _redactor.redact(encoded);
  }

  static CompactionInternalSummary decodeSummary(String json) {
    final map = jsonDecode(json) as Map<String, dynamic>;
    return CompactionInternalSummary(
      previousSummaryAnchor: map['previousSummaryAnchor'] as String?,
      currentGoal: map['currentGoal'] as String? ?? '',
      successCriteria: map['successCriteria'] as String?,
      constraints: map['constraints'] as String?,
      completedWork: map['completedWork'] as String?,
      activeState: map['activeState'] as String?,
      decisions: map['decisions'] as String?,
      blockers: map['blockers'] as String?,
      filesAndPaths: map['filesAndPaths'] as String?,
      pendingAsks: map['pendingAsks'] as String?,
      remainingWork: map['remainingWork'] as String?,
    );
  }

  static String? encodeFailureDetail(Map<String, dynamic>? detail) {
    if (detail == null || detail.isEmpty) {
      return null;
    }
    return _redactor.redact(jsonEncode(detail));
  }

  static Duration? _durationFromMs(int? durationMs) {
    if (durationMs == null) {
      return null;
    }
    return Duration(milliseconds: durationMs);
  }
}
