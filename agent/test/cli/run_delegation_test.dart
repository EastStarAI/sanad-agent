import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/cli/artifacts/run_artifacts.dart';
import 'package:sanad_agent/cli/client/cli_turn_client.dart';
import 'package:sanad_agent/cli/models/cli_events.dart';
import 'package:sanad_agent/cli/oneshot/oneshot_runner.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

class MockDelegationTurnClient extends CliTurnClientBase {
  final _events = StreamController<CliEvent>.broadcast();
  AgentTurnRequest? dispatchedRequest;
  int stopCount = 0;
  String? stoppedSessionId;
  final List<Map<String, dynamic>> permissionResponses = [];
  bool completeTurnImmediately;

  /// Turn-dispatch readiness of the runner under test.
  ///
  /// This is the only safe gate before emitting turn events. `OneshotRunner`
  /// records its initial `running` artifact through
  /// `RunArtifactCoordinator.recordInitial()` first, and only then resolves the
  /// client, subscribes to [eventStream]'s derived streams and calls
  /// [dispatchTurnRequest]. [eventStream] is a broadcast stream, so an event
  /// emitted between those two points has no subscriber, is dropped, and can
  /// never be observed by the run. Waiting for the `running` artifact therefore
  /// makes a test scheduler-dependent instead of deterministic.
  Completer<void> turnDispatched = Completer<void>();

  MockDelegationTurnClient({this.completeTurnImmediately = false});

  /// Whether the runner currently subscribes to this client's event streams.
  bool get hasEventSubscriber => _events.hasListener;

  /// Fails deterministically instead of silently dropping an intervention
  /// event that the run could never observe.
  void _requireEventSubscriber(String emitter) {
    if (_events.hasListener) return;
    fail(
      '$emitter() was called before the run subscribed to turn events. '
      'Gate turn events on the dispatch-readiness signal '
      '(await client.turnDispatched.future) instead of on the initial '
      '`running` artifact, which is recorded before subscription.',
    );
  }

  @override
  Stream<CliEvent> get eventStream => _events.stream;

  @override
  Stream<CliConnectionState> get stateStream => const Stream.empty();

  @override
  Future<String> dispatchTurnRequest(AgentTurnRequest request) async {
    dispatchedRequest = request;
    if (!turnDispatched.isCompleted) {
      turnDispatched.complete();
    }
    if (completeTurnImmediately) {
      scheduleMicrotask(() {
        _events
          ..add(
            CliAssistantChunkEvent(
              content: 'Completed response',
              sessionId: request.sessionId,
            ),
          )
          ..add(
            CliTurnCompleteEvent(
              finalMessage: 'Completed response',
              sessionId: request.sessionId,
            ),
          );
      });
    }
    return request.requestId ?? 'req-dispatch-id';
  }

  @override
  Future<void> stop({required String sessionId, String? runId}) async {
    stopCount++;
    stoppedSessionId = sessionId;
  }

  @override
  Future<void> respondPermission({
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? answer,
    String? comment,
    String? sessionId,
  }) async {
    permissionResponses.add({
      'requestId': requestId,
      'allowed': allowed,
      'decision': decision,
      'sessionId': sessionId,
    });
  }

  void emitChunk(String text, {String? sessionId}) {
    _events.add(CliAssistantChunkEvent(content: text, sessionId: sessionId));
  }

  void emitCancellation({
    String? sessionId,
    String reason = 'Session execution stopped',
  }) {
    _events.add(CliTurnCancelledEvent(reason: reason, sessionId: sessionId));
  }

  void emitError({
    String? sessionId,
    String message = 'Engine error',
    String code = 'engine_error',
    bool isFatal = false,
  }) {
    _events.add(
      CliErrorEvent(
        message: message,
        code: code,
        isFatal: isFatal,
        sessionId: sessionId,
      ),
    );
  }

  void emitUserQuestion({
    required String requestId,
    required String question,
    String? sessionId,
  }) {
    _requireEventSubscriber('emitUserQuestion');
    _events.add(
      CliPermissionRequestEvent(
        requestId: requestId,
        toolName: 'system_ask_user',
        permissionClass: 'user_interaction',
        sessionId: sessionId,
        questions: [
          {'question': question},
        ],
      ),
    );
  }

