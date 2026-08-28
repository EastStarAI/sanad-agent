import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'session_run_orchestrator.dart';

typedef DaemonExit = void Function(int code);

class DaemonRestartPreparation {
  const DaemonRestartPreparation({
    required this.accepted,
    required this.force,
    required this.timeout,
    this.requesterSessionId,
    this.requesterToolCallId,
    this.blockers = const [],
    this.outcome = 'accepted',
  });

  final bool accepted;
  final bool force;
  final Duration timeout;
  final String? requesterSessionId;
  final String? requesterToolCallId;
  final List<ControlledRestartBlocker> blockers;
  final String outcome;

  Map<String, dynamic> toJson() => {
    'success': accepted,
    'outcome': outcome,
    'force': force,
    'timeout_seconds': timeout.inSeconds,
    if (blockers.isNotEmpty)
      'blockers': blockers.map((blocker) => blocker.toJson()).toList(),
    'message': switch (outcome) {
      'safe' => 'Daemon reached a safe restart checkpoint.',
      'forced' => 'Restart timeout expired. Forced daemon restart accepted.',
      'provider_requests_interrupted' =>
        'Provider requests exceeded the restart timeout and were cancelled without automatic replay.',
      'already_in_progress' => 'Another daemon restart is already in progress.',
      'cancelled' =>
        'Daemon restart was cancelled by a higher-priority action.',
      'internal_error' => 'Restart safety evaluation failed.',
      _ => 'Restart timed out because runtime work is still executing.',
    },
  };
}

/// Owns transport-neutral daemon exits so HTTP and Sanad protocol commands use
/// the same supervised restart behavior.
class DaemonRestartCoordinator {
  DaemonRestartCoordinator({
    SessionRunOrchestrator? sessionOrchestrator,
    DaemonExit? exitDaemon,
  }) : _sessionOrchestrator = sessionOrchestrator,
       _exitDaemon = exitDaemon ?? exit;

  final SessionRunOrchestrator? _sessionOrchestrator;
  final DaemonExit _exitDaemon;
  final Logger _logger = Logger('DaemonRestartCoordinator');
  bool _restartInProgress = false;
  bool _permanentStopRequested = false;
  int _restartEpoch = 0;
  DaemonRestartPreparation? _activePreparation;

  Future<DaemonRestartPreparation> prepareRestart({
    bool force = false,
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    String? requesterSessionId,
    String? requesterToolCallId,
  }) async {
    if (_permanentStopRequested) {
      return DaemonRestartPreparation(
        accepted: false,
        force: force,
        timeout: timeout,
        outcome: 'cancelled',
      );
    }
    if (_restartInProgress) {
      return DaemonRestartPreparation(
        accepted: false,
        force: force,
        timeout: timeout,
        outcome: 'already_in_progress',
      );
    }
    _restartInProgress = true;
    final restartEpoch = ++_restartEpoch;
    final orchestrator = _sessionOrchestrator;
    orchestrator?.beginControlledRestartDrain();
    late final ControlledRestartCheckpointResult checkpoint;
    try {
      checkpoint =
          await orchestrator?.waitForControlledRestartCheckpoint(
            timeout: timeout,
            requesterSessionId: requesterSessionId,
            requesterToolCallId: requesterToolCallId,
          ) ??
          ControlledRestartCheckpointResult.safe;
    } on Object catch (error, stackTrace) {
      _logger.severe('Restart safety evaluation failed.', error, stackTrace);
      if (restartEpoch == _restartEpoch) {
        orchestrator?.cancelControlledRestartDrain();
        _restartInProgress = false;
      }
      return DaemonRestartPreparation(
        accepted: false,
        force: force,
        timeout: timeout,
        requesterSessionId: requesterSessionId,
        requesterToolCallId: requesterToolCallId,
        outcome: restartEpoch == _restartEpoch ? 'internal_error' : 'cancelled',
      );
    }

    if (restartEpoch != _restartEpoch) {
      return DaemonRestartPreparation(
        accepted: false,
        force: force,
        timeout: timeout,
        requesterSessionId: requesterSessionId,
        requesterToolCallId: requesterToolCallId,
        outcome: 'cancelled',
      );
    }

    final providerOnlyTimeout =
        !checkpoint.isSafe &&
        checkpoint.blockers.isNotEmpty &&
        checkpoint.blockers.every(
          (blocker) =>
              blocker.providerRequestInFlight &&
              blocker.toolCallIds.isEmpty &&
              blocker.checkpointRecognized,
        );
    if (providerOnlyTimeout || (!checkpoint.isSafe && force)) {
      await orchestrator?.interruptProviderRequestsForRestart(
        checkpoint.blockers,
      );
    }
    if (!checkpoint.isSafe && !providerOnlyTimeout && !force) {
      orchestrator?.cancelControlledRestartDrain();
      _restartInProgress = false;
      return DaemonRestartPreparation(
        accepted: false,
        force: false,
        timeout: timeout,
        requesterSessionId: requesterSessionId,
        requesterToolCallId: requesterToolCallId,
        blockers: checkpoint.blockers,
        outcome: 'timeout',
      );
    }

    final preparation = DaemonRestartPreparation(
      accepted: true,
      force: force,
      timeout: timeout,
      requesterSessionId: requesterSessionId,
      requesterToolCallId: requesterToolCallId,
      blockers: checkpoint.blockers,
      outcome: checkpoint.isSafe
          ? 'safe'
          : providerOnlyTimeout
          ? 'provider_requests_interrupted'
          : 'forced',
    );
    _activePreparation = preparation;
    return preparation;
  }

