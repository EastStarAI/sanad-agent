import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev/client_launch_profile.dart';
import '../../../../scripts/sanad_dev.dart' as sanad_dev;

void main() {
  const worktreeArguments = [
    'dart',
    'flutter_tools.snapshot',
    'run',
    '-d',
    'macos',
    '--dart-define-from-file=config/dev.json',
    '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58092',
    '--dart-define=ENABLE_CLOUD_GATEWAY=true',
    '--dart-define=SANAD_HOME=/tmp/worktree home',
    '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=sanad.abcd.',
    '--dart-define=SANAD_DEV_WORKTREE_NAME=58-safe-restart-recovery',
    '--dart-define=SANAD_DEV_WORKTREE_BRANCH=codex/task-58-safe-restart-recovery',
    '--host-vmservice-port=51112',
    '-t',
    'lib/driver_main.dart',
  ];

  test('extracts exact argv values including paths with spaces', () {
    final profile = extractClientLaunchProfile(worktreeArguments);

    expect(profile.define('LOCAL_GATEWAY_URL'), 'http://127.0.0.1:58092');
    expect(profile.define('SANAD_HOME'), '/tmp/worktree home');
    expect(
      profile.define('SANAD_SHARED_PREFERENCES_PREFIX'),
      'sanad.abcd.',
    );
    expect(
      profile.define('SANAD_DEV_WORKTREE_NAME'),
      '58-safe-restart-recovery',
    );
    expect(profile.target, 'lib/driver_main.dart');
    expect(
      profile.compileArguments.first,
      '--dart-define-from-file=config/dev.json',
    );
  });

  test('primary IDE profile resolves canonical implicit defaults', () {
    final discovered = extractClientLaunchProfile([
      'dart',
      'flutter_tools.snapshot',
      'run',
      '--machine',
      '-d',
      'macos',
      '--target',
      '/repo/client/lib/main.dart',
      '--dart-define-from-file=config/dev.json',
    ]);
    final profile = withImplicitPrimaryClientDefaults(
      discovered,
      allowed: true,
      primarySanadHome: '/users/dev/.sanad',
    );

    expect(profile.compileArguments, discovered.compileArguments);
    expect(profile.define('LOCAL_GATEWAY_URL'), 'http://127.0.0.1:58085');
    expect(profile.define('SANAD_HOME'), '/users/dev/.sanad');
    expect(profile.define('SANAD_SHARED_PREFERENCES_PREFIX'), '');
    expect(
      validateClientLaunchProfile(
        profile,
        isLinkedWorktree: false,
        expectedWorktreeName: 'primary',
        expectedBranch: 'main',
        expectedAgentPort: 58085,
        emptyPreferencesSanadHome: '/users/dev/.sanad',
        derivePreferencesPrefix: (_) => 'unexpected.',
        canonicalizePath: (path) => path,
      ),
      isNull,
    );
  });

  test('implicit primary defaults never override explicit conflicting identity', () {
    final discovered = extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define-from-file=config/dev.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58086',
    ]);
    final profile = withImplicitPrimaryClientDefaults(
      discovered,
      allowed: true,
      primarySanadHome: '/users/dev/.sanad',
    );

    expect(profile.define('LOCAL_GATEWAY_URL'), 'http://127.0.0.1:58086');
    expect(
      validateClientLaunchProfile(
        profile,
        isLinkedWorktree: false,
        expectedWorktreeName: 'primary',
        expectedBranch: 'main',
        expectedAgentPort: 58085,
        emptyPreferencesSanadHome: '/users/dev/.sanad',
        derivePreferencesPrefix: (_) => 'unexpected.',
        canonicalizePath: (path) => path,
      ),
      contains('targets port 58086'),
    );
  });

  test('implicit primary defaults remain disabled for unsafe runtime identity', () {
    final discovered = extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define-from-file=config/dev.json',
    ]);
    final profile = withImplicitPrimaryClientDefaults(
      discovered,
      allowed: false,
      primarySanadHome: '/users/dev/.sanad',
    );

    expect(
      validateClientLaunchProfile(
        profile,
        isLinkedWorktree: false,
        expectedWorktreeName: 'primary',
        expectedBranch: 'main',
        expectedAgentPort: 58086,
        emptyPreferencesSanadHome: '/users/dev/.sanad',
        derivePreferencesPrefix: (_) => 'unexpected.',
        canonicalizePath: (path) => path,
      ),
      contains('LOCAL_GATEWAY_URL is missing'),
    );
  });

  test('resolves linked and primary client directories without using target path', () {
    final linkedProfile = extractClientLaunchProfile(worktreeArguments);
    final linkedDirectory = resolveClientDirectoryForLaunchProfile(
      profile: linkedProfile,
      runtimeRepositoryRoot: '/repo/.agent/worktrees/58-safe-restart-recovery/sanad-agent',
      runtimeIsLinkedWorktree: true,
      runtimeWorktreeName: '58-safe-restart-recovery',
      separator: '/',
    );
    expect(
      linkedDirectory,
      '/repo/.agent/worktrees/58-safe-restart-recovery/sanad-agent/client',
    );

    final spacedDirectory = resolveClientDirectoryForLaunchProfile(
      profile: linkedProfile,
      runtimeRepositoryRoot: '/repo with spaces/.agent/worktrees/58-safe-restart-recovery/sanad-agent',
      runtimeIsLinkedWorktree: true,
      runtimeWorktreeName: '58-safe-restart-recovery',
      separator: '/',
    );
    expect(
      spacedDirectory,
      '/repo with spaces/.agent/worktrees/58-safe-restart-recovery/sanad-agent/client',
    );

    final primaryProfile = extractClientLaunchProfile([
      'flutter',
      'run',
      '-d',
      'macos',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58085',
    ]);
    final primaryDirectory = resolveClientDirectoryForLaunchProfile(
      profile: primaryProfile,
      runtimeRepositoryRoot: '/repo/.agent/worktrees/58-safe-restart-recovery/sanad-agent',
      runtimeIsLinkedWorktree: true,
      runtimeWorktreeName: '58-safe-restart-recovery',
      separator: '/',
    );
    expect(primaryDirectory, '/repo/client');

    final unknownExternalPrimary = resolveClientDirectoryForLaunchProfile(
      profile: primaryProfile,
      runtimeRepositoryRoot: '/tmp/external-worktree/sanad-agent',
      runtimeIsLinkedWorktree: true,
      runtimeWorktreeName: 'external-worktree',
      separator: '/',
    );
    expect(unknownExternalPrimary, isEmpty);
  });

  test('filters out clients with targets outside repository root', () {
    final externalTargetProfile = extractClientLaunchProfile([
      'flutter',
      'run',
      '-d',
      'macos',
      '--target=/Volumes/Storage/StudioProjects/other-app/lib/main.dart',
    ]);
    final resolvedExternal = resolveClientDirectoryForLaunchProfile(
      profile: externalTargetProfile,
      runtimeRepositoryRoot: '/Volumes/Storage/projects/sanad-agent',
      runtimeIsLinkedWorktree: false,
      runtimeWorktreeName: '',
      separator: '/',
    );
    expect(resolvedExternal, isEmpty);

    final internalTargetProfile = extractClientLaunchProfile([
      'flutter',
      'run',
      '-d',
      'macos',
      '--target=/Volumes/Storage/projects/sanad-agent/client/lib/main.dart',
    ]);
    final resolvedInternal = resolveClientDirectoryForLaunchProfile(
      profile: internalTargetProfile,
      runtimeRepositoryRoot: '/Volumes/Storage/projects/sanad-agent',
      runtimeIsLinkedWorktree: false,
      runtimeWorktreeName: '',
      separator: '/',
    );
    expect(resolvedInternal, '/Volumes/Storage/projects/sanad-agent/client');
  });

  test('attach arguments preserve launch profile and never inject local config', () {
    final profile = extractClientLaunchProfile(worktreeArguments);
    final arguments = buildClientAttachArguments(
      profile: profile,
      vmUrl: 'http://127.0.0.1:51112/',
      deviceId: 'macos',
    );

    expect(arguments.take(4), [
      'attach',
      '-d',
      'macos',
      '--debug-url=http://127.0.0.1:51112/',
    ]);
    expect(arguments, containsAll(profile.compileArguments));
    expect(arguments, containsAll(['-t', 'lib/driver_main.dart']));
    expect(arguments, isNot(contains('--dart-define-from-file=config/local.json')));
  });

  test('development-service matching requires an exact endpoint argument', () {
    expect(
      sanad_dev.matchesFlutterRunnerToDevelopmentService(
        const ['flutter', 'run', '--unrelated=prefix-51330-suffix'],
        devToolsPort: null,
        bindPort: null,
        originalPort: 51330,
      ),
      isFalse,
    );
    expect(
      sanad_dev.matchesFlutterRunnerToDevelopmentService(
        const ['flutter', 'run', '--host-vmservice-port=51330'],
        devToolsPort: null,
        bindPort: null,
        originalPort: 51330,
      ),
      isTrue,
    );
  });

  test('linked worktree profile validates against its matching agent', () {
    final profile = extractClientLaunchProfile(worktreeArguments);

    expect(
      validateClientLaunchProfile(
        profile,
        isLinkedWorktree: true,
        expectedWorktreeName: '58-safe-restart-recovery',
        expectedBranch: 'codex/task-58-safe-restart-recovery',
        expectedAgentPort: 58092,
        emptyPreferencesSanadHome: '/users/dev/.sanad',
        derivePreferencesPrefix: (_) => 'sanad.abcd.',
        canonicalizePath: (path) => path,
      ),
      isNull,
    );
  });

  test('primary checkout profile cannot restart a linked-worktree client', () {
    final primaryProfile = extractClientLaunchProfile([
      'flutter',
      'run',
      '-d',
      'macos',
      '--dart-define-from-file=config/dev.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58085',
      '--dart-define=SANAD_HOME=/users/dev/.sanad',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=',
    ]);

    final error = validateClientLaunchProfile(
      primaryProfile,
      isLinkedWorktree: true,
      expectedWorktreeName: '58-safe-restart-recovery',
      expectedBranch: 'codex/task-58-safe-restart-recovery',
      expectedAgentPort: 58092,
      emptyPreferencesSanadHome: '/users/dev/.sanad',
      derivePreferencesPrefix: (_) => 'sanad.abcd.',
      canonicalizePath: (path) => path,
    );

    expect(error, contains('targets port 58085'));
  });

  test('missing isolation defines fail closed', () {
    final incomplete = extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58092',
    ]);

    expect(
      validateClientLaunchProfile(
        incomplete,
        isLinkedWorktree: true,
        expectedWorktreeName: 'task',
        expectedBranch: 'codex/task',
        expectedAgentPort: 58092,
        emptyPreferencesSanadHome: '/users/dev/.sanad',
        derivePreferencesPrefix: (_) => 'sanad.abcd.',
        canonicalizePath: (path) => path,
      ),
      contains('SANAD_HOME is missing'),
    );
  });

  test('standalone isolated profile requires the matching workspace hash', () {
    final missing = extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define-from-file=config/dev.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58092',
      '--dart-define=SANAD_HOME=/isolated/clone',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=sanad.clone.',
    ]);
    final mismatched = extractClientLaunchProfile([
      ...missing.compileArguments,
      '--dart-define=SANAD_DEV_WORKSPACE_HASH=other',
    ]);

    String? validate(ClientLaunchProfile profile) => validateClientLaunchProfile(
      profile,
      isLinkedWorktree: false,
      expectedWorktreeName: 'clone',
      expectedBranch: 'main',
      expectedWorkspaceHash: 'expected',
      workspaceHashRequired: true,
      expectedAgentPort: 58092,
      emptyPreferencesSanadHome: '/users/dev/.sanad',
      derivePreferencesPrefix: (_) => 'sanad.clone.',
      canonicalizePath: (path) => path,
    );

    expect(validate(missing), contains('WORKSPACE_HASH is missing'));
    expect(validate(mismatched), contains('does not match'));
  });

  test('null-delimited argv preserves paths with spaces', () {
    final arguments = splitNullTerminatedArguments(
      'flutter\u0000run\u0000--dart-define=SANAD_HOME=/Users/Dev User/.sanad\u0000'.codeUnits,
    );

    expect(
      arguments,
      contains('--dart-define=SANAD_HOME=/Users/Dev User/.sanad'),
    );
  });

  test('linked global or custom home remains valid with derived prefix', () {
    final profile = extractClientLaunchProfile(worktreeArguments);
    final error = validateClientLaunchProfile(
      profile,
      isLinkedWorktree: true,
      expectedWorktreeName: '58-safe-restart-recovery',
      expectedBranch: 'codex/task-58-safe-restart-recovery',
      expectedAgentPort: 58092,
      emptyPreferencesSanadHome: '/users/dev/.sanad',
      derivePreferencesPrefix: (home) => home == '/tmp/worktree home' ? 'sanad.abcd.' : 'wrong.',
      canonicalizePath: (path) => path,
    );
    expect(error, isNull);
  });

  test('linked --home user keeps the primary empty namespace', () {
    final profile = extractClientLaunchProfile([
      ...worktreeArguments.where(
        (argument) =>
            !argument.startsWith('--dart-define=SANAD_HOME=') &&
            !argument.startsWith(
              '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=',
            ),
      ),
      '--dart-define=SANAD_HOME=/users/dev/.sanad',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=',
    ]);
    final error = validateClientLaunchProfile(
      profile,
      isLinkedWorktree: true,
      expectedWorktreeName: '58-safe-restart-recovery',
      expectedBranch: 'codex/task-58-safe-restart-recovery',
      expectedAgentPort: 58092,
      emptyPreferencesSanadHome: '/users/dev/.sanad',
      derivePreferencesPrefix: (_) => 'must-not-be-used.',
      canonicalizePath: (path) => path,
    );
    expect(error, isNull);
  });

  test('primary default or global home keeps empty namespace', () {
    final profile = extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define-from-file=config/dev.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58085',
      '--dart-define=SANAD_HOME=/global/sanad home',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=',
    ]);
    final error = validateClientLaunchProfile(
      profile,
      isLinkedWorktree: false,
      expectedWorktreeName: 'primary',
      expectedBranch: 'main',
      expectedAgentPort: 58085,
      emptyPreferencesSanadHome: '/global/sanad home',
      derivePreferencesPrefix: (_) => 'must-not-be-used.',
      canonicalizePath: (path) => path,
    );
    expect(error, isNull);
  });

  test('primary explicit custom home requires its derived namespace', () {
    final profile = extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define-from-file=config/dev.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58085',
      '--dart-define=SANAD_HOME=/custom/sanad home',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=sanad.custom.',
    ]);
    final error = validateClientLaunchProfile(
      profile,
      isLinkedWorktree: false,
      expectedWorktreeName: 'primary',
      expectedBranch: 'main',
      expectedAgentPort: 58085,
      emptyPreferencesSanadHome: '/users/dev/.sanad',
      derivePreferencesPrefix: (home) => home == '/custom/sanad home' ? 'sanad.custom.' : 'wrong.',
      canonicalizePath: (path) => path,
    );
    expect(error, isNull);
  });

  test('mismatched preferences prefix fails closed', () {
    final profile = extractClientLaunchProfile(worktreeArguments);
    final error = validateClientLaunchProfile(
      profile,
      isLinkedWorktree: true,
      expectedWorktreeName: '58-safe-restart-recovery',
      expectedBranch: 'codex/task-58-safe-restart-recovery',
      expectedAgentPort: 58092,
      emptyPreferencesSanadHome: '/users/dev/.sanad',
      derivePreferencesPrefix: (_) => 'sanad.other.',
      canonicalizePath: (path) => path,
    );
    expect(error, contains('SANAD_SHARED_PREFERENCES_PREFIX does not match'));
  });

  test('macOS procargs parser preserves argument boundaries', () {
    final payload = <int>[
      3,
      0,
      0,
      0,
      ...'/usr/bin/dart'.codeUnits,
      0,
      0,
      ...'dart'.codeUnits,
      0,
      ...'flutter run'.codeUnits,
      0,
      ...'--dart-define=SANAD_HOME=/Users/Dev User/.sanad'.codeUnits,
      0,
    ];
    expect(parseMacOsProcessArguments(payload), [
      'dart',
      'flutter run',
      '--dart-define=SANAD_HOME=/Users/Dev User/.sanad',
    ]);
  });

  test('macOS candidate seam invokes native argv reader for every pid', () async {
    final invoked = <int>[];
    final values = await readMacOsCandidateArguments([11, 22], (pid) async {
      invoked.add(pid);
      return pid == 22 ? ['dart', 'flutter_tools.snapshot', 'run'] : const [];
    });

    expect(invoked, [11, 22]);
    expect(values, {
      22: ['dart', 'flutter_tools.snapshot', 'run'],
    });
  });

  test(
    'macOS native reader returns current process argv through libc sysctl',
    () {
      final arguments = readMacOsProcessArguments(pid);
      expect(arguments, isNotEmpty);
      expect(arguments.join(' '), contains('flutter_test'));
    },
    skip: !Platform.isMacOS,
  );
}