  void emitToolPermission({
    required String requestId,
    required String toolName,
    String? sessionId,
  }) {
    _requireEventSubscriber('emitToolPermission');
    _events.add(
      CliPermissionRequestEvent(
        requestId: requestId,
        toolName: toolName,
        permissionClass: 'tool_execution',
        sessionId: sessionId,
      ),
    );
  }

  void emitTurnComplete({
    String? sessionId,
    String finalMessage = '',
    String? errorCode,
  }) {
    _events.add(
      CliTurnCompleteEvent(
        finalMessage: finalMessage,
        sessionId: sessionId,
        errorCode: errorCode,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

/// Awaits [predicate] until true (bounded) instead of relying on a fixed sleep.
///
/// The oneshot runner processes incoming events and writes artifacts through a
/// serialized asynchronous queue, so a bare `Future.delayed(...)` is timing
/// dependent and flakes under slow/parallel CI. This helper waits on the actual
/// observable contract condition; it does NOT weaken the caller's assertions,
/// which still verify the precise status/fields after the underlying handler
/// has progressed.
Future<void> waitFor(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('waitFor timed out before the expected contract condition was met');
}

Future<bool> _statusIs(
  Directory outDir,
  String status, {
  String? requestId,
}) async {
  final result = await RunArtifactStore(outDir.path).readResult();
  if (result == null || result.status != status) return false;
  if (requestId != null &&
      result.pendingIntervention?['request_id'] != requestId) {
    return false;
  }
  return true;
}

void main() {
  useIsolatedSanadTestHome();

  group('Sanad Run Delegation and Machine Contract', () {
    late Directory tempDir;
    late Directory outDir;
    late Directory executionDir;
    late MockDelegationTurnClient fakeClient;
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;

    SanadCommandRunner createRunner() {
      return SanadCommandRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        stdinReader: () async => null,
        client: fakeClient,
      );
    }

    setUp(() {
      tempDir = Directory(
        Directory.systemTemp
            .createTempSync('sanad-run-delegation-test-')
            .resolveSymbolicLinksSync(),
      );
      outDir = Directory(p.join(tempDir.path, 'out'))..createSync();
      executionDir = Directory(p.join(tempDir.path, 'worktree'))..createSync();
      fakeClient = MockDelegationTurnClient();
      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
    });

    tearDown(() async {
      await fakeClient.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      '--brief-file reads task prompt and avoids argv prompt exposure',
      () async {
        final briefFile = File(p.join(tempDir.path, 'task_brief.md'))
          ..writeAsStringSync(
            'Execute confidential task instructions.\nLine 2.',
          );

        final runner = createRunner();
        fakeClient.completeTurnImmediately = true;

        final exitCode = await runner.run([
          'run',
          '--brief-file',
          briefFile.path,
          '--session',
          'sess-prealloc-101',
          '--workspace',
          'ws-locked-88',
          '--out-dir',
          outDir.path,
        ]);

        expect(exitCode, equals(0));
        expect(fakeClient.dispatchedRequest, isNotNull);
        expect(
          fakeClient.dispatchedRequest!.message,
          equals('Execute confidential task instructions.\nLine 2.'),
        );
        expect(
          fakeClient.dispatchedRequest!.sessionId,
          equals('sess-prealloc-101'),
        );
        expect(
          fakeClient.dispatchedRequest!.workspaceId,
          equals('ws-locked-88'),
        );
      },
    );

    test(
      'rejects mutually exclusive --brief-file and positional prompt with exit 2',
      () async {
        final briefFile = File(p.join(tempDir.path, 'task_brief.md'))
          ..writeAsStringSync('Execute confidential task instructions.');

        final runner = createRunner();
        final exitCode = await runner.run([
          'run',
          '--brief-file',
          briefFile.path,
          'positional prompt text',
        ]);

        expect(exitCode, equals(2));
        final stderrText = stderrBuf.toString();
        expect(stderrText, contains('--brief-file'));
        expect(stderrText, contains('"positional prompt text"'));
      },
    );

    test(
      'G4: --thinking-mode off is a selectable product option id',
      () async {
        final briefFile = File(p.join(tempDir.path, 'task_brief.md'))
          ..writeAsStringSync('Answer briefly.');
        final runner = createRunner();
        fakeClient.completeTurnImmediately = true;

        final exitCode = await runner.run([
          'run',
          '--brief-file',
          briefFile.path,
          '--thinking-mode',
          'off',
          '--workspace',
          'ws-locked-88',
          '--out-dir',
          outDir.path,
        ]);

        expect(exitCode, equals(0), reason: stderrBuf.toString());
        expect(fakeClient.dispatchedRequest?.thinkingMode, 'off');
      },
    );

    test(
      'G4: a stray positional next to --brief-file names the stray argument '
      'instead of a misleading mutual-exclusion message',
      () async {
        final briefFile = File(p.join(tempDir.path, 'task_brief.md'))
          ..writeAsStringSync('Answer briefly.');
        final runner = createRunner();
        final exitCode = await runner.run([
          'run',
          '--brief-file',
          briefFile.path,
          '--thinking',
          'off',
          '--workspace',
          'ws-locked-88',
        ]);

        expect(exitCode, equals(2));
        final stderrText = stderrBuf.toString();
        expect(stderrText, isNot(contains('Mutually exclusive')));
        expect(stderrText, contains('"off"'));
        expect(fakeClient.dispatchedRequest, isNull);
      },
    );

    test(
      'G3: a pre-dispatch thinking rejection exits non-zero with its reason',
      () async {
        final outDir = Directory(p.join(tempDir.path, 'out-rejected'))
          ..createSync();
        final client = MockDelegationTurnClient();
        final oneshot = OneshotRunner(stdinReader: () async => null);
        final runFuture = oneshot.run(
          prompt: 'hi',
          session: 'sess-rejected',
          thinkingMode: 'none',
          outDir: outDir.path,
          client: client,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );
        await client.turnDispatched.future;
        client.emitTurnComplete(
          sessionId: 'sess-rejected',
          finalMessage:
              'The selected thinking option is unavailable for this route.',
          errorCode: 'thinking_option_unavailable_for_route',
        );

        final exitCode = await runFuture;
        expect(exitCode, isNot(0));
        expect(
          stderrBuf.toString(),
          contains('thinking_option_unavailable_for_route'),
        );
        final result = await RunArtifactStore(outDir.path).readResult();
        expect(result, isNotNull);
        expect(result!.status, 'failed');
        expect(result.exitCode, isNot(0));
        expect(result.error, contains('thinking_option_unavailable_for_route'));
        await client.dispose();
      },
    );

    test('rejects non-existent --brief-file with exit 2', () async {
      final runner = createRunner();
      final exitCode = await runner.run([
        'run',
        '--brief-file',
        p.join(tempDir.path, 'does_not_exist.md'),
      ]);

      expect(exitCode, equals(2));
      expect(stderrBuf.toString(), contains('does not exist'));
    });

    test(
      'rejects non-existent execution root --execution-root with exit 2',
      () async {
        final runner = createRunner();
        final exitCode = await runner.run([
          'run',
          '--execution-root',
          p.join(tempDir.path, 'non_existent_dir'),
          'some prompt',
        ]);

        expect(exitCode, equals(2));
        expect(stderrBuf.toString(), contains('Execution root directory'));
      },
    );

    test(
      'never mutates global Directory.current when --execution-root is passed',
      () async {
        final initialCwd = Directory.current.path;
        final runner = createRunner();
        fakeClient.completeTurnImmediately = true;

        await runner.run([
          'run',
          '--execution-root',
          executionDir.path,
          '--out-dir',
          outDir.path,
          'some prompt',
        ]);

        expect(Directory.current.path, equals(initialCwd));
        expect(
          fakeClient.dispatchedRequest?.metadata['execution_root'],
          equals(executionDir.path),
        );
        expect(fakeClient.dispatchedRequest?.workspaceId, isNull);
        final artifact = RunResultArtifact.fromJson(
          (jsonDecode(
                    File(p.join(outDir.path, 'result.json')).readAsStringSync(),
                  )
                  as Map)
              .cast<String, dynamic>(),
        );
        expect(artifact.workspaceId, isNull);
        expect(artifact.executionRoot, equals(executionDir.path));
      },
    );

    test('requires either --workspace or --execution-root', () async {
      final runner = createRunner();

      final exitCode = await runner.run(['run', 'some prompt']);

      expect(exitCode, equals(2));
      expect(
        stderrBuf.toString(),
        contains('One of --workspace or --execution-root is required'),
      );
      expect(fakeClient.dispatchedRequest, isNull);
    });

    test(
      '--workspace owns conversation while --execution-root targets the worktree',
      () async {
        final runner = createRunner();
        fakeClient.completeTurnImmediately = true;

        final exitCode = await runner.run([
          'run',
          '--workspace',
          'ws-authoritative',
          '--execution-root',
          executionDir.path,
          '--out-dir',
          outDir.path,
          'some prompt',
        ]);

        expect(exitCode, equals(0));
        expect(
          fakeClient.dispatchedRequest?.workspaceId,
          equals('ws-authoritative'),
        );
        expect(
          fakeClient.dispatchedRequest?.metadata['execution_root'],
          equals(executionDir.path),
        );
        final artifact = RunResultArtifact.fromJson(
          (jsonDecode(
                    File(p.join(outDir.path, 'result.json')).readAsStringSync(),
                  )
                  as Map)
              .cast<String, dynamic>(),
        );
        expect(artifact.workspaceId, equals('ws-authoritative'));
        expect(artifact.executionRoot, equals(executionDir.path));
      },
    );

    test(
      'normalizes relative --execution-root to canonical absolute path before dispatch',
      () async {
        final runner = createRunner();
        fakeClient.completeTurnImmediately = true;
        final relativeExecPath = p.relative(
          executionDir.path,
          from: Directory.current.path,
        );

        await runner.run([
          'run',
          '--execution-root',
          relativeExecPath,
          'some prompt',
        ]);

        final dispatchedRoot =
            fakeClient.dispatchedRequest?.metadata['execution_root'] as String?;
        expect(dispatchedRoot, isNotNull);
        expect(p.isAbsolute(dispatchedRoot!), isTrue);
        expect(
          Directory(dispatchedRoot).resolveSymbolicLinksSync(),
          equals(executionDir.resolveSymbolicLinksSync()),
        );
      },
    );

    test(
      'records known session ID and creates result.json and events.jsonl with --out-dir',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Do delegated work',
          session: 'sess-known-42',
          workspace: 'ws-existing-1',
          outDir: outDir.path,
          streamEvents: true,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        // Turn dispatch is the deterministic readiness gate: only after it can
        // the runner's event subscriptions be observed. The `running` artifact
        // is recorded earlier and cannot stand in for subscription readiness.
        await fakeClient.turnDispatched.future.timeout(
          const Duration(seconds: 5),
        );

        final store = RunArtifactStore(outDir.path);
        var midResult = await store.readResult();
        expect(midResult, isNotNull);
        expect(midResult!.status, equals('running'));
        expect(midResult.sessionId, equals('sess-known-42'));
        expect(midResult.workspaceId, equals('ws-existing-1'));

        // Check NDJSON events streamed to stdout
        expect(stdoutBuf.toString(), contains('"type":"running"'));

        // Simulate completion
        fakeClient.emitChunk('Done with work.', sessionId: 'sess-known-42');
        fakeClient.emitTurnComplete(sessionId: 'sess-known-42');

        final exitCode = await runFuture;
        expect(exitCode, equals(0));

        final finalResult = await store.readResult();
        expect(finalResult!.status, equals('completed'));
        expect(finalResult.exitCode, equals(0));
        expect(finalResult.sessionId, equals('sess-known-42'));
        expect(finalResult.text, equals('Done with work.'));
        expect(finalResult.terminalOutput, isNotNull);
        expect(finalResult.terminalOutput!['status'], equals('completed'));

        // Check events.jsonl
        final eventsFile = File(p.join(outDir.path, 'events.jsonl'));
        expect(eventsFile.existsSync(), isTrue);
        final eventLines = await eventsFile.readAsLines();
        expect(eventLines.length, greaterThanOrEqualTo(2));
        expect(eventLines.last, contains('"type":"completed"'));
      },
    );

    test(
      'surfaces non-terminal needs_input and needs_permission events without terminating run',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Supervised work',
          session: 'sess-supervise-1',
          outDir: outDir.path,
          streamEvents: true,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        // Turn dispatch is the deterministic readiness gate for turn events.
        // The initial `running` artifact is recorded before the runner resolves
        // the client and subscribes to its event streams, so gating on it can
        // drop an intervention event that the run would never observe.
        await fakeClient.turnDispatched.future.timeout(
          const Duration(seconds: 5),
        );

        // 1. Emit user question
        fakeClient.emitUserQuestion(
          requestId: 'req-q-1',
          question: 'Which file should be edited?',
          sessionId: 'sess-supervise-1',
        );
        await waitFor(
          () => _statusIs(outDir, 'needs_input', requestId: 'req-q-1'),
        );

        final store = RunArtifactStore(outDir.path);
        var result = await store.readResult();
        expect(result!.status, equals('needs_input'));
        expect(result.pendingIntervention?['request_id'], equals('req-q-1'));
        expect(stdoutBuf.toString(), contains('"type":"needs_input"'));

        // 2. Simulate subsequent turn activity (external answer was provided)
        fakeClient.emitChunk(
          'Resuming with answers.',
          sessionId: 'sess-supervise-1',
        );
        await waitFor(() async {
          final r = await RunArtifactStore(outDir.path).readResult();
          return r?.status == 'running' && r?.pendingIntervention == null;
        });

        result = await store.readResult();
        expect(result!.status, equals('running'));
        expect(result.pendingIntervention, isNull);
        expect(stdoutBuf.toString(), contains('"type":"resumed"'));

        // 3. Emit tool permission request (ordinary permission without --allow-all-tools)
        fakeClient.emitToolPermission(
          requestId: 'req-p-1',
          toolName: 'delete_directory',
          sessionId: 'sess-supervise-1',
        );
        await waitFor(() async {
          final r = await RunArtifactStore(outDir.path).readResult();
          return r?.status == 'needs_permission' &&
              r?.pendingIntervention?['tool_name'] == 'delete_directory';
        });

        result = await store.readResult();
        expect(result!.status, equals('needs_permission'));
        expect(
          result.pendingIntervention?['tool_name'],
          equals('delete_directory'),
        );
        expect(fakeClient.permissionResponses, isEmpty); // Fail-closed

        // 4. Resume and complete
        fakeClient.emitChunk('Tool completed.', sessionId: 'sess-supervise-1');
        fakeClient.emitTurnComplete(sessionId: 'sess-supervise-1');

        final exitCode = await runFuture;
        expect(exitCode, equals(0));
        result = await store.readResult();
        expect(result!.status, equals('completed'));
      },
    );

    test(
      'turn event readiness is the dispatch signal, not the initial running artifact',
      () async {
        // The runner records its `running` artifact before it resolves the
        // client and subscribes to the client's event streams. Holding stdin
        // open keeps that pre-dispatch window open for as long as this test
        // needs it, so the readiness contract is proven deterministically
        // instead of depending on scheduler luck (the reproduced full-suite
        // flake: an intervention event emitted after observing the artifact but
        // before subscription is dropped and can never be observed).
        final stdinGate = Completer<void>();
        final oneshot = OneshotRunner(
          stdinReader: () async {
            await stdinGate.future;
            return null;
          },
        );

        final runFuture = oneshot.run(
          prompt: 'Readiness gate task',
          session: 'sess-ready-1',
          outDir: outDir.path,
          streamEvents: true,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        // 1. The `running` artifact is observable while the run still has no
        //    turn event subscriber, so it cannot gate event emission.
        await waitFor(() => _statusIs(outDir, 'running'));
        expect(fakeClient.hasEventSubscriber, isFalse);

        // 2. Dispatch is the readiness contract: the runner subscribes before
        //    it dispatches, so events emitted from here on are always observed.
        stdinGate.complete();
        await fakeClient.turnDispatched.future.timeout(
          const Duration(seconds: 5),
        );
        expect(fakeClient.hasEventSubscriber, isTrue);

        fakeClient.emitUserQuestion(
          requestId: 'req-ready-1',
          question: 'Which workspace should be used?',
          sessionId: 'sess-ready-1',
        );
        await waitFor(
          () => _statusIs(outDir, 'needs_input', requestId: 'req-ready-1'),
        );

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('needs_input'));
        expect(
          result.pendingIntervention?['request_id'],
          equals('req-ready-1'),
        );

        // 3. Complete the run so the readiness above is not the only outcome.
        fakeClient.emitChunk('Answer received.', sessionId: 'sess-ready-1');
        fakeClient.emitTurnComplete(
          sessionId: 'sess-ready-1',
          finalMessage: 'Readiness gate proven.',
        );
        expect(await runFuture, equals(0));
      },
    );

    test(
      '--allow-all-tools auto-approves ordinary tool permissions but leaves system_ask_user pending',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Auto tools work',
          session: 'sess-auto-1',
          allowAllTools: true,
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future.timeout(
          const Duration(seconds: 5),
        );
        expect(fakeClient.dispatchedRequest?.metadata['allow_all_tools'], isTrue);

        // 1. Emit ordinary tool permission -> auto approved
        fakeClient.emitToolPermission(
          requestId: 'req-perm-auto',
          toolName: 'git_commit',
          sessionId: 'sess-auto-1',
        );
        await waitFor(() async {
          return fakeClient.permissionResponses.length == 1;
        });

        expect(fakeClient.permissionResponses.length, equals(1));
        expect(fakeClient.permissionResponses.first['allowed'], isTrue);
        expect(
          fakeClient.permissionResponses.first['sessionId'],
          equals('sess-auto-1'),
        );

        // 2. Emit clarification question -> NOT auto approved
        fakeClient.emitUserQuestion(
          requestId: 'req-clarify-2',
          question: 'Confirm action?',
          sessionId: 'sess-auto-1',
        );
        await waitFor(() => _statusIs(outDir, 'needs_input'));

        expect(
          fakeClient.permissionResponses.length,
          equals(1),
        ); // Still only 1
        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('needs_input'));

        // Complete
        fakeClient.emitTurnComplete(sessionId: 'sess-auto-1');
        await runFuture;
      },
    );

    test(
      'timeout triggers scoped session stop and records timeout in result.json',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Long running task',
          session: 'sess-timeout-99',
          timeout: const Duration(milliseconds: 100),
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        final exitCode = await runFuture;
        expect(exitCode, equals(124));
        expect(fakeClient.stopCount, equals(1));
        expect(fakeClient.stoppedSessionId, equals('sess-timeout-99'));

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('timeout'));
        expect(result.exitCode, equals(124));
        expect(result.error, contains('timed out'));
        expect(result.terminalOutput?['status'], equals('timeout'));
        expect(result.terminalOutput?['exit_code'], equals(124));
      },
    );

