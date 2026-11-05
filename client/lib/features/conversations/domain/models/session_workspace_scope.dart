/// The workspace identity of a session that executes in an unregistered root.
///
/// A run session (`sanad run --execution-root <path>`) has no registered
/// workspace; its `exec_root:<path>` key names the folder it executes in, not a
/// workspace record. It must stay distinguishable everywhere the Client decides
/// which sidebar group owns a session, because the sidebar only builds groups for
/// registered workspaces plus the ordinary unscoped group: a run session placed
/// in an `exec_root:` page would appear in no group at all.
library;

/// Prefix of an execution-root workspace identity.
const String execRootWorkspacePrefix = 'exec_root:';

/// The workspace identity of a session that executes in [root].
String execRootWorkspaceId(String root) => '$execRootWorkspacePrefix$root';

/// Whether [workspaceId] names an execution root rather than a registered
/// workspace.
bool isExecRootWorkspaceId(String? workspaceId) =>
    workspaceId != null && workspaceId.startsWith(execRootWorkspacePrefix);
