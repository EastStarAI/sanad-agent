import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/models/compaction_operation_record.dart';
import 'package:test/test.dart';

RouteSignature _route() {
  return const RouteSignature(
    providerInstanceId: 'provider-1',
    templateId: 'openai',
    protocol: 'openai_compatible',
    normalizedBaseUrl: 'https://api.example.com/v1',
    modelId: 'gpt-4o',
    configRevision: 1,
    credentialRevision: 1,
  );
}

CompactionCandidate _candidate() {
  const summary = CompactionInternalSummary(
    currentGoal: 'Ship compaction',
    remainingWork: 'Persist boundary',
  );
  return CompactionCandidate(
    compactionId: 'cmp-1',
    sessionId: 'session-1',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(4),
    sourceRange: CompactionMessageRange(
      start: const CompactionMessageIdentity(1),
      end: const CompactionMessageIdentity(3),
    ),
    retainedTailRange: CompactionMessageRange(
      start: const CompactionMessageIdentity(4),
      end: const CompactionMessageIdentity(6),
    ),
    internalSummary: summary,
    continuityResult: CompactionContinuityResult.fromSummary(summary),
    metrics: CompactionMetrics(
      contextWindowTokens: 128_000,
      estimatedRequestTokensBefore: 100_000,
      estimatedRequestTokensAfter: 30_000,
      retainedTailTokens: 8_000,
    ),
    routeSignature: _route(),
  );
}

void main() {
  group('CompactionOperationRecord', () {
    test('started row forbids terminal fields', () {
      final started = CompactionOperationRecord(
        compactionId: 'cmp-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        status: CompactionStatus.started,
        sourceHistoryRevision: const CompactionHistoryRevision(2),
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(2),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(3),
          end: const CompactionMessageIdentity(4),
        ),
        routeSignature: _route(),
        startedAt: DateTime.utc(2026, 8, 29),
      );

      expect(started.isTerminal, isFalse);
      expect(started.isAuthoritativeProjection, isFalse);
    });

    test('fromCandidate builds completed authoritative row', () {
      final completed = CompactionOperationRecord.fromCandidate(
        candidate: _candidate(),
        startedAt: DateTime.utc(2026, 8, 29, 1),
        completedAt: DateTime.utc(2026, 8, 29, 2),
      );

      expect(completed.isAuthoritativeProjection, isTrue);
      expect(completed.sourceHistoryRevision.value, 4);
    });
  });

  group('CompactionBoundaryValidity', () {
    test('rejects boundary when message rows were removed', () {
      final boundary = CompactionOperationRecord.fromCandidate(
        candidate: _candidate(),
        startedAt: DateTime.utc(2026, 8, 29),
        completedAt: DateTime.utc(2026, 8, 29, 1),
      );

      expect(
        CompactionBoundaryValidity.isProjectionEligible(
          boundary: boundary,
          existingMessageRowIds: {2, 3, 4, 5, 6},
          currentRevision: const SessionHistoryRevision(4),
        ),
        isFalse,
      );
    });

    test('accepts boundary when ranges and revision remain valid', () {
      final boundary = CompactionOperationRecord.fromCandidate(
        candidate: _candidate(),
        startedAt: DateTime.utc(2026, 8, 29),
        completedAt: DateTime.utc(2026, 8, 29, 1),
      );

      expect(
        CompactionBoundaryValidity.isProjectionEligible(
          boundary: boundary,
          existingMessageRowIds: {1, 2, 3, 4, 5, 6},
          currentRevision: const SessionHistoryRevision(5),
        ),
        isTrue,
      );
    });
  });
}
