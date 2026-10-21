import 'dart:async';

import 'continuation_checkpoint_coordinator.dart';
import 'run_cancellation_scope.dart';

/// Manages provider request admission, in-flight state tracking,
/// controlled restart draining, and cancellation scopes for the runner.
class RunnerAdmissionGate {
  bool stopRequested = false;
  bool providerRequestInFlight = false;
  Completer<void>? _restartDrainRelease;
  RunCancellationScope? _cancellationScope;

  RunCancellationScope? get cancellationScope => _cancellationScope;

  bool get canPublishRunEvents => _cancellationScope?.isPublicationOpen ?? true;

  void markProviderResponseTerminalCommitted({
    required ContinuationCheckpointCoordinator checkpointCoordinator,
    required CheckpointContext checkpointCtx,
  }) {
    settleProviderRequest(
      checkpointCoordinator: checkpointCoordinator,
      checkpointCtx: checkpointCtx,
    );
  }

  void settleProviderRequest({
    required ContinuationCheckpointCoordinator checkpointCoordinator,
    required CheckpointContext checkpointCtx,
  }) {
    checkpointCoordinator.markModelRequestSettled(ctx: checkpointCtx);
    providerRequestInFlight = false;
  }

  void beginControlledRestartDrain() {
    _restartDrainRelease ??= Completer<void>();
  }

  void cancelControlledRestartDrain() {
    final release = _restartDrainRelease;
    _restartDrainRelease = null;
    if (release != null && !release.isCompleted) release.complete();
  }

  /// Atomically claims permission to invoke the provider after any restart
  /// drain has been released.
  ///
  /// The drain check, [persistInFlightCheckpoint] (the durable
  /// `model_request_in_flight` marker) and the in-memory in-flight marker
  /// deliberately execute without an intervening await. This prevents a
  /// restart safety scan from observing a safe checkpoint after this run has
  /// passed its gate but before it becomes visible as a provider blocker. The
  /// callback runs after any drain wait, so it reads the runner's current
  /// history and checkpoint context rather than values captured before it.
  Future<bool> claimProviderRequestAfterRestartDrain({
    required void Function() persistInFlightCheckpoint,
  }) async {
    while (true) {
      final release = _restartDrainRelease;
      if (release != null) {
        await release.future;
        continue;
      }
      if (stopRequested) return false;
      persistInFlightCheckpoint();
      providerRequestInFlight = true;
      return true;
    }
  }

  void requestStop() {
    stopRequested = true;
    providerRequestInFlight = false;
    cancelControlledRestartDrain();
    _cancellationScope?.invalidate(reason: RunCancellationReason.userStop);
  }

  void resetStopRequested() {
    stopRequested = false;
  }

  void attachCancellationScope(RunCancellationScope scope) {
    _cancellationScope = scope;
  }

  void detachCancellationScope(RunCancellationScope scope) {
    if (identical(_cancellationScope, scope)) {
      _cancellationScope = null;
    }
  }

  void clearCancellationScope() {
    _cancellationScope = null;
  }
}
