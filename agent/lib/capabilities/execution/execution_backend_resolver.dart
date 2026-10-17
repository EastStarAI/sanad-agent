import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';

import 'direct_execution_backend.dart';
import 'execution_backend.dart';
import 'protected_execution_backend.dart';

/// Resolves the appropriate [ExecutionBackend] dynamically for a workspace.
///
/// Under Plan 83 (Task 83g Gate G3):
/// Reads the latest [WorkspaceSecurityPolicy] from [WorkspacePolicyStore] at the
/// execution boundary. When a user switches execution mode in workspace settings,
/// the very next command executed in the same session immediately adopts the new
/// backend without requiring session restart or command replay.
class ExecutionBackendResolver {
  ExecutionBackendResolver({
    WorkspacePolicyStore? policyStore,
    ExecutionBackend? directBackend,
    ExecutionBackend? protectedBackend,
  }) : _policyStore = policyStore ?? const WorkspacePolicyStore(),
       _directBackend = directBackend ?? DirectExecutionBackend(),
       _protectedBackend = protectedBackend ?? ProtectedExecutionBackend();

  final WorkspacePolicyStore _policyStore;
  final ExecutionBackend _directBackend;
  final ExecutionBackend _protectedBackend;

  /// Resolves the active [ExecutionBackend] for [workspaceId] / [canonicalPath].
  Future<ExecutionBackend> resolveBackend({
    required String workspaceId,
    required String canonicalPath,
  }) async {
    final policy = await _policyStore.readSecurityPolicy(
      workspaceId,
      canonicalPath: canonicalPath,
    );

    switch (policy.executionMode) {
      case ExecutionMode.protected:
        return _protectedBackend;
      case ExecutionMode.direct:
        return _directBackend;
    }
  }
}
