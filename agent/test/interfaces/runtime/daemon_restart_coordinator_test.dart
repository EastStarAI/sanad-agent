import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

import '../../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();

  test('controlled restart timeout defaults to one minute', () {
    expect(
      SessionRunOrchestrator.controlledRestartCheckpointTimeout,
      const Duration(minutes: 1),
    );
  });

  test('safe restart exits only after preparation is completed', () async {
    int? exitCode;
    final orchestrator = _BoundaryOrchestrator();
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: orchestrator,
      exitDaemon: (code) => exitCode = code,
    );

    final preparation = await coordinator.prepareRestart();

    expect(preparation.accepted, isTrue);
    expect(orchestrator.drainStarted, isTrue);
    expect(exitCode, isNull);

    await coordinator.completePreparedRestart(preparation);
    expect(exitCode, 0);
  });

  test(
    'controlled-exit maintenance runs after drain and before exit',
    () async {
      final steps = <String>[];
      final orchestrator = _BoundaryOrchestrator();
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        beforeControlledExit: () async {
          expect(orchestrator.drainStarted, isTrue);
          steps.add('maintenance');
        },
        exitDaemon: (_) => steps.add('exit'),
      );

      final preparation = await coordinator.prepareRestart();
      expect(steps, isEmpty);
      await coordinator.completePreparedRestart(preparation);

      expect(steps, ['maintenance', 'exit']);
    },
  );

  test('maintenance failure cannot cancel a safe restart', () async {
    int? exitCode;
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: _BoundaryOrchestrator(),
      beforeControlledExit: () async => throw StateError('vacuum failed'),
      exitDaemon: (code) => exitCode = code,
    );

    final preparation = await coordinator.prepareRestart();
    await coordinator.completePreparedRestart(preparation);

    expect(exitCode, 0);
  });

  test(
    'prepared pause exits permanently without cancelling durable work',
    () async {
      int? exitCode;
      final orchestrator = _BoundaryOrchestrator();
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (code) => exitCode = code,
      );

      final preparation = await coordinator.prepareRestart();
      await coordinator.completePreparedPause(preparation);

      expect(exitCode, 123);
      expect(orchestrator.stopAllRequested, isFalse);
      final restartAfterPause = await coordinator.prepareRestart();
      expect(restartAfterPause.outcome, 'cancelled');
    },
  );

  test('prepared permanent stop exits the source supervisor', () async {
    int? exitCode;
    final orchestrator = _BoundaryOrchestrator();
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: orchestrator,
      exitDaemon: (code) => exitCode = code,
    );

    final preparation = await coordinator.prepareRestart();

    expect(preparation.accepted, isTrue);
    expect(exitCode, isNull);

    await coordinator.completePreparedStop(preparation);

    expect(exitCode, 123);
  });

  test(
    'tool-origin restart waits after its one response for requester checkpoint',
    () async {
      int? exitCode;
      final requesterCheckpoint =
          Completer<ControlledRestartCheckpointResult>();
      final orchestrator = _RequesterBoundaryOrchestrator(requesterCheckpoint);
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (code) => exitCode = code,
      );

      final preparation = await coordinator.prepareRestart(
        requesterSessionId: 'requester-session',
        requesterToolCallId: 'requester-tool',
      );
      final completing = coordinator.completePreparedRestart(preparation);
      await Future<void>.delayed(Duration.zero);

      expect(exitCode, isNull);
      expect(orchestrator.requiredRequesterCompletion, isTrue);

      requesterCheckpoint.complete(ControlledRestartCheckpointResult.safe);
      await completing;
      expect(exitCode, 0);
    },
  );

  test(
    'non-forced timeout reports blockers and leaves daemon running',
    () async {
      int? exitCode;
      final orchestrator = _BoundaryOrchestrator(
        result: const ControlledRestartCheckpointResult(
          isSafe: false,
          blockers: [
            ControlledRestartBlocker(
              sessionId: 'blocked-session',
              toolCallIds: ['unsafe-tool'],
              checkpointRecognized: true,
            ),
          ],
        ),
      );
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (code) => exitCode = code,
      );

      final preparation = await coordinator.prepareRestart(
        timeout: const Duration(seconds: 7),
      );
      await coordinator.completePreparedRestart(preparation);

      expect(preparation.accepted, isFalse);
      expect(preparation.outcome, 'timeout');
      expect(preparation.timeout, const Duration(seconds: 7));
      expect(preparation.blockers.single.sessionId, 'blocked-session');
      expect(orchestrator.drainCancelled, isTrue);
      expect(exitCode, isNull);
    },
  );

  test(
    'ordinary restart keeps waiting for an active provider request',
    () async {
      int? exitCode;
      final blocker = const ControlledRestartBlocker(
        sessionId: 'provider-session',
        toolCallIds: [],
        checkpointRecognized: true,
        providerRequestInFlight: true,
      );
      final safeCheckpoint = Completer<ControlledRestartCheckpointResult>();
      final orchestrator = _SequencedBoundaryOrchestrator(
        firstResult: ControlledRestartCheckpointResult(
          isSafe: false,
          blockers: [blocker],
        ),
        nextResult: safeCheckpoint.future,
      );
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (code) => exitCode = code,
      );

      var preparationCompleted = false;
      final preparing = coordinator
          .prepareRestart(timeout: const Duration(seconds: 7))
          .whenComplete(() => preparationCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(preparationCompleted, isFalse);
      expect(orchestrator.calls, 2);
      expect(orchestrator.interruptedBlockers, isEmpty);
      expect(exitCode, isNull);

      safeCheckpoint.complete(ControlledRestartCheckpointResult.safe);
      final preparation = await preparing;
      expect(preparation.accepted, isTrue);
      expect(preparation.force, isFalse);
      expect(preparation.outcome, 'safe');
      expect(orchestrator.interruptedBlockers, isEmpty);
      expect(orchestrator.drainCancelled, isFalse);
      expect(exitCode, isNull);

      await coordinator.completePreparedRestart(preparation);
      expect(exitCode, 0);
    },
  );

  test(
    'mixed provider and tool timeout remains rejected without force',
    () async {
      final orchestrator = _BoundaryOrchestrator(
        result: const ControlledRestartCheckpointResult(
          isSafe: false,
          blockers: [
            ControlledRestartBlocker(
              sessionId: 'provider-session',
              toolCallIds: [],
              checkpointRecognized: true,
              providerRequestInFlight: true,
            ),
            ControlledRestartBlocker(
              sessionId: 'tool-session',
              toolCallIds: ['unsafe-tool'],
              checkpointRecognized: true,
            ),
          ],
        ),
      );
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (_) {},
      );

      final preparation = await coordinator.prepareRestart();

      expect(preparation.accepted, isFalse);
      expect(preparation.outcome, 'timeout');
      expect(orchestrator.interruptedBlockers, isEmpty);
      expect(orchestrator.drainCancelled, isTrue);
    },
  );

  test(
    'concurrent restart is rejected until active preparation completes',
    () async {
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        exitDaemon: (_) {},
      );

      final first = await coordinator.prepareRestart();
      final concurrent = await coordinator.prepareRestart();

      expect(first.accepted, isTrue);
      expect(concurrent.accepted, isFalse);
      expect(concurrent.outcome, 'already_in_progress');

      await coordinator.completePreparedRestart(first);
      final next = await coordinator.prepareRestart();
      expect(next.accepted, isTrue);
      coordinator.abandonPreparedRestart(next);
    },
  );

  test(
    'abandoned response preparation releases drain and permits retry',
    () async {
      final orchestrator = _BoundaryOrchestrator();
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (_) {},
      );

      final preparation = await coordinator.prepareRestart();
      coordinator.abandonPreparedRestart(preparation);

      expect(orchestrator.drainCancelled, isTrue);
      final retry = await coordinator.prepareRestart();
      expect(retry.accepted, isTrue);
      coordinator.abandonPreparedRestart(retry);
    },
  );

  test(
    'forced timeout exits only after the single response boundary',
    () async {
      int? exitCode;
      final orchestrator = _BoundaryOrchestrator(
        result: const ControlledRestartCheckpointResult(
          isSafe: false,
          blockers: [
            ControlledRestartBlocker(
              sessionId: 'blocked-session',
              toolCallIds: ['unsafe-tool'],
              checkpointRecognized: true,
            ),
          ],
        ),
      );
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: orchestrator,
        exitDaemon: (code) => exitCode = code,
      );

      final preparation = await coordinator.prepareRestart(force: true);
      expect(preparation.accepted, isTrue);
      expect(preparation.outcome, 'forced');
      expect(exitCode, isNull);

      await coordinator.completePreparedRestart(preparation);
      expect(exitCode, 0);
    },
  );

  test(
    'prepared pause removes the runtime record before its exit',
    () async {
      final steps = <String>[];
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        beforeDaemonExit: () async => steps.add('cleanup'),
        exitDaemon: (code) => steps.add('exit $code'),
      );

      final preparation = await coordinator.prepareRestart();
      await coordinator.completePreparedPause(preparation);

      expect(steps, ['cleanup', 'exit 123']);
    },
  );

  test(
    'a permanent stop removes the runtime record before its exit',
    () async {
      final steps = <String>[];
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        beforeDaemonExit: () async => steps.add('cleanup'),
        exitDaemon: (code) => steps.add('exit $code'),
      );

      await coordinator.stop(acknowledgementDelay: Duration.zero);

      expect(steps, ['cleanup', 'exit 123']);
    },
  );

  test(
    'a prepared permanent stop removes the runtime record before its exit',
    () async {
      final steps = <String>[];
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        beforeDaemonExit: () async => steps.add('cleanup'),
        exitDaemon: (code) => steps.add('exit $code'),
      );

      final preparation = await coordinator.prepareRestart();
      await coordinator.completePreparedStop(preparation);

      // `completePreparedStop` delegates to `stop`, so the record removal runs
      // exactly once.
      expect(steps, ['cleanup', 'exit 123']);
    },
  );

  test(
    'a supervised restart removes the record before its successor publishes',
    () async {
      final steps = <String>[];
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        beforeControlledExit: () async => steps.add('maintenance'),
        beforeDaemonExit: () async => steps.add('cleanup'),
        exitDaemon: (code) => steps.add('exit $code'),
      );

      final preparation = await coordinator.prepareRestart();
      await coordinator.completePreparedRestart(preparation);

      expect(steps, ['maintenance', 'cleanup', 'exit 0']);
    },
  );

  test('a failing pre-exit cleanup still exits', () async {
    final exitCodes = <int>[];
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: _BoundaryOrchestrator(),
      beforeDaemonExit: () async => throw StateError('record is busy'),
      exitDaemon: exitCodes.add,
    );

    final preparation = await coordinator.prepareRestart();
    await coordinator.completePreparedPause(preparation);

    expect(exitCodes, [123]);
  });

  test('a pre-exit cleanup that never completes still exits', () async {
    final exitCodes = <int>[];
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: _BoundaryOrchestrator(),
      beforeDaemonExit: () => Completer<void>().future,
      beforeDaemonExitTimeout: const Duration(milliseconds: 20),
      exitDaemon: exitCodes.add,
    );

    final preparation = await coordinator.prepareRestart();
    await coordinator.completePreparedPause(preparation);

    expect(exitCodes, [123]);
  });

  test('a restart that leaves the daemon running keeps the record', () async {
    var cleanups = 0;
    final exitCodes = <int>[];
    final blocked = _BoundaryOrchestrator(
      result: const ControlledRestartCheckpointResult(
        isSafe: false,
        blockers: [
          ControlledRestartBlocker(
            sessionId: 'blocked-session',
            toolCallIds: ['unsafe-tool'],
            checkpointRecognized: true,
          ),
        ],
      ),
    );
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: blocked,
      beforeDaemonExit: () async => cleanups++,
      exitDaemon: exitCodes.add,
    );

    final rejected = await coordinator.prepareRestart();
    await coordinator.completePreparedRestart(rejected);

    expect(rejected.accepted, isFalse);
    expect(cleanups, 0);
    expect(exitCodes, isEmpty);
  });

  test('an abandoned restart keeps the record and leaves the daemon up', () async {
    var cleanups = 0;
    final exitCodes = <int>[];
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: _BoundaryOrchestrator(),
      beforeDaemonExit: () async => cleanups++,
      exitDaemon: exitCodes.add,
    );

    final preparation = await coordinator.prepareRestart();
    coordinator.abandonPreparedRestart(preparation);

    expect(preparation.accepted, isTrue);
    expect(cleanups, 0);
    expect(exitCodes, isEmpty);
  });

  test(
    'a managed stop removes the real runtime record before its exit',
    () async {
      // The production wiring: the coordinator owns the exit, so a
      // `sanad-dev stop` (a `/shutdown` pause or a permanent stop) must remove
      // the Home's record itself; `dispose()` is never reached on that path.
      await LocalGatewayEndpointRecord.write(host: '127.0.0.1', port: 58136);
      final recordFile = File(
        SanadHomeBootstrap.resolveChild(LocalGatewayEndpointRecord.relativePath),
      );
      expect(recordFile.existsSync(), isTrue);

      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        beforeDaemonExit: LocalGatewayEndpointRecord.removeOwnedOnExit,
        exitDaemon: (_) {},
      );

      await coordinator.stop(acknowledgementDelay: Duration.zero);

      expect(recordFile.existsSync(), isFalse);
    },
  );

  test(
    'a prepared pause removes the real runtime record before its exit',
    () async {
      // `sanad-dev stop` pauses; the successor publish of a restart cannot be
      // involved, so the record must be gone once the pause completes.
      await LocalGatewayEndpointRecord.write(host: '127.0.0.1', port: 58137);
      final recordFile = File(
        SanadHomeBootstrap.resolveChild(LocalGatewayEndpointRecord.relativePath),
      );
      final coordinator = DaemonRestartCoordinator(
        sessionOrchestrator: _BoundaryOrchestrator(),
        beforeDaemonExit: LocalGatewayEndpointRecord.removeOwnedOnExit,
        exitDaemon: (_) {},
      );

      final preparation = await coordinator.prepareRestart();
      await coordinator.completePreparedPause(preparation);

      expect(recordFile.existsSync(), isFalse);
    },
  );

  test('permanent stop cancels a restart still waiting for safety', () async {
    final checkpoint = Completer<ControlledRestartCheckpointResult>();
    final orchestrator = _StopBoundaryOrchestrator(checkpoint);
    final exitCodes = <int>[];
    final coordinator = DaemonRestartCoordinator(
      sessionOrchestrator: orchestrator,
      exitDaemon: exitCodes.add,
    );

    final preparing = coordinator.prepareRestart();
    await Future<void>.delayed(Duration.zero);
    final stopping = coordinator.stop(acknowledgementDelay: Duration.zero);
    checkpoint.complete(ControlledRestartCheckpointResult.safe);

    final preparation = await preparing;
    await stopping;
    await coordinator.completePreparedRestart(preparation);
    final restartAfterStop = await coordinator.prepareRestart();

    expect(preparation.accepted, isFalse);
    expect(preparation.outcome, 'cancelled');
    expect(restartAfterStop.outcome, 'cancelled');
    expect(orchestrator.drainCancelled, isTrue);
    expect(orchestrator.stopAllRequested, isTrue);
    expect(orchestrator.stopAllPreserveInteractiveWaits, isTrue);
    expect(exitCodes, [123]);
  });
}

