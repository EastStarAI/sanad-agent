import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;

const testWorkspaceHash = '2b962b17';
final testClientDirectory = platformNeutralTestPath('/repo/client');

/// Converts a POSIX-style path to the host platform syntax.
///
/// On Windows, absolute POSIX paths (e.g. `/repo/client`) are mapped to the
/// current working drive (e.g. `C:\repo\client`).
String platformNeutralTestPath(String posixPath) {
  if (posixPath.isEmpty) return posixPath;
  if (!Platform.isWindows) return posixPath;
  final normalized = posixPath.replaceAll('/', Platform.pathSeparator);
  if (posixPath.startsWith('/')) {
    final currentRoot = p.rootPrefix(Directory.current.path);
    return p.join(currentRoot, normalized.substring(1));
  }
  return normalized;
}

runtime_context.SanadDevRuntime createTestRuntime({
  String workspaceRoot = '/repo',
  String repositoryRoot = '/repo',
  String worktreeId = 'task-$testWorkspaceHash',
  bool isLinkedWorktree = true,
  bool usesPrimaryResources = false,
  int agentPort = 58092,
  int vmServicePort = 51092,
  String sanadHome = '/isolated/home',
  String runtimeDirectory = '/isolated/runtime',
  String branch = 'codex/task',
  bool platformNeutral = false,
}) {
  return runtime_context.SanadDevRuntime(
    workspaceRoot: platformNeutral
        ? platformNeutralTestPath(workspaceRoot)
        : workspaceRoot,
    repositoryRoot: platformNeutral
        ? platformNeutralTestPath(repositoryRoot)
        : repositoryRoot,
    worktreeId: worktreeId,
    isLinkedWorktree: isLinkedWorktree,
    usesPrimaryResources: usesPrimaryResources,
    agentPort: agentPort,
    vmServicePort: vmServicePort,
    sanadHome: platformNeutral ? platformNeutralTestPath(sanadHome) : sanadHome,
    runtimeDirectory: platformNeutral
        ? platformNeutralTestPath(runtimeDirectory)
        : runtimeDirectory,
    branch: branch,
  );
}

final testLinkedRuntime = createTestRuntime(platformNeutral: true);

final testPrimaryRuntime = createTestRuntime(
  workspaceRoot: '/primary',
  repositoryRoot: '/primary',
  worktreeId: 'main-aabbccdd',
  isLinkedWorktree: false,
  usesPrimaryResources: true,
  agentPort: 58085,
  vmServicePort: 51001,
  sanadHome: '/users/developer/.sanad',
  runtimeDirectory: '/users/developer/.sanad/dev/runtimes/main',
  branch: 'main',
  platformNeutral: true,
);

launch_profile.ClientLaunchProfile testOwnedProfile({
  int gatewayPort = 58092,
  String preferencesPrefix = '',
  bool includeHash = true,
  String sanadHome = '/isolated/home',
  String workspaceHash = testWorkspaceHash,
}) {
  return launch_profile.extractClientLaunchProfile([
    'flutter',
    'run',
    '--dart-define-from-file=config/dev.json',
    '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:$gatewayPort',
    '--dart-define=SANAD_HOME=$sanadHome',
    '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=${preferencesPrefix.isEmpty ? runtime_context.deriveSanadDevPreferencesPrefix(sanadHome) : preferencesPrefix}',
    '--dart-define=SANAD_DEV_WORKTREE_NAME=repo',
    '--dart-define=SANAD_DEV_WORKTREE_BRANCH=codex/task',
    '--dart-define=SANAD_DEV_LAUNCHER_ID=launcher-1',
    '--dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-1',
    if (includeHash) '--dart-define=SANAD_DEV_WORKSPACE_HASH=$workspaceHash',
  ]);
}
