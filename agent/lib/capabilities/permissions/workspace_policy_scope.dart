import 'workspace_policy_store.dart';

/// The policy key, root and display name of a session's workspace scope.
///
/// A registered workspace is keyed by its UUID. An isolated execution root
/// without a registered workspace is keyed by its `exec_root:` id. A session
/// with neither has no durable policy scope.
class WorkspacePolicyScope {
  const WorkspacePolicyScope({this.id, this.path, this.name});

  final String? id;
  final String? path;
  final String? name;

  /// The root workspace tools operate on for a session: the validated
  /// `execution_root` when one is set, else the registered workspace path.
  /// Policy scope must be derived from this root, never from the workspace
  /// display metadata alone.
  static String? toolRoot(Map<String, dynamic> metadata) {
    String? nonEmpty(Object? value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    final executionRoot = nonEmpty(metadata['execution_root']);
    if (executionRoot != null) return executionRoot;
    final rawWorkspace = metadata['workspace'];
    return rawWorkspace is Map ? nonEmpty(rawWorkspace['path']) : null;
  }

  factory WorkspacePolicyScope.fromMetadata(Map<String, dynamic> metadata) {
    String? nonEmpty(Object? value) {
      final text = value?.toString().trim();
      return text == null || text.isEmpty ? null : text;
    }

    final rawWorkspace = metadata['workspace'];
    final workspace = rawWorkspace is Map
        ? rawWorkspace.cast<String, dynamic>()
        : null;
    final registeredId = nonEmpty(workspace?['id']);
    if (registeredId != null) {
      return WorkspacePolicyScope(
        id: registeredId,
        path: nonEmpty(workspace?['path']),
        name: nonEmpty(workspace?['name']),
      );
    }
    final metadataId = nonEmpty(metadata['workspace_id']);
    final executionRoot = nonEmpty(metadata['execution_root']);
    if (metadataId != null &&
        metadataId.startsWith(WorkspacePolicyStore.execRootPrefix) &&
        executionRoot != null) {
      return WorkspacePolicyScope(
        id: metadataId,
        path: executionRoot,
        name: nonEmpty(metadata['workspace_name']),
      );
    }
    return WorkspacePolicyScope(path: nonEmpty(workspace?['path']));
  }
}