class _RequesterBoundaryOrchestrator extends SessionRunOrchestrator {
  _RequesterBoundaryOrchestrator(this.requesterCheckpoint);

  final Completer<ControlledRestartCheckpointResult> requesterCheckpoint;
  bool requiredRequesterCompletion = false;
  var calls = 0;

  @override
  void beginControlledRestartDrain() {}

  @override
  Future<ControlledRestartCheckpointResult> waitForControlledRestartCheckpoint({
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    Duration pollInterval =
        SessionRunOrchestrator.controlledRestartCheckpointPollInterval,
    String? requesterSessionId,
    String? requesterToolCallId,
    bool requireRequesterCompletion = false,
  }) {
    calls++;
    if (calls == 1) {
      expect(requesterSessionId, 'requester-session');
      expect(requesterToolCallId, 'requester-tool');
      return Future.value(ControlledRestartCheckpointResult.safe);
    }
    requiredRequesterCompletion = requireRequesterCompletion;
    return requesterCheckpoint.future;
  }
}

class _BoundaryOrchestrator extends SessionRunOrchestrator {
  _BoundaryOrchestrator({this.result = ControlledRestartCheckpointResult.safe});

  final ControlledRestartCheckpointResult result;
  bool drainStarted = false;
  bool drainCancelled = false;
  bool stopAllRequested = false;
  bool stopAllPreserveInteractiveWaits = false;
  final List<ControlledRestartBlocker> interruptedBlockers = [];

