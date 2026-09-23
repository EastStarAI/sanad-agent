import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/cli/artifacts/run_artifacts.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();

  group('RunArtifactStore and RunResultArtifact', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('run-artifacts-test-');
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'RunResultArtifact round-trips to JSON and preserves safe fields without secrets',
      () {
        const artifact = RunResultArtifact(
          sessionId: 'sess-1234',
          workspaceId: 'ws-test',
          executionRoot: '/path/to/exec/root',
          provider: 'OpenCode Go',
          model: 'deepseek-v4-flash',
          status: 'needs_permission',
          exitCode: 0,
          startedAt: '2026-09-22T04:00:00.000Z',
          endedAt: null,
          durationMs: 1200,
          text: 'Waiting for tool approval',
          error: null,
          pendingIntervention: {
            'kind': 'needs_permission',
            'request_id': 'req-99',
            'tool_name': 'bash',
          },
          terminalOutput: {
            'session_id': 'sess-1234',
            'status': 'needs_permission',
            'exit_code': 0,
          },
        );

        expect(artifact.isNeedsIntervention, isTrue);
        expect(artifact.isRunning, isFalse);
        expect(artifact.isCompleted, isFalse);
        expect(artifact.isTerminal, isFalse);

        final json = artifact.toJson();
        expect(json['session_id'], 'sess-1234');
        expect(json['workspace_id'], 'ws-test');
        expect(json['execution_root'], '/path/to/exec/root');
        expect(json['provider'], 'OpenCode Go');
        expect(json['model'], 'deepseek-v4-flash');
        expect(json['status'], 'needs_permission');
        expect(json['pending_intervention']['tool_name'], 'bash');

        // Ensure no raw prompts or secrets
        expect(json.containsKey('prompt'), isFalse);
        expect(json.containsKey('brief'), isFalse);
        expect(json.containsKey('api_key'), isFalse);

        final deserialized = RunResultArtifact.fromJson(json);
        expect(deserialized.sessionId, artifact.sessionId);
        expect(deserialized.workspaceId, artifact.workspaceId);
        expect(deserialized.executionRoot, artifact.executionRoot);
        expect(deserialized.provider, artifact.provider);
        expect(deserialized.model, artifact.model);
        expect(deserialized.status, artifact.status);
        expect(deserialized.durationMs, 1200);
        expect(deserialized.pendingIntervention?['request_id'], 'req-99');
      },
    );

    test(
      'RunArtifactStore publishes complete result.json and appends events.jsonl',
      () async {
        final store = RunArtifactStore(tempDir.path);

        const initialArtifact = RunResultArtifact(
          sessionId: 'sess-abc',
          workspaceId: 'ws-root',
          executionRoot: '/tmp/exec',
          status: 'running',
          startedAt: '2026-09-22T04:00:00.000Z',
        );

        await store.writeResult(initialArtifact);

        final readInitial = await store.readResult();
        expect(readInitial, isNotNull);
        expect(readInitial!.status, 'running');
        expect(readInitial.sessionId, 'sess-abc');
        expect(readInitial.executionRoot, '/tmp/exec');

        // Append lifecycle events
        const event1 = RunLifecycleEvent(
          timestamp: '2026-09-22T04:00:01.000Z',
          type: 'running',
          sessionId: 'sess-abc',
          data: {'workspace_id': 'ws-root'},
        );
        const event2 = RunLifecycleEvent(
          timestamp: '2026-09-22T04:00:05.000Z',
          type: 'completed',
          sessionId: 'sess-abc',
          data: {'exit_code': 0, 'duration_ms': 5000},
        );

        await store.appendEvent(event1);
        await store.appendEvent(event2);

        final eventsFile = File(p.join(tempDir.path, 'events.jsonl'));
        expect(eventsFile.existsSync(), isTrue);
        final lines = await eventsFile.readAsLines();
        expect(lines.length, 2);
        expect(lines[0], contains('"type":"running"'));
        expect(lines[1], contains('"type":"completed"'));
        expect(lines[1], contains('"exit_code":0'));

        // Update terminal result
        final updated = initialArtifact.copyWith(
          status: 'completed',
          exitCode: 0,
          endedAt: '2026-09-22T04:00:05.000Z',
          durationMs: 5000,
          text: 'All done.',
        );
        await store.writeResult(updated);

        final readFinal = await store.readResult();
        expect(readFinal!.status, 'completed');
        expect(readFinal.exitCode, 0);
        expect(readFinal.durationMs, 5000);
        expect(readFinal.text, 'All done.');
      },
    );

    test(
      'RunArtifactCoordinator serializes rapid pending -> resumed -> completed race and ensures terminal wins',
      () async {
        final store = RunArtifactStore(tempDir.path);
        final stdoutBuf = StringBuffer();

        final coordinator = RunArtifactCoordinator(
          store: store,
          streamEvents: true,
          outSink: stdoutBuf,
          sessionId: 'sess-race-1',
          workspaceId: 'ws-race',
          executionRoot: '/tmp/worktree',
          initialProvider: 'OpenCode Go',
          initialModel: 'deepseek-v4-flash',
        );

        // Launch rapid concurrent operations without awaiting between them
        final f0 = coordinator.recordInitial();
        final f1 = coordinator.recordPendingIntervention(
          kind: 'needs_permission',
          requestId: 'req-fast-1',
          toolName: 'shell_execute',
        );
        final f2 = coordinator.recordResumed();
        final f3 = coordinator.recordPendingIntervention(
          kind: 'needs_input',
          requestId: 'req-fast-2',
          questions: [
            {'question': 'Confirm edit?'},
          ],
        );
        final f4 = coordinator.recordTerminal(
          exitCode: 0,
          status: 'completed',
          text: 'Finished successfully after rapid transitions.',
        );
        // Attempt another non-terminal call after terminal has been invoked
        final f5 = coordinator.recordResumed();
        final f6 = coordinator.recordPendingIntervention(
          kind: 'needs_permission',
          requestId: 'req-late',
          toolName: 'ignored_tool',
        );

        // Await all queued tasks and drain coordinator
        await Future.wait([f0, f1, f2, f3, f4, f5, f6]);
        await coordinator.drain();

        // Verify that final result.json is cleanly completed and terminal state won
        final finalResult = await store.readResult();
        expect(finalResult, isNotNull);
        expect(finalResult!.status, equals('completed'));
        expect(finalResult.exitCode, equals(0));
        expect(finalResult.isCompleted, isTrue);
        expect(finalResult.isTerminal, isTrue);
        expect(finalResult.pendingIntervention, isNull);
        expect(finalResult.terminalOutput, isNotNull);
        expect(finalResult.terminalOutput!['status'], equals('completed'));
        expect(finalResult.terminalOutput!['exit_code'], equals(0));
        expect(finalResult.executionRoot, equals('/tmp/worktree'));
        expect(finalResult.provider, equals('OpenCode Go'));
        expect(finalResult.model, equals('deepseek-v4-flash'));

        // Verify events file was written without file-write race corruption
        final eventsFile = File(p.join(tempDir.path, 'events.jsonl'));
        expect(eventsFile.existsSync(), isTrue);
        final eventLines = await eventsFile.readAsLines();
        expect(
          eventLines.map(
            (line) =>
                (jsonDecode(line) as Map<String, dynamic>)['type'] as String,
          ),
          equals([
            'running',
            'needs_permission',
            'resumed',
            'needs_input',
            'completed',
          ]),
        );
      },
    );

    test(
      'RunArtifactCoordinator does not drop or swallow subsequent actions when a store write fails',
      () async {
        final flakyStore = _FlakyArtifactStore(tempDir.path, failOnWrite: 2);
        final coordinator = RunArtifactCoordinator(
          store: flakyStore,
          sessionId: 'sess-recover-1',
          workspaceId: 'ws-recover',
          executionRoot: '/tmp/worktree',
        );

        // 1. Initial succeeds (writeCount = 1)
        await coordinator.recordInitial();
        expect(flakyStore.writeCount, equals(1));

        // 2. Pending intervention fails due to simulated disk failure (writeCount = 2)
        await expectLater(
          coordinator.recordPendingIntervention(
            kind: 'needs_permission',
            requestId: 'req-fail',
          ),
          throwsA(isA<FileSystemException>()),
        );

        // 3. Subsequent terminal action MUST still execute and succeed despite previous failure
        await coordinator.recordTerminal(
          exitCode: 130,
          status: 'cancelled',
          error: 'Session cancelled by user',
        );
        await coordinator.drain();

        expect(flakyStore.writeCount, equals(3));
        final finalResult = await flakyStore.readResult();
        expect(finalResult, isNotNull);
        expect(finalResult!.status, equals('cancelled'));
        expect(finalResult.exitCode, equals(130));
        expect(finalResult.isCancelled, isTrue);
        expect(finalResult.isTerminal, isTrue);
        expect(finalResult.error, equals('Session cancelled by user'));
      },
    );

    test(
      'RunArtifactCoordinator latches terminal state monotonically',
      () async {
        final store = RunArtifactStore(tempDir.path);
        final coordinator = RunArtifactCoordinator(
          store: store,
          sessionId: 'sess-latch-1',
        );

        await coordinator.recordInitial();

        // First terminal call wins
        await coordinator.recordTerminal(
          exitCode: 124,
          status: 'timeout',
          error: 'Timed out',
        );

        // Subsequent terminal call with different status/code must be ignored
        await coordinator.recordTerminal(
          exitCode: 0,
          status: 'completed',
          text: 'Late completion',
        );

        await coordinator.drain();

        final result = await store.readResult();
        expect(result!.status, equals('timeout'));
        expect(result.exitCode, equals(124));
        expect(result.isTimeout, isTrue);
      },
    );

    test('terminal result write failure remains retryable', () async {
      final flakyStore = _FlakyArtifactStore(tempDir.path, failOnWrite: 2);
      final coordinator = RunArtifactCoordinator(
        store: flakyStore,
        sessionId: 'sess-terminal-retry',
      );

      await coordinator.recordInitial();
      await expectLater(
        coordinator.recordTerminal(
          exitCode: 1,
          status: 'failed',
          error: 'Fatal run error',
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(coordinator.isTerminal, isFalse);
      expect(coordinator.currentArtifact.isTerminal, isFalse);

      await coordinator.recordTerminal(
        exitCode: 1,
        status: 'failed',
        error: 'Fatal run error',
      );

      final result = await flakyStore.readResult();
      expect(result!.status, equals('failed'));
      expect(result.terminalOutput?['session_id'], 'sess-terminal-retry');
    });

    test(
      'terminal event failure cannot reopen or overwrite published terminal result',
      () async {
        final flakyStore = _FlakyArtifactStore(
          tempDir.path,
          failOnEventType: 'timeout',
        );
        final coordinator = RunArtifactCoordinator(
          store: flakyStore,
          sessionId: 'sess-terminal-event-fail',
        );

        await coordinator.recordInitial();
        await expectLater(
          coordinator.recordTerminal(
            exitCode: 124,
            status: 'timeout',
            error: 'Timed out',
          ),
          throwsA(isA<FileSystemException>()),
        );

        expect(coordinator.isTerminal, isTrue);
        expect(coordinator.currentArtifact.status, 'timeout');

        await coordinator.recordPendingIntervention(
          kind: 'needs_input',
          requestId: 'late-request',
        );
        await coordinator.recordResumed();
        await coordinator.recordTerminal(exitCode: 0, status: 'completed');

        final result = await flakyStore.readResult();
        expect(result!.status, 'timeout');
        expect(result.exitCode, 124);
      },
    );

    test('cause classification trusts structured codes, not generic prose', () {
      expect(
        RunResultArtifact.classifyCause(
          code: 'timeout',
          message: 'provider request timed out',
        ),
        'provider_timeout',
      );
      expect(
        RunResultArtifact.classifyCause(
          code: 'observer_error',
          message: 'timeout while reading a local log connection',
        ),
        'observer_error',
      );
      expect(
        RunResultArtifact.classifyCause(
          code: 'billing',
          message: 'account action required',
        ),
        'provider_quota',
      );
      expect(
        RunResultArtifact.classifyCause(
          code: 'upstream_rate_limit',
          message: 'retry later',
        ),
        'rate_limit',
      );
    });

    test(
      'RunArtifactCoordinator records nonterminal notices (blocked/waiting/resuming), tracks cause, transitions on progress, and preserves terminal precedence',
      () async {
        final store = RunArtifactStore(tempDir.path);
        final coordinator = RunArtifactCoordinator(
          store: store,
          sessionId: 'sess-nonterminal-1',
          initialProvider: 'OpenCode Go',
          initialModel: 'deepseek-v4-flash',
        );

        await coordinator.recordInitial();
        var current = (await store.readResult())!;
        expect(current.status, 'running');
        expect(current.isTerminal, isFalse);
        expect(current.cause, isNull);

        // 1. Transition to blocked with provider timeout
        await coordinator.recordRuntimeNotice(
          status: 'blocked',
          code: 'timeout',
          message:
              'Notice: Request timed out\n\nProvider response: TimeoutException: generateStream',
          provider: 'OpenCode Go',
          model: 'deepseek-v4-flash',
        );

        current = (await store.readResult())!;
        expect(current.status, 'blocked');
        expect(current.isBlocked, isTrue);
        expect(current.isTerminal, isFalse);
        expect(current.cause, 'provider_timeout');
        expect(
          current.stateSince,
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')),
        );

        var events = await store.readEvents();
        expect(events.length, 2);
        expect(events[1].type, 'blocked');
        expect(events[1].data['cause'], 'provider_timeout');
        expect(events[1].data['code'], 'timeout');

        // 2. Transition to resuming
        await coordinator.recordRuntimeNotice(
          status: 'resuming',
          code: 'resuming',
          message: 'Notice: Resuming…: Retrying the last request.',
          provider: 'OpenCode Go',
          model: 'deepseek-v4-flash',
        );

        current = (await store.readResult())!;
        expect(current.status, 'resuming');
        expect(current.isResuming, isTrue);

        events = await store.readEvents();
        expect(events.length, 3);
        expect(events[2].type, 'resuming');

        // 3. Progress returns session to running and sets lastProgressAt
        await coordinator.recordProgress();
        current = (await store.readResult())!;
        expect(current.status, 'running');
        expect(current.cause, isNull);
        expect(current.lastProgressAt, isNotNull);
        final firstProgressAt = current.lastProgressAt;
        // Streaming callbacks may arrive per token. Progress persistence is
        // bounded instead of rewriting result.json for every callback.
        await coordinator.recordProgress();
        current = (await store.readResult())!;
        expect(current.lastProgressAt, firstProgressAt);

        events = await store.readEvents();
        expect(events.length, 4);
        expect(events[3].type, 'resumed');

        // 4. Terminal completion latches
        await coordinator.recordTerminal(exitCode: 0, status: 'completed');
        current = (await store.readResult())!;
        expect(current.status, 'completed');
        expect(current.isCompleted, isTrue);
        expect(current.isTerminal, isTrue);

        // 5. Subsequent nonterminal notice must NOT overwrite terminal state
        await coordinator.recordRuntimeNotice(
          status: 'blocked',
          code: 'late_notice',
          message: 'Should be ignored',
        );
        current = (await store.readResult())!;
        expect(current.status, 'completed');
      },
    );
  });
}

class _FlakyArtifactStore extends RunArtifactStore {
  int writeCount = 0;
  final int? failOnWrite;
  final String? failOnEventType;

  _FlakyArtifactStore(
    super.artifactsDir, {
    this.failOnWrite,
    this.failOnEventType,
  });

  @override
  Future<void> writeResult(RunResultArtifact artifact) async {
    writeCount++;
    if (writeCount == failOnWrite) {
      throw const FileSystemException('Simulated disk write failure');
    }
    await super.writeResult(artifact);
  }

  @override
  Future<void> appendEvent(RunLifecycleEvent event) async {
    if (event.type == failOnEventType) {
      throw const FileSystemException('Simulated event append failure');
    }
    await super.appendEvent(event);
  }
}
