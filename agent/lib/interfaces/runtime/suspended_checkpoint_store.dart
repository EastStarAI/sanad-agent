import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

class SuspendedCheckpointStore {
  SuspendedCheckpointStore({SessionManager? sessionManager})
    : _sessionManager = sessionManager;

  SessionManager? _sessionManager;

  SessionManager get _manager => _sessionManager ??= SessionManager();

  Future<void> save(SuspendedCheckpoint checkpoint) async {
    _manager.saveSuspendedCheckpoint(checkpoint);
  }

  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async {
    return _manager.getSuspendedCheckpointByRequestId(requestId);
  }

  Future<List<SuspendedCheckpoint>> listAwaitingPermission() async {
    return _manager.listSuspendedCheckpoints(status: 'awaiting_permission');
  }

  Future<List<SuspendedCheckpoint>> listRecoverable() async {
    return _manager
        .listSuspendedCheckpoints()
        .where(
          (checkpoint) =>
              checkpoint.status == 'awaiting_permission' ||
              checkpoint.status == 'decision_ready' ||
              checkpoint.status == 'executing_tool',
        )
        .toList(growable: false);
  }

  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {
    _manager.updateSuspendedCheckpointStatus(
      requestId: requestId,
      status: status,
    );
  }

  Future<bool> claimDecision({
    required String requestId,
    required String status,
  }) async {
    return _manager.claimSuspendedCheckpointDecision(
      requestId: requestId,
      status: status,
    );
  }

  Future<void> deleteByRequestId(String requestId) async {
    _manager.deleteSuspendedCheckpointByRequestId(requestId);
  }
}