  /// Cancels the active preparation when its transport response could not be
  /// flushed. The daemon remains running and queued work is released.
  void abandonPreparedRestart(DaemonRestartPreparation preparation) {
    if (!identical(_activePreparation, preparation)) return;
    _sessionOrchestrator?.cancelControlledRestartDrain();
    _activePreparation = null;
    _restartInProgress = false;
  }

  /// Completes a prepared restart after the transport has flushed its single
  /// response. A normal tool-origin restart then waits for that requester tool
  /// result to become durable before exiting.
  Future<void> completePreparedRestart(
    DaemonRestartPreparation preparation, {
    Duration acknowledgementDelay = Duration.zero,
  }) async {
    if (!preparation.accepted || !identical(_activePreparation, preparation)) {
      return;
    }
    try {
      if (acknowledgementDelay > Duration.zero) {
        await Future<void>.delayed(acknowledgementDelay);
      }

      final requesterSessionId = preparation.requesterSessionId;
      final requesterToolCallId = preparation.requesterToolCallId;
      if (!preparation.force &&
          requesterSessionId != null &&
          requesterToolCallId != null) {
        final requesterCheckpoint =
            await _sessionOrchestrator?.waitForControlledRestartCheckpoint(
              timeout: preparation.timeout,
              requesterSessionId: requesterSessionId,
              requesterToolCallId: requesterToolCallId,
              requireRequesterCompletion: true,
            ) ??
            ControlledRestartCheckpointResult.safe;
        if (!requesterCheckpoint.isSafe) {
          _logger.warning(
            'Restart requester tool did not reach a durable checkpoint; '
            'leaving the daemon running.',
          );
          abandonPreparedRestart(preparation);
          return;
        }
      }

      if (!identical(_activePreparation, preparation)) {
        return;
      }
      _logger.info(
        preparation.outcome == 'forced'
            ? 'Exiting daemon for forced supervised restart...'
            : 'Exiting daemon for supervised restart...',
      );
      _exitDaemon(0);
      _activePreparation = null;
      _restartInProgress = false;
    } on Object catch (error, stackTrace) {
      _logger.severe(
        'Prepared restart completion failed; leaving the daemon running.',
        error,
        stackTrace,
      );
      abandonPreparedRestart(preparation);
    }
  }

  /// Completes a safe preparation as a resumable permanent shutdown.
  ///
  /// The controlled drain remains closed and durable non-terminal work is left
  /// intact for startup recovery. Unlike [stop], this never calls
  /// `requestStopAll()` and therefore never terminally cancels the work.
  Future<void> completePreparedPause(
    DaemonRestartPreparation preparation, {
    Duration acknowledgementDelay = Duration.zero,
  }) async {
    if (!preparation.accepted || !identical(_activePreparation, preparation)) {
      return;
    }
    _permanentStopRequested = true;
    if (acknowledgementDelay > Duration.zero) {
      await Future<void>.delayed(acknowledgementDelay);
    }
    _logger.info('Exiting daemon with resumable work preserved...');
    _exitDaemon(123);
    _activePreparation = null;
    _restartInProgress = false;
  }

  /// Completes a safe restart preparation as a destructive permanent shutdown.
  ///
  /// This legacy path is used when an external launcher deliberately takes
  /// ownership and requires the old runtime work to be cancelled.
  Future<void> completePreparedStop(
    DaemonRestartPreparation preparation, {
    Duration acknowledgementDelay = Duration.zero,
  }) async {
    if (!preparation.accepted || !identical(_activePreparation, preparation)) {
      return;
    }
    if (acknowledgementDelay > Duration.zero) {
      await Future<void>.delayed(acknowledgementDelay);
    }
    await stop(acknowledgementDelay: Duration.zero);
  }

  Future<DaemonRestartPreparation> restart({
    bool force = false,
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    Duration acknowledgementDelay = const Duration(milliseconds: 500),
  }) async {
    final preparation = await prepareRestart(force: force, timeout: timeout);
    await completePreparedRestart(
      preparation,
      acknowledgementDelay: acknowledgementDelay,
    );
    return preparation;
  }

  Future<void> stop({
    Duration acknowledgementDelay = const Duration(milliseconds: 100),
  }) async {
    _permanentStopRequested = true;
    final activePreparation = _activePreparation;
    if (activePreparation != null) {
      abandonPreparedRestart(activePreparation);
    } else if (_restartInProgress) {
      _restartEpoch += 1;
      _sessionOrchestrator?.cancelControlledRestartDrain();
      _restartInProgress = false;
    }
    await _sessionOrchestrator?.requestStopAll();
    await Future<void>.delayed(acknowledgementDelay);
    _logger.info('Exiting daemon permanently...');
    _exitDaemon(123);
  }

  void scheduleRestart({
    bool force = false,
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    Duration acknowledgementDelay = const Duration(milliseconds: 500),
  }) {
    unawaited(
      restart(
        force: force,
        timeout: timeout,
        acknowledgementDelay: acknowledgementDelay,
      ),
    );
  }
}
