/// The workspace identity a session carries when no registered workspace owns
/// it.
///
/// A run session (`sanad run --execution-root <path>`) has no registered
/// workspace: its only targeting is the folder it executes in. Such a session is
/// keyed by `exec_root:<path>` — the same key the permission policy store uses
/// for that root — so it is still addressable as a scope without inventing a
/// workspace record.
///
/// That key names an execution path, never a registered workspace, so it must
/// stay distinguishable everywhere a consumer decides "which workspace owns this
/// session": the session list query groups those sessions with the unscoped
/// ones, and a client renders them in its ordinary unscoped group.
library;

/// Prefix of an execution-root workspace identity.
const String execRootWorkspacePrefix = 'exec_root:';

/// The workspace identity of a session that executes in [root].
String execRootWorkspaceId(String root) => '$execRootWorkspacePrefix$root';

/// Whether [workspaceId] is an execution-root identity rather than a
/// registered workspace.
bool isExecRootWorkspaceId(String? workspaceId) =>
    workspaceId != null && workspaceId.startsWith(execRootWorkspacePrefix);

/// The execution root embedded in [workspaceId], or `null` when it is not an
/// execution-root identity.
String? executionRootOfWorkspaceId(String? workspaceId) {
  if (!isExecRootWorkspaceId(workspaceId)) return null;
  final root = workspaceId!.substring(execRootWorkspacePrefix.length).trim();
  return root.isEmpty ? null : root;
}
