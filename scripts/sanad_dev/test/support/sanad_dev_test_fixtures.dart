import 'dart:io';

import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;

const testWorkspaceHash = '2b962b17';
final testClientDirectory = '/repo${Platform.pathSeparator}client';

const testLinkedRuntime = runtime_context.SanadDevRuntime(
  workspaceRoot: '/repo',
  repositoryRoot: '/repo',
  worktreeId: 'task-$testWorkspaceHash',
  isLinkedWorktree: true,
  usesPrimaryResources: false,
  agentPort: 58092,
  vmServicePort: 51092,
  sanadHome: '/isolated/home',
  runtimeDirectory: '/isolated/runtime',
  branch: 'codex/task',
);

const testPrimaryRuntime = runtime_context.SanadDevRuntime(
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
