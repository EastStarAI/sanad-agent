import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/runtime_context.dart';

void main() {
  test('worktree ids are readable, stable, and path-specific', () {
    final first = deriveWorktreeId(
      '/workspace/.agent/worktrees/task-a',
      'codex/task-a',
    );
    final repeated = deriveWorktreeId(
      '/workspace/.agent/worktrees/task-a',
      'codex/task-a',
    );
    final second = deriveWorktreeId(
      '/workspace/.agent/worktrees/task-b',
      'codex/task-a',
    );

    expect(first, repeated);
    expect(first, startsWith('codex-task-a-'));
    expect(second, isNot(first));
  });

  test('runtime id sanitization removes path punctuation', () {
    expect(sanitizeRuntimeId('Feature/UI Fix #42'), 'feature-ui-fix-42');
    expect(sanitizeRuntimeId('---'), 'worktree');
  });

  test('linked worktrees receive one worktree-scoped Sanad Home', () {
    final userHome = _absoluteTestPath('users', 'developer');
    final home = resolveSanadDevHome(
      isLinkedWorktree: true,
      userHome: userHome,
      worktreeId: 'task-1234',
      configuredSanadHome: _absoluteTestPath('shared', 'sanad'),
    );

    expect(home, path.join(userHome, '.sanad', 'dev', 'homes', 'task-1234'));
  });

  test('primary checkout preserves the configured Sanad Home', () {
    final userHome = _absoluteTestPath('users', 'developer');
    final configuredHome = _absoluteTestPath('custom', 'main-home');
    expect(
      resolveSanadDevHome(
        isLinkedWorktree: false,
        userHome: userHome,
        worktreeId: 'main-1234',
        configuredSanadHome: configuredHome,
      ),
      configuredHome,
    );
    expect(
      resolveSanadDevHome(
        isLinkedWorktree: false,
        userHome: userHome,
        worktreeId: 'main-1234',
      ),
      path.join(userHome, '.sanad'),
    );
  });

  test(
    'primary, linked, and standalone custom-home resources are distinct',
    () {
      expect(
        resolveUsesPrimarySanadDevResources(isLinkedWorktree: false),
        isTrue,
      );
      expect(
        resolveSanadDevAgentPortStart(
          workspaceRoot: '/primary',
          usesPrimaryResources: true,
        ),
        canonicalPrimaryAgentPort,
      );
      expect(
        resolveUsesPrimarySanadDevResources(isLinkedWorktree: true),
        isFalse,
      );
      expect(
        resolveUsesPrimarySanadDevResources(
          isLinkedWorktree: false,
          sanadHomeOverride: '/isolated/clone-home',
        ),
        isFalse,
      );
      final linkedPort = resolveSanadDevAgentPortStart(
        workspaceRoot: '/repo/.agent/worktrees/task',
        usesPrimaryResources: false,
      );
      final clonePort = resolveSanadDevAgentPortStart(
        workspaceRoot: '/independent/clone',
        usesPrimaryResources: false,
      );
      expect(linkedPort, inInclusiveRange(58086, 58185));
      expect(clonePort, inInclusiveRange(58086, 58185));
      expect(
        resolveSanadDevPreferencesPrefix(
          isLinkedWorktree: false,
          sanadHome: '/isolated/clone-home',
          sanadHomeSelector: '/isolated/clone-home',
        ),
        startsWith('sanad.'),
      );
    },
  );

  test('cloud is enabled by default and can be disabled explicitly', () {
    expect(resolveSanadDevCloudEnabled(const []), isTrue);
    expect(resolveSanadDevCloudEnabled(const ['--cloud']), isTrue);
    expect(resolveSanadDevCloudEnabled(const ['--no-cloud']), isFalse);
    expect(
      resolveSanadDevCloudEnabled(const ['--no-cloud', '--cloud']),
      isTrue,
    );
  });

  test('preferences namespace follows the selected Sanad Home', () {
    final first = resolveSanadDevPreferencesPrefix(
      isLinkedWorktree: true,
      sanadHome: '/isolated/first',
    );
    final repeated = resolveSanadDevPreferencesPrefix(
      isLinkedWorktree: true,
      sanadHome: '/isolated/first',
    );
    final second = resolveSanadDevPreferencesPrefix(
      isLinkedWorktree: true,
      sanadHome: '/isolated/second',
    );

    expect(first, repeated);
    expect(first, startsWith('sanad.'));
    expect(first, isNot(second));
    expect(
      resolveSanadDevPreferencesPrefix(
        isLinkedWorktree: true,
        sanadHome: '/users/developer/.sanad',
        sanadHomeSelector: 'user',
      ),
      isEmpty,
    );
    expect(
      resolveSanadDevPreferencesPrefix(
        isLinkedWorktree: false,
        sanadHome: '/users/developer/.sanad',
      ),
      isEmpty,
    );
  });

  test('unified home environment removes inherited state-home overrides', () {
    final environment = buildUnifiedSanadHomeEnvironment({
      'SANAD_HOME': '/shared/home',
      'SANAD_STATE_HOME': '/legacy/state',
      'PATH': '/bin',
    }, sanadHome: '/isolated/home');

    expect(environment['SANAD_HOME'], '/isolated/home');
    expect(environment.containsKey('SANAD_STATE_HOME'), isFalse);
    expect(environment['PATH'], '/bin');
  });

  test(
    'user or absolute home overrides win and relative paths are rejected',
    () {
      final userHome = _absoluteTestPath('users', 'developer');
      final configuredHome = _absoluteTestPath('configured', 'user-home');
      final isolatedHome = _absoluteTestPath('isolated', 'sanad-home');
      expect(isSanadDevHomeSelector('user'), isTrue);
      expect(isSanadDevHomeSelector(isolatedHome), isTrue);
      expect(isSanadDevHomeSelector(path.join('relative', 'home')), isFalse);
      expect(
        resolveSanadDevHome(
          isLinkedWorktree: true,
          userHome: userHome,
          worktreeId: 'task-1234',
          configuredSanadHome: configuredHome,
          sanadHomeOverride: 'user',
        ),
        configuredHome,
      );
      expect(
        resolveSanadDevHome(
          isLinkedWorktree: true,
          userHome: userHome,
          worktreeId: 'task-1234',
          sanadHomeOverride: 'user',
        ),
        path.join(userHome, '.sanad'),
      );
      expect(
        resolveSanadDevHome(
          isLinkedWorktree: true,
          userHome: userHome,
          worktreeId: 'task-1234',
          sanadHomeOverride: isolatedHome,
        ),
        isolatedHome,
      );
      expect(
        () => resolveSanadDevHome(
          isLinkedWorktree: true,
          userHome: userHome,
          worktreeId: 'task-1234',
          sanadHomeOverride: path.join('relative', 'home'),
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'available-port probe skips an occupied deterministic candidate',
    () async {
      final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(occupied.close);
      final start = occupied.port;

      final selected = await findAvailablePort(
        start: start,
        minimum: start,
        maximum: start + 10,
      );

      expect(selected, isNot(start));
      expect(selected, inInclusiveRange(start + 1, start + 10));
    },
  );

  test('runtime metadata round-trips process and endpoint fields', () async {
    final temp = await Directory.systemTemp.createTemp(
      'sanad-dev-runtime-test',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = SanadDevRuntime(
      workspaceRoot: '/workspace/task',
      repositoryRoot: '/workspace/task/sanad-agent',
      worktreeId: 'task-1234',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58091,
      vmServicePort: 51111,
      sanadHome: '${temp.path}/home',
      runtimeDirectory: '${temp.path}/runtime',
      branch: 'codex/task',
    );

    expect(runtime.toJson()['sanad_home'], '${temp.path}/home');
    expect(runtime.toJson().containsKey('state_home'), isFalse);

    await writeRuntimeRecord(
      runtime,
      runtime.toJson(agentPid: 123, clientPid: 456, status: 'running'),
    );
    final record = await readRuntimeRecord(runtime);

    expect(record, isNotNull);
    expect(record!.agentPid, 123);
    expect(record.clientPid, 456);
    expect(record.agentPort, 58091);
    expect(record.vmServicePort, 51111);
    expect(record.status, 'running');
  });

  test('worktree display name uses the worktree directory leaf', () {
    const runtime = SanadDevRuntime(
      workspaceRoot: '/workspace/.agent/worktrees/ui-status',
      repositoryRoot: '/workspace/.agent/worktrees/ui-status/sanad-agent',
      worktreeId: 'ui-status-1234',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58091,
      vmServicePort: 51111,
      sanadHome: '/tmp/home',
      runtimeDirectory: '/tmp/runtime',
      branch: 'codex/ui-status',
    );

    expect(runtime.worktreeDisplayName, 'ui-status');
  });
}

String _absoluteTestPath(String first, String second) =>
    path.joinAll([Platform.isWindows ? r'C:\' : '/', first, second]);