    test(
      'SIGINT signal triggers scoped session stop and records interrupted in result.json',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);
        final signalStream = StreamController<ProcessSignal>();

        final runFuture = oneshot.run(
          prompt: 'Interrupted task',
          session: 'sess-sigint-77',
          signalStream: signalStream.stream,
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future.timeout(
          const Duration(seconds: 5),
        );
        signalStream.add(ProcessSignal.sigint);

        final exitCode = await runFuture;
        expect(exitCode, equals(130));
        expect(fakeClient.stopCount, equals(1));
        expect(fakeClient.stoppedSessionId, equals('sess-sigint-77'));

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('interrupted'));
        expect(result.exitCode, equals(130));
        expect(result.error, contains('SIGINT'));
        expect(result.terminalOutput?['status'], equals('interrupted'));
        expect(result.terminalOutput?['exit_code'], equals(130));

        await signalStream.close();
      },
    );

    test(
      'post-initialization error path produces terminal artifact and preserves exit code',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        // Prompt is empty, producing exit 1
        final exitCode = await oneshot.run(
          prompt: '   ',
          session: 'sess-empty-prompt',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        expect(exitCode, equals(1));
        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result, isNotNull);
        expect(result!.status, equals('failed'));
        expect(result.exitCode, equals(1));
        expect(result.error, contains('No prompt'));
        expect(result.terminalOutput?['status'], equals('failed'));
        expect(result.terminalOutput?['exit_code'], equals(1));
      },
    );

    test(
      'human run without --out-dir does not create any files or artifacts',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Normal human run',
          session: 'sess-human-1',
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future.timeout(
          const Duration(seconds: 5),
        );
        fakeClient.emitChunk('Human response.', sessionId: 'sess-human-1');
        fakeClient.emitTurnComplete(sessionId: 'sess-human-1');

        final exitCode = await runFuture;
        expect(exitCode, equals(0));
        expect(stdoutBuf.toString(), contains('Human response.'));

        // Check that tempDir has no new files in outDir
        final files = outDir.listSync();
        expect(files, isEmpty);
      },
    );

    test(
      'external stop event produces targeted cancelled terminal result (exit 130, status cancelled)',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Task to be stopped',
          session: 'sess-stop-target',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future;
        fakeClient.emitCancellation(
          sessionId: 'sess-stop-target',
          reason: 'Session stopped by operator',
        );

        final exitCode = await runFuture;
        expect(exitCode, equals(130));

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('cancelled'));
        expect(result.exitCode, equals(130));
        expect(result.isCancelled, isTrue);
        expect(result.isTerminal, isTrue);
        expect(result.error, contains('Session stopped by operator'));
        expect(result.terminalOutput?['status'], equals('cancelled'));
        expect(result.terminalOutput?['exit_code'], equals(130));
      },
    );

    test(
      'stop event for another session does not cancel the current session',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'My session task',
          session: 'sess-my-session',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future;

        // Emit cancellation for a DIFFERENT session ID
        fakeClient.emitCancellation(
          sessionId: 'sess-other-session',
          reason: 'Other session stopped',
        );

        // Current session finishes normally
        fakeClient.emitChunk(
          'My session finished.',
          sessionId: 'sess-my-session',
        );
        fakeClient.emitTurnComplete(sessionId: 'sess-my-session');

        final exitCode = await runFuture;
        expect(exitCode, equals(0));

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('completed'));
        expect(result.exitCode, equals(0));
        expect(result.text, equals('My session finished.'));
      },
    );

    test('cancellation does not overwrite prior timeout', () async {
      final oneshot = OneshotRunner(stdinReader: () async => null);

      final runFuture = oneshot.run(
        prompt: 'Timed out task',
        session: 'sess-timeout-race',
        timeout: const Duration(milliseconds: 50),
        outDir: outDir.path,
        client: fakeClient,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
      );

      final exitCode = await runFuture;
      expect(exitCode, equals(124));

      // Late cancellation event after timeout
      fakeClient.emitCancellation(sessionId: 'sess-timeout-race');

      final store = RunArtifactStore(outDir.path);
      final result = await store.readResult();
      expect(result!.status, equals('timeout'));
      expect(result.exitCode, equals(124));
      expect(result.isTimeout, isTrue);
    });

    test('cancellation does not overwrite prior signal interruption', () async {
      final oneshot = OneshotRunner(stdinReader: () async => null);
      final signalStream = StreamController<ProcessSignal>();

      final runFuture = oneshot.run(
        prompt: 'Signal race task',
        session: 'sess-sig-race',
        signalStream: signalStream.stream,
        outDir: outDir.path,
        client: fakeClient,
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
      );

      await fakeClient.turnDispatched.future;
      signalStream.add(ProcessSignal.sigint);

      final exitCode = await runFuture;
      expect(exitCode, equals(130));

      // Late cancellation event after signal
      fakeClient.emitCancellation(sessionId: 'sess-sig-race');

      final store = RunArtifactStore(outDir.path);
      final result = await store.readResult();
      expect(result!.status, equals('interrupted'));
      expect(result.exitCode, equals(130));
      expect(result.isInterrupted, isTrue);

      await signalStream.close();
    });

    test(
      'late cancellation does not overwrite prior turn completion',
      () async {
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Complete race task',
          session: 'sess-complete-race',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future;
        fakeClient.emitChunk('Done', sessionId: 'sess-complete-race');
        fakeClient.emitTurnComplete(sessionId: 'sess-complete-race');

        final exitCode = await runFuture;
        expect(exitCode, equals(0));

        // Late cancellation arrives after completion
        fakeClient.emitCancellation(sessionId: 'sess-complete-race');

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result!.status, equals('completed'));
        expect(result.exitCode, equals(0));
        expect(result.isCompleted, isTrue);
      },
    );

    test(
      'error does not overwrite prior cancellation, and cancellation does not overwrite prior error',
      () async {
        // Case A: Cancellation first
        final storeA = Directory(p.join(tempDir.path, 'out-a'))..createSync();
        final clientA = MockDelegationTurnClient();
        final oneshotA = OneshotRunner(stdinReader: () async => null);

        final runFutureA = oneshotA.run(
          prompt: 'Race A',
          session: 'sess-race-a',
          outDir: storeA.path,
          client: clientA,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await clientA.turnDispatched.future;
        clientA.emitCancellation(sessionId: 'sess-race-a');
        clientA.emitError(sessionId: 'sess-race-a', message: 'Late error');

        final exitCodeA = await runFutureA;
        expect(exitCodeA, equals(130));
        final resultA = await RunArtifactStore(storeA.path).readResult();
        expect(resultA!.status, equals('cancelled'));
        expect(resultA.exitCode, equals(130));

        // Case B: Error first
        final storeB = Directory(p.join(tempDir.path, 'out-b'))..createSync();
        final clientB = MockDelegationTurnClient();
        final oneshotB = OneshotRunner(stdinReader: () async => null);

        final runFutureB = oneshotB.run(
          prompt: 'Race B',
          session: 'sess-race-b',
          outDir: storeB.path,
          client: clientB,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await clientB.turnDispatched.future;
        clientB.emitError(
          sessionId: 'sess-race-b',
          message: 'Initial fatal error',
        );
        clientB.emitCancellation(sessionId: 'sess-race-b');

        final exitCodeB = await runFutureB;
        expect(exitCodeB, equals(1));
        final resultB = await RunArtifactStore(storeB.path).readResult();
        expect(resultB!.status, equals('failed'));
        expect(resultB.exitCode, equals(1));
      },
    );

    test(
      'run fails closed as incomplete (exit 1, cause missing_final) when turn complete arrives with empty/missing final message',
      () async {
        final outDir = Directory(p.join(tempDir.path, 'out-missing-final'))
          ..createSync();
        final fakeClient = MockDelegationTurnClient();
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Execute task',
          session: 'sess-missing-final',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future;
        // Turn completes with no assistant chunks and empty finalMessage
        fakeClient.emitTurnComplete(
          sessionId: 'sess-missing-final',
          finalMessage: '',
        );

        final exitCode = await runFuture;
        expect(exitCode, equals(1));
        expect(
          stderrBuf.toString(),
          contains(
            'Turn execution completed without a final summary (missing final).',
          ),
        );

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result, isNotNull);
        expect(result!.status, equals('incomplete'));
        expect(result.exitCode, equals(1));
        expect(result.cause, equals('missing_final'));
        expect(result.isCompleted, isFalse);
        expect(result.isIncomplete, isTrue);
        expect(result.isTerminal, isTrue);
        expect(result.isSuccess, isFalse);
        expect(result.error, contains('missing final'));

        final events = await store.readEvents();
        expect(events.last.type, equals('incomplete'));
        expect(events.last.data['exit_code'], equals(1));
        expect(events.last.data['cause'], equals('missing_final'));
      },
    );

    test(
      'run fails closed as incomplete (exit 1, cause missing_final) when output contains only mid-progress text',
      () async {
        final outDir = Directory(p.join(tempDir.path, 'out-progress-only'))
          ..createSync();
        final fakeClient = MockDelegationTurnClient();
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Execute task 97f',
          session: 'sess-progress-only',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future;
        // Turn emits only a mid-progress message and completes without a final summary
        fakeClient.emitChunk(
          'running/task-97f',
          sessionId: 'sess-progress-only',
        );
        fakeClient.emitTurnComplete(
          sessionId: 'sess-progress-only',
          finalMessage: '',
        );

        final exitCode = await runFuture;
        expect(exitCode, equals(1));
        expect(
          stderrBuf.toString(),
          contains(
            'Turn execution completed without a final summary (missing final).',
          ),
        );

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result, isNotNull);
        expect(result!.status, equals('incomplete'));
        expect(result.exitCode, equals(1));
        expect(result.cause, equals('missing_final'));
        expect(result.isCompleted, isFalse);
        expect(result.isIncomplete, isTrue);
        expect(result.isTerminal, isTrue);
        expect(result.isSuccess, isFalse);
        expect(result.text, equals('running/task-97f'));
      },
    );

    test(
      'run replaces mid-progress text with authoritative final summary when finalMessage is provided',
      () async {
        final outDir = Directory(p.join(tempDir.path, 'out-progress-replaced'))
          ..createSync();
        final fakeClient = MockDelegationTurnClient();
        final oneshot = OneshotRunner(stdinReader: () async => null);

        final runFuture = oneshot.run(
          prompt: 'Execute task 97f with real summary',
          session: 'sess-progress-replaced',
          outDir: outDir.path,
          client: fakeClient,
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
        );

        await fakeClient.turnDispatched.future;
        // Mid-progress chunk emitted during execution
        fakeClient.emitChunk(
          'running/task-97f',
          sessionId: 'sess-progress-replaced',
        );
        // Final message arrives on turnComplete with substantive summary
        fakeClient.emitTurnComplete(
          sessionId: 'sess-progress-replaced',
          finalMessage:
              'Task 97f completed: event loop unblocked and all tests passed.',
        );

        final exitCode = await runFuture;
        expect(exitCode, equals(0));

        final store = RunArtifactStore(outDir.path);
        final result = await store.readResult();
        expect(result, isNotNull);
        expect(result!.status, equals('completed'));
        expect(result.exitCode, equals(0));
        expect(result.cause, isNull);
        expect(result.isCompleted, isTrue);
        expect(result.isSuccess, isTrue);
        expect(
          result.text,
          equals(
            'Task 97f completed: event loop unblocked and all tests passed.',
          ),
        );
      },
    );
  });
}