  @override
  Future<void> interruptProviderRequestsForRestart(
    Iterable<ControlledRestartBlocker> blockers,
  ) async {
    interruptedBlockers.addAll(blockers);
  }

  @override
  Future<void> requestStopAll({bool preserveInteractiveWaits = false}) async {
    stopAllRequested = true;
    stopAllPreserveInteractiveWaits = preserveInteractiveWaits;
  }

  @override
  void beginControlledRestartDrain() {
    drainStarted = true;
  }

  @override
  void cancelControlledRestartDrain() {
    drainCancelled = true;
  }

  @override
  Future<ControlledRestartCheckpointResult> waitForControlledRestartCheckpoint({
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    Duration pollInterval =
        SessionRunOrchestrator.controlledRestartCheckpointPollInterval,
    String? requesterSessionId,
    String? requesterToolCallId,
    bool requireRequesterCompletion = false,
  }) async {
    return result;
  }
}

class _SequencedBoundaryOrchestrator extends SessionRunOrchestrator {
  _SequencedBoundaryOrchestrator({
    required this.firstResult,
    required this.nextResult,
  });

  final ControlledRestartCheckpointResult firstResult;
  final Future<ControlledRestartCheckpointResult> nextResult;
  final List<ControlledRestartBlocker> interruptedBlockers = [];
  var calls = 0;
  bool drainCancelled = false;

