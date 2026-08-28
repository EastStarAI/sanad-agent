import 'dart:async';

import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:test/test.dart';

void main() {
  group('RunCancellationScope', () {
    late RunCancellationScope scope;

    setUp(() {
      scope = RunCancellationScope(
        sessionId: 'session-1',
        runId: 'run-1',
        workItemId: 'work-1',
        generation: 1,
      );
    });

    test('invalidate closes publication synchronously', () {
      expect(scope.isPublicationOpen, isTrue);
      scope.invalidate();
      expect(scope.isPublicationOpen, isFalse);
      expect(scope.state, RunCancellationState.active);
    });

    test('first cancel runs cleanup once for registered resources', () async {
      var cleanupCount = 0;
      scope.register('resource-a', () async {
        cleanupCount++;
      });

      final report = await scope.cancel();

      expect(cleanupCount, 1);
      expect(report.finalState, RunCancellationState.cancelled);
      expect(report.resources, hasLength(1));
      expect(report.resources.first.outcome, RunCancellationResourceOutcome.cancelled);
    });

    test('repeated cancel joins the same operation', () async {
      var cleanupCount = 0;
      scope.register('resource-a', () async {
        cleanupCount++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      });

      final first = scope.cancel();
      final second = scope.cancel();
      expect(identical(first, second), isTrue);

      final reports = await Future.wait([first, second]);
      expect(cleanupCount, 1);
      expect(reports.first.finalState, RunCancellationState.cancelled);
      expect(reports.last.finalState, RunCancellationState.cancelled);
    });

    test('late registration after cancel starts runs cleanup once', () async {
      final gate = Completer<void>();
      scope.register('slow', () async {
        await gate.future;
      });

      final cancelFuture = scope.cancel();
      await Future<void>.delayed(Duration.zero);

      var lateCount = 0;
      scope.register('late', () async {
        lateCount++;
      });

      gate.complete();
      await cancelFuture;

      expect(lateCount, 1);
    });

    test('release removes registration without running cleanup', () async {
      var cleanupCount = 0;
      final handle = scope.register('released-resource', () async {
        cleanupCount++;
      });

      handle.release();
      final report = await scope.cancel();

      expect(cleanupCount, 0);
      expect(report.resources, isEmpty);
      expect(handle.isReleased, isTrue);
    });

    test('repeated release is idempotent', () {
      final handle = scope.register('released-resource', () async {});
      handle.release();
      handle.release();
      expect(handle.isReleased, isTrue);
    });

    test('cancel after release skips released cleanup', () async {
      var cleanupCount = 0;
      final released = scope.register('released', () async {
        cleanupCount++;
      });
      scope.register('active', () async {
        cleanupCount++;
      });

      released.release();
      await scope.cancel();

      expect(cleanupCount, 1);
    });

    test('cleanup failure is typed and terminal', () async {
      scope.register('failing-resource', () async {
        throw StateError('cleanup failed');
      });

      final report = await scope.cancel();

      expect(report.finalState, RunCancellationState.cleanupFailed);
      expect(report.resources.first.outcome, RunCancellationResourceOutcome.cleanupFailed);
    });

    test('cleanup deadline produces cleanup_failed without hanging', () async {
      scope.register('slow-resource', () async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      final report = await scope.cancel(
        cleanupDeadline: const Duration(milliseconds: 20),
      );

      expect(report.cleanupDeadlineExceeded, isTrue);
      expect(report.finalState, RunCancellationState.cleanupFailed);
      expect(report.resources.first.outcome, RunCancellationResourceOutcome.timedOut);
    });

    test('markCompleted closes publication without cancelling resources', () async {
      var cleanupCount = 0;
      scope.register('resource', () async {
        cleanupCount++;
      });

      scope.markCompleted();

      expect(scope.isPublicationOpen, isFalse);
      expect(scope.state, RunCancellationState.completed);
      expect(cleanupCount, 0);
    });
  });
}
