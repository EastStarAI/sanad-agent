import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'agent_maintenance_state_repository.dart';
import 'agent_state_database.dart';
import 'runtime/session_work_item_repository.dart';

enum AgentStateVacuumDecision {
  pending,
  executed,
  throttled,
  belowThreshold,
  failed,
}

class AgentStateMaintenanceResult {
  final int orphanedWorkItemsDeleted;
  final int terminalWorkItemsDeleted;
  final bool terminalPruneRan;
  final AgentStateVacuumDecision vacuumDecision;
  final int reclaimableBytesBeforeVacuum;
  final bool failed;

  const AgentStateMaintenanceResult({
    required this.orphanedWorkItemsDeleted,
    required this.terminalWorkItemsDeleted,
    required this.terminalPruneRan,
    required this.vacuumDecision,
    required this.reclaimableBytesBeforeVacuum,
    this.failed = false,
  });
}

/// Post-ready policy owner for bounded `state.db` maintenance.
///
/// Cleanup waits for runtime idleness and deletes bounded batches while
/// yielding between them. Full `VACUUM` is only marked pending here; the daemon
/// restart owner executes it after a controlled drain and response flush.
class AgentStateMaintenanceService {
  static const terminalWorkItemRetention = Duration(days: 14);
  static const terminalPruneInterval = Duration(hours: 24);
  static const vacuumInterval = Duration(days: 7);
  static const vacuumMinReclaimableBytes = 64 * 1024 * 1024;
  static const vacuumMinFreeRatio = 0.20;
  static const postReadyGracePeriod = Duration(seconds: 30);
  static const idlePollInterval = Duration(seconds: 5);
  static const deleteBatchSize = 25;

  static final Logger _logger = Logger('AgentStateMaintenance');

  final AgentStateDatabase _state;
  final SessionWorkItemRepository _workItems;
  final AgentMaintenanceStateRepository _maintenanceState;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Duration _terminalRetention;
  final Duration _pruneInterval;
  final Duration _vacuumInterval;
  final Duration _initialDelay;
  final Duration _idlePoll;
  final int _batchSize;
  final int _vacuumMinReclaimableBytes;
  final double _vacuumMinFreeRatio;
  final AgentStatePageStatistics Function()? _readPageStatistics;
  final void Function()? _runVacuum;

  AgentStateMaintenanceService(
    this._state, {
    SessionWorkItemRepository? workItems,
    AgentMaintenanceStateRepository? maintenanceState,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Duration? terminalWorkItemRetention,
    Duration? terminalPruneInterval,
    Duration? vacuumInterval,
    Duration? initialDelay,
    Duration? idlePollInterval,
    int? batchSize,
    int? vacuumMinReclaimableBytes,
    double? vacuumMinFreeRatio,
    @visibleForTesting AgentStatePageStatistics Function()? readPageStatistics,
    @visibleForTesting void Function()? runVacuum,
  }) : _workItems = workItems ?? SessionWorkItemRepository(_state),
       _maintenanceState =
           maintenanceState ?? AgentMaintenanceStateRepository(_state),
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed,
       _terminalRetention =
           terminalWorkItemRetention ??
           AgentStateMaintenanceService.terminalWorkItemRetention,
       _pruneInterval =
           terminalPruneInterval ??
           AgentStateMaintenanceService.terminalPruneInterval,
       _vacuumInterval =
           vacuumInterval ?? AgentStateMaintenanceService.vacuumInterval,
       _initialDelay =
           initialDelay ?? AgentStateMaintenanceService.postReadyGracePeriod,
       _idlePoll =
           idlePollInterval ?? AgentStateMaintenanceService.idlePollInterval,
       _batchSize = batchSize ?? AgentStateMaintenanceService.deleteBatchSize,
       _vacuumMinReclaimableBytes =
           vacuumMinReclaimableBytes ??
           AgentStateMaintenanceService.vacuumMinReclaimableBytes,
       _vacuumMinFreeRatio =
           vacuumMinFreeRatio ??
           AgentStateMaintenanceService.vacuumMinFreeRatio,
       _readPageStatistics = readPageStatistics,
       _runVacuum = runVacuum {
    if (_batchSize <= 0) {
      throw ArgumentError.value(_batchSize, 'batchSize', 'Must be positive.');
    }
  }