  @override
  void beginControlledRestartDrain() {}

  @override
  void cancelControlledRestartDrain() {
    drainCancelled = true;
  }

  @override
  Future<void> interruptProviderRequestsForRestart(
    Iterable<ControlledRestartBlocker> blockers,
  ) async {
    interruptedBlockers.addAll(blockers);
  }

  @override
  Future<ControlledRestartCheckpointResult> waitForControlledRestartCheckpoint({
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    Duration pollInterval =
        SessionRunOrchestrator.controlledRestartCheckpointPollInterval,
    String? requesterSessionId,
    String? requesterToolCallId,
    bool requireRequesterCompletion = false,
  }) {
    calls++;
    return calls == 1 ? Future.value(firstResult) : nextResult;
  }
}

class _StopBoundaryOrchestrator extends SessionRunOrchestrator {
  _StopBoundaryOrchestrator(this.checkpoint);

  final Completer<ControlledRestartCheckpointResult> checkpoint;
  bool drainCancelled = false;
  bool stopAllRequested = false;
  bool stopAllPreserveInteractiveWaits = false;

  @override
  void beginControlledRestartDrain() {}

  @override
  void cancelControlledRestartDrain() {
    drainCancelled = true;
  }

  @override
  Future<void> requestStopAll({bool preserveInteractiveWaits = false}) async {
    stopAllRequested = true;
    stopAllPreserveInteractiveWaits = preserveInteractiveWaits;
  }

  @override
  Future<ControlledRestartCheckpointResult> waitForControlledRestartCheckpoint({
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    Duration pollInterval =
        SessionRunOrchestrator.controlledRestartCheckpointPollInterval,
    String? requesterSessionId,
    String? requesterToolCallId,
    bool requireRequesterCompletion = false,
  }) {
    return checkpoint.future;
  }
}
