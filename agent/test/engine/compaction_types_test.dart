import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
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

CompactionMetrics _metrics({
  int before = 120_000,
  int after = 40_000,
}) {
  return CompactionMetrics(
    contextWindowTokens: 128_000,
    estimatedRequestTokensBefore: before,
    estimatedRequestTokensAfter: after,
    retainedTailTokens: 8_000,
  );
}

void main() {
  group('CompactionPressure', () {
    test('exceedsThreshold uses output reservation and safety buffer', () {
      final pressure = CompactionPressure(
        routeSignature: _route(),
        contextWindowTokens: 100,
        outputReservationTokens: 20,
        safetyBufferTokens: 10,
        estimatedRequestTokens: 71,
        measurementKind: CompactionMeasurementKind.estimated,
      );

      expect(pressure.effectiveInputBudget, 70);
      expect(pressure.exceedsThreshold, isTrue);

      final under = pressure.copyWithEstimate(70);
      expect(under.exceedsThreshold, isFalse);
    });
  });

  group('CompactionMessageRange', () {
    test('uses durable row identities not list indices', () {
      final range = CompactionMessageRange(
        start: const CompactionMessageIdentity(4),
        end: const CompactionMessageIdentity(9),
      );

      expect(range.contains(const CompactionMessageIdentity(7)), isTrue);
      expect(range.contains(const CompactionMessageIdentity(10)), isFalse);
    });
  });

  group('CompactionInternalSummary', () {
    test('is not a conversation Message', () {
      const summary = CompactionInternalSummary(
        currentGoal: 'Ship compaction',
        remainingWork: 'Implement 53b persistence',
      );

      expect(summary, isNot(isA<Message>()));
      expect(summary.missingRequiredSections(), isEmpty);
    });

    test('reports missing required sections', () {
      const summary = CompactionInternalSummary(currentGoal: ' ');

      expect(
        summary.missingRequiredSections(),
        containsAll(['currentGoal', 'remainingWork']),
      );
    });
  });

  group('CompactionCandidate', () {
    test('requires passed continuity validation', () {
      const summary = CompactionInternalSummary(
        currentGoal: 'Goal',
        remainingWork: 'Next step',
      );
      final continuity = CompactionContinuityResult.fromSummary(summary);

      final candidate = CompactionCandidate(
        compactionId: 'cmp-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(3),
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(5),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(6),
          end: const CompactionMessageIdentity(10),
        ),
        internalSummary: summary,
        continuityResult: continuity,
        metrics: _metrics(),
        routeSignature: _route(),
      );

      expect(candidate.rangesAreOrdered, isTrue);
    });

    test('rejects failed continuity', () {
      expect(
        () => CompactionCandidate(
          compactionId: 'cmp-1',
          sessionId: 'session-1',
          trigger: CompactionTrigger.manual,
          sourceRevision: const CompactionHistoryRevision(1),
          sourceRange: CompactionMessageRange(
            start: const CompactionMessageIdentity(1),
            end: const CompactionMessageIdentity(2),
          ),
          retainedTailRange: CompactionMessageRange(
            start: const CompactionMessageIdentity(3),
            end: const CompactionMessageIdentity(4),
          ),
          internalSummary: const CompactionInternalSummary(currentGoal: ''),
          continuityResult: CompactionContinuityResult.validated(
            passed: false,
            missingAnchors: ['currentGoal'],
          ),
          metrics: _metrics(),
          routeSignature: _route(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('CompactionOutcome', () {
    test('completed factory carries candidate only', () {
      const summary = CompactionInternalSummary(
        currentGoal: 'Goal',
        remainingWork: 'Work',
      );
      final candidate = CompactionCandidate(
        compactionId: 'cmp-2',
        sessionId: 'session-2',
        trigger: CompactionTrigger.overflow,
        sourceRevision: const CompactionHistoryRevision(2),
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(2),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(3),
          end: const CompactionMessageIdentity(4),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: _metrics(),
        routeSignature: _route(),
      );

      final outcome = CompactionOutcome.completed(
        candidate: candidate,
        queuedMessagesAccepted: 2,
      );

      expect(outcome.status, CompactionStatus.completed);
      expect(outcome.failureReason, isNull);
      expect(outcome.candidate, same(candidate));
      expect(outcome.queuedMessagesAccepted, 2);
    });

    test('failed factory requires typed reason', () {
      final outcome = CompactionOutcome.failed(
        compactionId: 'cmp-3',
        trigger: CompactionTrigger.manual,
        failureReason: CompactionFailureReason.sessionBusy,
      );

      expect(outcome.status, CompactionStatus.failed);
      expect(outcome.candidate, isNull);
      expect(outcome.failureReason, CompactionFailureReason.sessionBusy);
    });
  });
}

extension on CompactionPressure {
  CompactionPressure copyWithEstimate(int estimatedRequestTokens) {
    return CompactionPressure(
      routeSignature: routeSignature,
      contextWindowTokens: contextWindowTokens,
      outputReservationTokens: outputReservationTokens,
      safetyBufferTokens: safetyBufferTokens,
      estimatedRequestTokens: estimatedRequestTokens,
      confirmedInputTokens: confirmedInputTokens,
      measurementKind: measurementKind,
    );
  }
}
