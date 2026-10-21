import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_scope.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';

import 'direct_execution_backend.dart';
import 'execution_backend.dart';
import 'protected_execution_backend.dart';

/// Selects the backend for one execution from the daemon policy.
///
/// The policy is read at every execution, so an owner's change applies to the
/// next command of the same session without a new session or replay. A
/// command already running keeps the backend it started on.
class ExecutionBackendResolver {
  ExecutionBackendResolver({
    WorkspacePolicyStore? policyStore,
    ExecutionBackend? directBackend,
    ExecutionBackend? protectedBackend,
  }) : _policyStore = policyStore,
       _directBackend = directBackend ?? DirectExecutionBackend(),
       _protectedBackend =
           protectedBackend ?? const ProtectedExecutionBackend();

  static final _logger = Logger('ExecutionBackendResolver');

  final WorkspacePolicyStore? _policyStore;
  final ExecutionBackend _directBackend;
  final ExecutionBackend _protectedBackend;

  /// Selects the backend for a command running in [root] (the canonical
  /// tool root). When [root] is omitted it is derived from the session's
  /// validated execution root.
  Future<ExecutionBackend> resolve(ToolContext? context, {String? root}) async {
    final toolRoot =
        root ?? WorkspacePolicyScope.toolRoot(context?.metadata ?? const {});
    if (toolRoot == null) return _directBackend;
    final EffectiveWorkspacePolicy? effective;
    try {
      effective = await (_policyStore ?? WorkspacePolicyStore()).resolveForRoot(
        toolRoot,
      );
    } catch (error) {
      _logger.warning(
        'Workspace policy read failed (${error.runtimeType}); refusing.',
      );
      return const PolicyUnavailableBackend();
    }
    return switch (effective?.policy.executionMode ?? ExecutionMode.direct) {
      ExecutionMode.direct => _directBackend,
      ExecutionMode.protected => _protectedBackend,
    };
  }
}
