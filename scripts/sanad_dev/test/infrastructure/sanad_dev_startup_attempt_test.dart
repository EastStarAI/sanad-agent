import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/startup_attempt.dart';

void main() {
  test(
    'background child launch removes public flag and adds internal mode',
    () {
      expect(
        sanadDevBackgroundChildArguments('/repo/scripts/sanad_dev.dart', const [
          'run',
          '--driver',
          '--background',
          '--home=/tmp/test-home',
        ]),
        const [
          '/repo/scripts/sanad_dev.dart',
          'run',
          '--driver',
          '--home=/tmp/test-home',
          '--internal-background',
        ],
      );
    },
  );

  test(
    'native background child does not pass its executable as an argument',
    () {
      expect(
        sanadDevBackgroundChildArguments('/runtime/sanad-dev-native', const [
          'run',
          '--background',
        ], nativeExecutable: true),
        const ['run', '--internal-background'],
      );
      expect(
        sanadDevUsesNativeRuntimeExecutable(
          executablePath: '/runtime/sanad-dev-native',
          scriptPath: '/runtime/sanad-dev-native',
        ),
        isTrue,
      );
    },
  );

  test('Windows background command preserves paths and arguments safely', () {
    final commandLine = sanadDevWindowsBackgroundCommandLine(
      executable: r"C:\tools\Sanad Agent\sanad-dev.exe",
      arguments: const ['run', 'agent', '--home', r"C:\Home O'Brien"],
      workingDirectory: r"C:\repo O'Brien",
      callerDirectory: r'C:\repo\caller',
    );
    final encoded = commandLine.split(' ').last;
    final bytes = base64Decode(encoded);
    final codeUnits = <int>[
      for (var index = 0; index < bytes.length; index += 2)
        bytes[index] | (bytes[index + 1] << 8),
    ];
    final script = String.fromCharCodes(codeUnits);

    expect(
      commandLine,
      startsWith(
        'powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden',
      ),
    );
    expect(script, contains(r"C:\tools\Sanad Agent\sanad-dev.exe"));
    expect(script, contains(r"C:\Home O''Brien"));
    expect(script, contains(r"C:\repo O''Brien"));
    expect(script, contains(r'$env:SANAD_DEV_CALLER_DIR'));
    expect(script, contains(r'exit $LASTEXITCODE'));
  });

  test(
    'Windows WMI launch script configures invisible startup and working directory',
    () {
      final launchScript = sanadDevWindowsBackgroundLaunchScript(
        commandLine: r"powershell.exe -Command Write-Host 'hi'",
        workingDirectory: r"C:\repo O'Brien",
      );

      expect(
        launchScript,
        contains('New-CimInstance -ClassName Win32_ProcessStartup'),
      );
      expect(launchScript, contains('ShowWindow = [uint16]0'));
      expect(launchScript, contains(r'ProcessStartupInformation = $startup'));
      expect(launchScript, contains(r"CurrentDirectory = 'C:\repo O''Brien'"));
    },
  );

  test('child exit keeps a bounded result-publication grace', () {
    final exitedAt = DateTime.utc(2026, 9, 1, 10);
    expect(
      isSanadDevBackgroundPublicationGraceActive(
        exitedAt,
        now: exitedAt.add(const Duration(milliseconds: 1500)),
      ),
      isTrue,
    );
    expect(
      isSanadDevBackgroundPublicationGraceActive(
        exitedAt,
        now: exitedAt.add(const Duration(seconds: 2)),
      ),
      isFalse,
    );
  });

  test('only a fresh starting attempt projects transitional status', () {
    final attempt = SanadDevStartupAttempt(
      attemptId: 'attempt-transition',
      workspaceHash: 'workspace-transition',
      agentPort: 58090,
      requestedHome: 'worktree-default',
      resolvedHome: '/tmp/home',
      stage: SanadDevStartupStage.readiness,
      outcome: SanadDevStartupOutcome.starting,
      updatedAt: DateTime.utc(2026, 9, 1, 10),
    );

    expect(
      isSanadDevStartupAttemptInProgress(
        attempt,
        now: DateTime.utc(2026, 9, 1, 10, 5),
      ),
      isTrue,
    );
    expect(
      isSanadDevStartupAttemptInProgress(
        attempt,
        now: DateTime.utc(2026, 9, 1, 10, 7),
      ),
      isFalse,
    );
    expect(
      isSanadDevStartupAttemptInProgress(
        attempt.copyWith(outcome: SanadDevStartupOutcome.failed),
        now: DateTime.utc(2026, 9, 1, 10, 1),
      ),
      isFalse,
    );
  });

  test(
    'startup attempt preserves requested and resolved Home identity',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-startup-attempt-',
      );
      addTearDown(() => home.delete(recursive: true));
      final attempt = SanadDevStartupAttempt(
        attemptId: 'attempt-1',
        workspaceHash: 'workspace-1',
        agentPort: 58091,
        requestedHome: 'user',
        resolvedHome: home.path,
        stage: SanadDevStartupStage.preflight,
        outcome: SanadDevStartupOutcome.starting,
        updatedAt: DateTime.utc(2026, 9, 1),
      );

      await writeSanadDevStartupAttempt(attempt);
      final restored = await readSanadDevStartupAttempt(home.path, 58091);

      expect(restored?.requestedHome, 'user');
      expect(restored?.resolvedHome, home.path);
      expect(restored?.stage, SanadDevStartupStage.preflight);
      expect(restored?.outcome, SanadDevStartupOutcome.starting);
    },
  );

  test('failed startup records bounded diagnostic fields', () async {
    final home = await Directory.systemTemp.createTemp(
      'sanad-startup-failure-',
    );
    addTearDown(() => home.delete(recursive: true));
    final failed = SanadDevStartupAttempt(
      attemptId: 'attempt-2',
      workspaceHash: 'workspace-2',
      agentPort: 58092,
      requestedHome: '/requested/home',
      resolvedHome: home.path,
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      updatedAt: DateTime.utc(2026, 9, 1),
      exitStatus: 1,
      failureReason: 'client readiness failed',
    );

    await writeSanadDevStartupAttempt(failed);
    final restored = await readSanadDevStartupAttempt(home.path, 58092);

    expect(restored?.exitStatus, 1);
    expect(restored?.failureReason, 'client readiness failed');
    expect(restored?.outcome, SanadDevStartupOutcome.failed);
  });

  test('worktree locator restores an attempt from an explicit Home', () async {
    final root = await Directory.systemTemp.createTemp(
      'sanad-startup-locator-',
    );
    addTearDown(() => root.delete(recursive: true));
    final home = '${root.path}${Platform.pathSeparator}explicit-home';
    final runtimeDirectory =
        '${root.path}${Platform.pathSeparator}runtime-directory';
    final attempt = SanadDevStartupAttempt(
      attemptId: 'attempt-located',
      workspaceHash: 'workspace-located',
      agentPort: 58093,
      requestedHome: home,
      resolvedHome: home,
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      updatedAt: DateTime.utc(2026, 9, 1),
      exitStatus: 1,
      failureReason: 'agent readiness failed',
    );

    await writeSanadDevStartupAttempt(attempt);
    await writeSanadDevStartupAttemptLocator(
      runtimeDirectory: runtimeDirectory,
      attempt: attempt,
    );
    final restored = await readLocatedSanadDevStartupAttempt(
      runtimeDirectory: runtimeDirectory,
      workspaceHash: 'workspace-located',
    );

    expect(restored?.resolvedHome, home);
    expect(restored?.failureReason, 'agent readiness failed');
  });

  test('unsupported startup attempt versions fail closed', () {
    expect(
      () => SanadDevStartupAttempt.fromJson(const {'version': 99}),
      throwsFormatException,
    );
  });
}
