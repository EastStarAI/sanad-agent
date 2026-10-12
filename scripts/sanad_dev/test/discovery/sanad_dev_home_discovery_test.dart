import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:sanad_dev/src/infrastructure/secure_runtime_file.dart'
    as secure_runtime_file;
import 'package:sanad_dev/src/infrastructure/startup_attempt.dart'
    as startup_attempt;

void main() {
  test(
    'gateway discovery includes homes recorded by sibling runtimes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'sanad-candidate-homes-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final siblingHome = '${temp.path}${Platform.pathSeparator}sibling-home';
      final runtimeRoot = '${temp.path}${Platform.pathSeparator}runtimes';
      final current = runtime_context.SanadDevRuntime(
        workspaceRoot: '/repo/current',
        repositoryRoot: '/repo/current',
        worktreeId: 'current',
        isLinkedWorktree: true,
        usesPrimaryResources: false,
        agentPort: 58092,
        vmServicePort: 51092,
        sanadHome: '${temp.path}${Platform.pathSeparator}current-home',
        runtimeDirectory: '$runtimeRoot${Platform.pathSeparator}current',
        branch: 'codex/current',
      );
      final sibling = runtime_context.SanadDevRuntime(
        workspaceRoot: '/repo/sibling',
        repositoryRoot: '/repo/sibling',
        worktreeId: 'sibling',
        isLinkedWorktree: true,
        usesPrimaryResources: false,
        agentPort: 58093,
        vmServicePort: 51093,
        sanadHome: siblingHome,
        runtimeDirectory: '$runtimeRoot${Platform.pathSeparator}sibling',
        branch: 'codex/sibling',
      );
      await runtime_context.writeRuntimeRecord(sibling, sibling.toJson());

      final homes = await sanad_dev.discoverLocalGatewayCandidateHomes(current);

      expect(homes, contains(current.sanadHome));
      expect(homes, contains(siblingHome));
    },
  );

  test('gateway discovery restores the active explicit Home locator', () async {
    final temp = await Directory.systemTemp.createTemp(
      'sanad-active-home-locator-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final customHome = '${temp.path}${Platform.pathSeparator}custom-home';
    final runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo/current',
      repositoryRoot: '/repo/current',
      worktreeId: 'main-aabbccdd',
      isLinkedWorktree: false,
      usesPrimaryResources: true,
      agentPort: 58085,
      vmServicePort: 51085,
      sanadHome: '${temp.path}${Platform.pathSeparator}default-home',
      runtimeDirectory:
          '${temp.path}${Platform.pathSeparator}runtimes${Platform.pathSeparator}main',
      branch: 'main',
    );
    final attempt = startup_attempt.SanadDevStartupAttempt(
      attemptId: 'attempt-1',
      workspaceHash: 'aabbccdd',
      agentPort: 58091,
      requestedHome: customHome,
      resolvedHome: customHome,
      stage: startup_attempt.SanadDevStartupStage.managed,
      outcome: startup_attempt.SanadDevStartupOutcome.managed,
      updatedAt: DateTime.now().toUtc(),
    );
    await startup_attempt.writeSanadDevStartupAttempt(attempt);
    await startup_attempt.writeSanadDevStartupAttemptLocator(
      runtimeDirectory: runtime.runtimeDirectory,
      attempt: attempt,
    );

    final homes = await sanad_dev.discoverLocalGatewayCandidateHomes(runtime);

    expect(await sanad_dev.inferPostLaunchSanadHome(runtime), customHome);
    expect(homes, contains(customHome));
  });

  test('explicit Home restricts gateway credential discovery', () async {
    final temp = await Directory.systemTemp.createTemp('sanad-explicit-home-');
    addTearDown(() => temp.delete(recursive: true));
    final explicitHome = '${temp.path}${Platform.pathSeparator}explicit-home';
    final runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo/current',
      repositoryRoot: '/repo/current',
      worktreeId: 'main-aabbccdd',
      isLinkedWorktree: false,
      usesPrimaryResources: false,
      agentPort: 58091,
      vmServicePort: 51091,
      sanadHome: explicitHome,
      runtimeDirectory:
          '${temp.path}${Platform.pathSeparator}runtimes${Platform.pathSeparator}main',
      branch: 'main',
    );

    final homes = await sanad_dev.discoverLocalGatewayCandidateHomes(
      runtime,
      sanadHomeOverride: explicitHome,
    );

    expect(homes, equals({explicitHome}));
  });

  test('foreign active Home locator is ignored', () async {
    final temp = await Directory.systemTemp.createTemp(
      'sanad-foreign-home-locator-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final foreignHome = '${temp.path}${Platform.pathSeparator}foreign-home';
    final runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo/current',
      repositoryRoot: '/repo/current',
      worktreeId: 'main-aabbccdd',
      isLinkedWorktree: false,
      usesPrimaryResources: true,
      agentPort: 58085,
      vmServicePort: 51085,
      sanadHome: '${temp.path}${Platform.pathSeparator}default-home',
      runtimeDirectory:
          '${temp.path}${Platform.pathSeparator}runtimes${Platform.pathSeparator}main',
      branch: 'main',
    );
    final attempt = startup_attempt.SanadDevStartupAttempt(
      attemptId: 'attempt-1',
      workspaceHash: 'different-hash',
      agentPort: 58091,
      requestedHome: foreignHome,
      resolvedHome: foreignHome,
      stage: startup_attempt.SanadDevStartupStage.managed,
      outcome: startup_attempt.SanadDevStartupOutcome.managed,
      updatedAt: DateTime.now().toUtc(),
    );
    await startup_attempt.writeSanadDevStartupAttempt(attempt);
    await startup_attempt.writeSanadDevStartupAttemptLocator(
      runtimeDirectory: runtime.runtimeDirectory,
      attempt: attempt,
    );

    final homes = await sanad_dev.discoverLocalGatewayCandidateHomes(runtime);

    expect(await sanad_dev.inferPostLaunchSanadHome(runtime), isNull);
    expect(homes, isNot(contains(foreignHome)));
  });

  test('malformed active Home locator is ignored', () async {
    final temp = await Directory.systemTemp.createTemp(
      'sanad-malformed-home-locator-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final defaultHome = '${temp.path}${Platform.pathSeparator}default-home';
    final runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo/current',
      repositoryRoot: '/repo/current',
      worktreeId: 'main-aabbccdd',
      isLinkedWorktree: false,
      usesPrimaryResources: true,
      agentPort: 58085,
      vmServicePort: 51085,
      sanadHome: defaultHome,
      runtimeDirectory:
          '${temp.path}${Platform.pathSeparator}runtimes${Platform.pathSeparator}main',
      branch: 'main',
    );
    await secure_runtime_file.secureRuntimeAtomicWrite(
      runtime.runtimeDirectory,
      startup_attempt.sanadDevStartupAttemptLocatorPath(
        runtime.runtimeDirectory,
      ),
      '{"version":1,"resolved_home":42}',
    );

    final homes = await sanad_dev.discoverLocalGatewayCandidateHomes(runtime);

    expect(await sanad_dev.inferPostLaunchSanadHome(runtime), isNull);
    expect(homes, contains(defaultHome));
  });
}
