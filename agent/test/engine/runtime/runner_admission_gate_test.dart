import 'package:sanad_agent/engine/runtime/runner_admission_gate.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:test/test.dart';

/// Boundary tests for the extracted runner admission gate.
///
/// The gate is the single owner of provider admission, in-flight state, the
/// atomic restart drain, and the cancellation scope lifecycle. These
/// assertions fail if any of those responsibilities is moved back into the
/// runner host or dropped during a later refactor.
void main() {
  RunCancellationScope scopeFor(String runId) => RunCancellationScope(
    sessionId: 'session-1',
    runId: runId,
    workItemId: 'work-1',
    generation: 1,
  );

  group('RunnerAdmissionGate', () {
    test('starts idle with publication open and no attached scope', () {
      final gate = RunnerAdmissionGate();

      expect(gate.stopRequested, isFalse);
      expect(gate.providerRequestInFlight, isFalse);
      expect(gate.cancellationScope, isNull);
      expect(gate.canPublishRunEvents, isTrue);
    });

    test('a stop clears in-flight state and closes run-event publication', () {
      final gate = RunnerAdmissionGate();
      final scope = scopeFor('run-1');
      gate.attachCancellationScope(scope);
      gate.beginControlledRestartDrain();
      // A provider request is already in flight when the stop arrives.
      gate.providerRequestInFlight = true;

      gate.requestStop();

      expect(gate.stopRequested, isTrue);
      expect(gate.providerRequestInFlight, isFalse);
      expect(gate.canPublishRunEvents, isFalse);
      expect(gate.cancellationScope, same(scope));
      expect(scope.isPublicationOpen, isFalse);
    });

    test('resetStopRequested reopens admission without touching the scope', () {
      final gate = RunnerAdmissionGate();
      final scope = scopeFor('run-2');
      gate.attachCancellationScope(scope);
      gate.requestStop();

      gate.resetStopRequested();

      expect(gate.stopRequested, isFalse);
      expect(gate.cancellationScope, same(scope));
      // Publication stays closed for the invalidated scope; only the
      // stop flag is reset for the next turn.
      expect(gate.canPublishRunEvents, isFalse);
    });

    test('detach only clears the scope instance it was given', () {
      final gate = RunnerAdmissionGate();
      final attached = scopeFor('run-3');
      final other = scopeFor('run-4');
      gate.attachCancellationScope(attached);

      gate.detachCancellationScope(other);
      expect(gate.cancellationScope, same(attached));

      gate.detachCancellationScope(attached);
      expect(gate.cancellationScope, isNull);
    });

    test('clearCancellationScope releases the attached scope unconditionally', () {
      final gate = RunnerAdmissionGate();
      gate.attachCancellationScope(scopeFor('run-5'));

      gate.clearCancellationScope();

      expect(gate.cancellationScope, isNull);
      expect(gate.canPublishRunEvents, isTrue);
    });

    test('a released restart drain stops a later stop from hanging', () async {
      final gate = RunnerAdmissionGate();
      gate.providerRequestInFlight = true;

      gate.beginControlledRestartDrain();
      gate.cancelControlledRestartDrain();

      // A drain that was already released must not keep admission waiting: a
      // stop right after it still clears the previously in-flight request.
      expect(gate.stopRequested, isFalse);
      gate.requestStop();
      expect(gate.stopRequested, isTrue);
      expect(gate.providerRequestInFlight, isFalse);
      await Future<void>.delayed(Duration.zero);
    });
  });
}