  /// Runs cleanup only after readiness, the grace period, and runtime idleness.
  /// Activity pauses progress before the next bounded delete batch.
  Future<AgentStateMaintenanceResult> runAfterReady({
    required bool Function() hasRuntimeActivity,
  }) async {
    await _delay(_initialDelay);
    await _waitUntilIdle(hasRuntimeActivity);

    final nowUtc = _clock().toUtc();
    var orphanedDeleted = 0;
    var terminalDeleted = 0;
    var terminalPruneRan = false;
    var orphanFailed = false;

    try {
      final orphanIds = _workItems.findOrphanedWorkItemIds();
      orphanedDeleted = await _deleteInBatches(
        orphanIds,
        hasRuntimeActivity,
        _workItems.deleteOrphanedWorkItemBatch,
      );
    } catch (error, stack) {
      orphanFailed = true;
      _logger.warning(
        'Deferred orphan work-item cleanup failed.',
        error,
        stack,
      );
    }

    final pruneStamp = _maintenanceState.readTerminalPruneSucceededAt(nowUtc);
    if (pruneStamp.isDue(nowUtc, _pruneInterval)) {
      final cutoff = nowUtc.subtract(_terminalRetention);
      try {
        final terminalIds = _workItems.findTerminalWorkItemIdsOlderThan(cutoff);
        terminalDeleted = await _deleteInBatches(
          terminalIds,
          hasRuntimeActivity,
          (ids) => _workItems.deleteTerminalWorkItemBatch(ids, cutoff),
        );
        _maintenanceState.writeTerminalPruneSucceededAt(nowUtc);
        terminalPruneRan = true;
      } catch (error, stack) {
        _logger.warning(
          'Deferred terminal work-item prune failed; it remains due.',
          error,
          stack,
        );
        return AgentStateMaintenanceResult(
          orphanedWorkItemsDeleted: orphanedDeleted,
          terminalWorkItemsDeleted: terminalDeleted,
          terminalPruneRan: false,
          vacuumDecision: AgentStateVacuumDecision.failed,
          reclaimableBytesBeforeVacuum: 0,
          failed: true,
        );
      }
    }

    final vacuumStamp = _maintenanceState.readVacuumSucceededAt(nowUtc);
    if (!vacuumStamp.isDue(nowUtc, _vacuumInterval)) {
      final result = AgentStateMaintenanceResult(
        orphanedWorkItemsDeleted: orphanedDeleted,
        terminalWorkItemsDeleted: terminalDeleted,
        terminalPruneRan: terminalPruneRan,
        vacuumDecision: AgentStateVacuumDecision.throttled,
        reclaimableBytesBeforeVacuum: 0,
        failed: orphanFailed,
      );
      _logResult(result);
      return result;
    }

    final stats = _readPageStatistics?.call() ?? _state.pageStatistics();
    final qualifies =
        stats.reclaimableBytes >= _vacuumMinReclaimableBytes &&
        stats.freeRatio >= _vacuumMinFreeRatio;
    _maintenanceState.writeVacuumPending(qualifies);
    final result = AgentStateMaintenanceResult(
      orphanedWorkItemsDeleted: orphanedDeleted,
      terminalWorkItemsDeleted: terminalDeleted,
      terminalPruneRan: terminalPruneRan,
      vacuumDecision: qualifies
          ? AgentStateVacuumDecision.pending
          : AgentStateVacuumDecision.belowThreshold,
      reclaimableBytesBeforeVacuum: stats.reclaimableBytes,
      failed: orphanFailed,
    );
    _logResult(result);
    return result;
  }

  /// Executes a previously qualified vacuum at the controlled-exit boundary.
  /// Returns without page scans when no pending marker exists.
  AgentStateVacuumDecision runPendingVacuum() {
    if (!_maintenanceState.isVacuumPending()) {
      return AgentStateVacuumDecision.throttled;
    }
    try {
      if (_runVacuum != null) {
        _runVacuum();
      } else {
        _state.vacuum();
      }
      final nowUtc = _clock().toUtc();
      _state.transaction((tx) {
        _maintenanceState.writeVacuumSucceededAt(nowUtc, transaction: tx);
        _maintenanceState.writeVacuumPending(false, transaction: tx);
      });
      _logger.info('Pending state.db VACUUM completed at controlled exit.');
      return AgentStateVacuumDecision.executed;
    } catch (error, stack) {
      _logger.warning(
        'Pending state.db VACUUM failed; it remains pending.',
        error,
        stack,
      );
      return AgentStateVacuumDecision.failed;
    }
  }

  Future<int> _deleteInBatches(
    List<String> ids,
    bool Function() hasRuntimeActivity,
    int Function(Iterable<String>) deleteBatch,
  ) async {
    var deleted = 0;
    for (var offset = 0; offset < ids.length; offset += _batchSize) {
      await _waitUntilIdle(hasRuntimeActivity);
      final end = (offset + _batchSize).clamp(0, ids.length);
      deleted += deleteBatch(ids.sublist(offset, end));
      await _delay(Duration.zero);
    }
    return deleted;
  }

  Future<void> _waitUntilIdle(bool Function() hasRuntimeActivity) async {
    while (hasRuntimeActivity()) {
      await _delay(_idlePoll);
    }
  }

  void _logResult(AgentStateMaintenanceResult result) {
    final didWork =
        result.orphanedWorkItemsDeleted > 0 ||
        result.terminalWorkItemsDeleted > 0 ||
        result.vacuumDecision == AgentStateVacuumDecision.pending;
    if (!didWork) return;
    _logger.info(
      'Agent state maintenance: '
      'orphaned=${result.orphanedWorkItemsDeleted} '
      'terminal=${result.terminalWorkItemsDeleted} '
      'vacuum=${result.vacuumDecision.name} '
      'reclaimableBytes=${result.reclaimableBytesBeforeVacuum}',
    );
  }
}
