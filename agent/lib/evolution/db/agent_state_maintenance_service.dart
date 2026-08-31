import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'agent_maintenance_state_repository.dart';
import 'agent_state_database.dart';
import 'runtime/session_work_item_repository.dart';

enum AgentStateVacuumDecision { executed, throttled, belowThreshold, failed }

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

/// Startup-only policy owner for `state.db` maintenance.
///
/// Uses production retention and vacuum thresholds by default. Clock,
/// durations, and thresholds are injectable for tests and must not become
/// user-facing settings.
class AgentStateMaintenanceService {
  static const terminalWorkItemRetention = Duration(days: 14);
  static const terminalPruneInterval = Duration(hours: 24);
  static const vacuumInterval = Duration(days: 7);
  static const vacuumMinReclaimableBytes = 64 * 1024 * 1024;
  static const vacuumMinFreeRatio = 0.20;

  static final Logger _logger = Logger('AgentStateMaintenance');

  final AgentStateDatabase _state;
  final SessionWorkItemRepository _workItems;
  final AgentMaintenanceStateRepository _maintenanceState;
  final DateTime Function() _clock;
  final Duration _terminalRetention;
  final Duration _pruneInterval;
  final Duration _vacuumInterval;
  final int _vacuumMinReclaimableBytes;
  final double _vacuumMinFreeRatio;
  final AgentStatePageStatistics Function()? _readPageStatistics;
  final void Function()? _runVacuum;

  AgentStateMaintenanceService(
    this._state, {
    SessionWorkItemRepository? workItems,
    AgentMaintenanceStateRepository? maintenanceState,
    DateTime Function()? clock,
    Duration? terminalWorkItemRetention,
    Duration? terminalPruneInterval,
    Duration? vacuumInterval,
    int? vacuumMinReclaimableBytes,
    double? vacuumMinFreeRatio,
    @visibleForTesting AgentStatePageStatistics Function()? readPageStatistics,
    @visibleForTesting void Function()? runVacuum,
  }) : _workItems = workItems ?? SessionWorkItemRepository(_state),
       _maintenanceState =
           maintenanceState ?? AgentMaintenanceStateRepository(_state),
       _clock = clock ?? DateTime.now,
       _terminalRetention =
           terminalWorkItemRetention ??
           AgentStateMaintenanceService.terminalWorkItemRetention,
       _pruneInterval =
           terminalPruneInterval ??
           AgentStateMaintenanceService.terminalPruneInterval,
       _vacuumInterval =
           vacuumInterval ?? AgentStateMaintenanceService.vacuumInterval,
       _vacuumMinReclaimableBytes =
           vacuumMinReclaimableBytes ??
           AgentStateMaintenanceService.vacuumMinReclaimableBytes,
       _vacuumMinFreeRatio =
           vacuumMinFreeRatio ??
           AgentStateMaintenanceService.vacuumMinFreeRatio,
       _readPageStatistics = readPageStatistics,
       _runVacuum = runVacuum;

  AgentStateMaintenanceResult run() {
    final nowUtc = _clock().toUtc();
    var orphanedDeleted = 0;
    var terminalDeleted = 0;
    var terminalPruneRan = false;
    var pruneFailed = false;
    var orphanFailed = false;

    try {
      orphanedDeleted = _workItems.cleanupOrphanedWorkItems();
    } catch (error, stack) {
      orphanFailed = true;
      _logger.warning('Orphan work-item cleanup failed.', error, stack);
    }

    final pruneStamp = _maintenanceState.readTerminalPruneSucceededAt(nowUtc);
    if (pruneStamp.isDue(nowUtc, _pruneInterval)) {
      final cutoff = nowUtc.subtract(_terminalRetention);
      try {
        terminalDeleted = _state.transaction((tx) {
          final deleted = _workItems.deleteTerminalWorkItemsOlderThan(
            cutoff,
            transaction: tx,
          );
          _maintenanceState.writeTerminalPruneSucceededAt(
            nowUtc,
            transaction: tx,
          );
          return deleted;
        });
        terminalPruneRan = true;
      } catch (error, stack) {
        _logger.warning(
          'Terminal work-item prune failed; transaction rolled back.',
          error,
          stack,
        );
        pruneFailed = true;
      }
    }

    if (pruneFailed) {
      final failed = AgentStateMaintenanceResult(
        orphanedWorkItemsDeleted: orphanedDeleted,
        terminalWorkItemsDeleted: 0,
        terminalPruneRan: false,
        vacuumDecision: AgentStateVacuumDecision.failed,
        reclaimableBytesBeforeVacuum: 0,
        failed: true,
      );
      return failed;
    }

    final stats = _readPageStatistics?.call() ?? _state.pageStatistics();
    final vacuumStamp = _maintenanceState.readVacuumSucceededAt(nowUtc);
    late final AgentStateVacuumDecision vacuumDecision;
    if (!vacuumStamp.isDue(nowUtc, _vacuumInterval)) {
      vacuumDecision = AgentStateVacuumDecision.throttled;
    } else if (stats.reclaimableBytes < _vacuumMinReclaimableBytes ||
        stats.freeRatio < _vacuumMinFreeRatio) {
      vacuumDecision = AgentStateVacuumDecision.belowThreshold;
    } else {
      try {
        if (_runVacuum != null) {
          _runVacuum();
        } else {
          _state.vacuum();
        }
        _maintenanceState.writeVacuumSucceededAt(nowUtc);
        vacuumDecision = AgentStateVacuumDecision.executed;
      } catch (error, stack) {
        _logger.warning('state.db VACUUM failed.', error, stack);
        vacuumDecision = AgentStateVacuumDecision.failed;
      }
    }

    final result = AgentStateMaintenanceResult(
      orphanedWorkItemsDeleted: orphanedDeleted,
      terminalWorkItemsDeleted: terminalDeleted,
      terminalPruneRan: terminalPruneRan,
      vacuumDecision: vacuumDecision,
      reclaimableBytesBeforeVacuum: stats.reclaimableBytes,
      failed: orphanFailed || vacuumDecision == AgentStateVacuumDecision.failed,
    );
    _logResult(result);
    return result;
  }

  void _logResult(AgentStateMaintenanceResult result) {
    final didWork =
        result.orphanedWorkItemsDeleted > 0 ||
        result.terminalWorkItemsDeleted > 0 ||
        result.vacuumDecision == AgentStateVacuumDecision.executed;
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

/// Daemon-owned containment wrapper: swallows unexpected maintenance errors
/// so durable restore and platform start continue. `agent/bin/daemon.dart`
/// must call this once per boot after DI and logging, and before
/// orchestrator attach, restore, and gateway start.
void runAgentStateMaintenanceSafely(
  AgentStateMaintenanceService service, {
  Logger? logger,
}) {
  try {
    service.run();
  } catch (error, stack) {
    (logger ?? Logger('DaemonStartup')).warning(
      'Agent state maintenance failed; durable restore continues.',
      error,
      stack,
    );
  }
}
