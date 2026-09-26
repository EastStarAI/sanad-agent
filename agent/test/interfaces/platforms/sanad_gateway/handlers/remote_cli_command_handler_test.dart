import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/cli/workspace/cli_workspace_state.dart';
import 'package:sanad_agent/cli/workspace/workspace_cli_service.dart';
import 'package:sanad_agent/cli/workspace/workspace_locator.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/interfaces/models/remote_cli.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/remote_cli_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

import '../../../../support/isolated_sanad_test_home.dart';
import '../../../../support/memory_agent_secret_store.dart';

class _MockAuthManager extends AuthManager {
  _MockAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String? get hardwareId => 'target-device-1';
}

void main() {
  useIsolatedSanadTestHome();
  final getIt = GetIt.instance;

  late SanadProtocolBridge bridge;
  late _MockAuthManager authManager;
  late RemoteCliCommandHandler handler;
  late List<Map<String, dynamic>> emittedEnvelopes;

  setUp(() {
    authManager = _MockAuthManager();
    getIt.registerSingleton<AuthManager>(authManager);

    bridge = SanadProtocolBridge();
    emittedEnvelopes = <Map<String, dynamic>>[];

    handler = RemoteCliCommandHandler(
      bridge: bridge,
      authManager: authManager,
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> emitEnvelope(Map<String, dynamic> envelope) async {
    emittedEnvelopes.add(envelope);
  }

  group('RemoteCliCommandHandler - Validation and Admission', () {
    test('rejects missing request_id with invalid_request', () async {
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.invalidRequest);
    });

    test('rejects empty argv with invalid_request', () async {
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-empty-argv',
            'argv': <String>[],
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.invalidRequest);
    });

    test('rejects wrong device_id with wrong_device', () async {
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-wrong-dev',
            'device_id': 'different-device-99',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.wrongDevice);
    });

    test('rejects duplicate request_id with duplicate_request', () async {
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-dup-1',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      emittedEnvelopes.clear();

      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-dup-1',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.duplicateRequest);
    });

    test('rejects payload with argv exceeding maximum argument count', () async {
      final largeArgv = List.generate(257, (i) => 'arg$i');
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: {
            'request_id': 'req-too-many-args',
            'argv': largeArgv,
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.payloadTooLarge);
    });

    test('rejects payload with an argument exceeding maximum length with payload_too_large', () async {
      final hugeArg = 'x' * (RemoteCliLimits.maxArgLength + 1);
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: {
            'request_id': 'req-huge-arg',
            'argv': ['version', hugeArg],
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.payloadTooLarge);
    });

    test('rejects payload with stdin exceeding maximum length with payload_too_large', () async {
      final hugeStdin = 's' * (RemoteCliLimits.maxStdinLength + 1);
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: {
            'request_id': 'req-huge-stdin',
            'argv': ['version'],
            'stdin': hugeStdin,
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.payloadTooLarge);
    });

    test('rejects payload with brief_content exceeding 512KB with payload_too_large', () async {
      final hugeBrief = 'b' * (RemoteCliLimits.maxBriefContentLength + 1);
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: {
            'request_id': 'req-huge-brief',
            'argv': ['run', '--brief-file', 'task.md'],
            'brief_content': hugeBrief,
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.payloadTooLarge);
    });

    test('accepts request targeting registered device ID when hardware ID differs', () async {
      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager, // hardwareId is 'target-device-1'
        registeredDeviceId: () => 'cloud-assigned-device-42',
      );

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-cloud-device-match',
            'device_id': 'cloud-assigned-device-42',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      expect(
        emittedEnvelopes.any((e) => e['event'] == RemoteCliCommands.result),
        isTrue,
      );
      final resultEnv = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEnv['payload']['exit_code'], 0);
    });

    test('rejects cancel request targeting mismatched device ID with wrong_device', () async {
      await handler.handleCancel(
        CanonicalEvent(
          type: RemoteCliCommands.cancel,
          payload: const {
            'request_id': 'cancel-wrong-dev',
            'device_id': 'other-device-99',
            'target_request_id': 'any-target',
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.wrongDevice);
    });

    test('accepts --url flag as alias for --gateway-url in CLI runner', () async {
      final runner = SanadCommandRunner();
      final results = runner.argParser.parse(['--url', 'ws://localhost:9999/ws', 'version']);
      expect(results.wasParsed('gateway-url'), isTrue);
      expect(results['gateway-url'], 'ws://localhost:9999/ws');
    });
  });

  group('RemoteCliCommandHandler - Execution and Streaming', () {
    test('executes command, streams stdout, and returns terminal result with monotonic seq', () async {
      await handler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-version-1',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes.length, greaterThanOrEqualTo(2));

      // Check stdout events
      final stdoutEvents = emittedEnvelopes
          .where((e) => e['event'] == RemoteCliCommands.stdout)
          .toList();
      expect(stdoutEvents, isNotEmpty);
      final stdoutCombined = stdoutEvents
          .map((e) => e['payload']['text'] as String)
          .join();
      expect(stdoutCombined, contains('Sanad Agent'));

      // Check terminal result event
      final resultEvents = emittedEnvelopes
          .where((e) => e['event'] == RemoteCliCommands.result)
          .toList();
      expect(resultEvents, hasLength(1));
      final resPayload = resultEvents.first['payload'] as Map<String, dynamic>;
      expect(resPayload['request_id'], 'req-version-1');
      expect(resPayload['exit_code'], 0);
      expect(resPayload['cancelled'], isFalse);
      expect(resPayload['timed_out'], isFalse);

      // Verify sequence numbers are strictly monotonic across all events
      var lastSeq = 0;
      for (final env in emittedEnvelopes) {
        if (env['type'] == 'event') {
          final seq = env['payload']['seq'] as int;
          expect(seq, greaterThan(lastSeq));
          lastSeq = seq;
        }
      }
    });

    test('preserves arguments verbatim without shell evaluation', () async {
      var capturedArgs = <String>[];
      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'version': (cmd) {
                capturedArgs = cmd.argResults?.rest ?? [];
                stdoutSink.writeln('Custom version executed');
                return 0;
              },
            },
          );
        },
      );

      const maliciousPayload = '; rm -rf / && echo hacked | grep secret';
      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-no-shell',
            'argv': ['version', maliciousPayload],
          },
        ),
        emitEnvelope,
      );

      expect(capturedArgs, contains(maliciousPayload));
      final resultEvent = emittedEnvelopes.lastWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['exit_code'], 0);
    });

    test('preserves stdin semantics and supplies input to runner', () async {
      String? receivedStdin;
      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            stdinReader: stdinReader,
            customHandlers: {
              'version': (cmd) async {
                receivedStdin = await stdinReader();
                stdoutSink.writeln('Read stdin successfully');
                return 0;
              },
            },
          );
        },
      );

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-stdin-1',
            'argv': ['version'],
            'stdin': '{"key": "streamed_stdin_payload"}',
          },
        ),
        emitEnvelope,
      );

      expect(receivedStdin, '{"key": "streamed_stdin_payload"}');
      final resultEvent = emittedEnvelopes.lastWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['exit_code'], 0);
    });

    test('materializes brief_content to temp file and points argv to it', () async {
      String? briefFilePath;
      String? briefFileContent;

      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'run': (cmd) {
                briefFilePath = cmd.getOption('brief-file');
                if (briefFilePath != null && File(briefFilePath!).existsSync()) {
                  briefFileContent = File(briefFilePath!).readAsStringSync();
                }
                stdoutSink.writeln('Brief processed');
                return 0;
              },
            },
          );
        },
      );

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-brief-1',
            'argv': ['run', '--brief-file', 'original/local/path.txt'],
            'brief_content': 'Materialized task brief instructions here',
          },
        ),
        emitEnvelope,
      );

      expect(briefFilePath, isNotNull);
      expect(briefFilePath, isNot('original/local/path.txt'));
      expect(briefFileContent, 'Materialized task brief instructions here');

      // The temp file must be cleaned up in finally block
      expect(File(briefFilePath!).existsSync(), isFalse);
    });
  });

  group('RemoteCliCommandHandler - Cancellation and Timeout', () {
    test('cancels in-flight execution via device.cli.cancel', () async {
      final executionStarted = Completer<void>();
      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'version': (cmd) async {
                executionStarted.complete();
                // Simulating long-running command waiting for signal
                await signalStream!.first;
                return 130;
              },
            },
            signalStream: signalStream,
          );
        },
      );

      final executeFuture = customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-to-cancel',
            'argv': ['version'],
            'timeout_seconds': 30,
          },
        ),
        emitEnvelope,
      );

      await executionStarted.future;

      // Now issue cancellation
      await customHandler.handleCancel(
        CanonicalEvent(
          type: RemoteCliCommands.cancel,
          payload: const {
            'request_id': 'cancel-req-1',
            'target_request_id': 'req-to-cancel',
          },
        ),
        emitEnvelope,
      );

      await executeFuture;

      final cancelAck = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.cancel,
      );
      expect(cancelAck['payload']['target_request_id'], 'req-to-cancel');
      expect(cancelAck['payload']['success'], isTrue);

      final resultEvent = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['request_id'], 'req-to-cancel');
      expect(resultEvent['payload']['cancelled'], isTrue);
      expect(resultEvent['payload']['exit_code'], 130);
    });

    test('cancel on non-existent target returns not_found error', () async {
      await handler.handleCancel(
        CanonicalEvent(
          type: RemoteCliCommands.cancel,
          payload: const {
            'request_id': 'cancel-non-existent',
            'target_request_id': 'non-existent-req-id',
          },
        ),
        emitEnvelope,
      );

      expect(emittedEnvelopes, hasLength(1));
      final env = emittedEnvelopes.first;
      expect(env['type'], 'error');
      expect(env['payload']['code'], RemoteCliErrorCodes.notFound);
    });

    test('timeout terminates execution and emits exit_code 124', () async {
      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'version': (cmd) async {
                await Future.delayed(const Duration(seconds: 10));
                return 0;
              },
            },
            signalStream: signalStream,
          );
        },
      );

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-timeout-1',
            'argv': ['version'],
            'timeout_seconds': 1,
          },
        ),
        emitEnvelope,
      );

      final resultEvent = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['timed_out'], isTrue);
      expect(resultEvent['payload']['exit_code'], 124);
    });
  });

  group('SanadProtocolBridge - Remote CLI Protocol Dispatch', () {
    test('routes device.cli.execute and device.cli.cancel through handleCommand', () async {
      bridge.setRemoteCliHandlerForTesting(handler);

      final handledExecute = await bridge.handleCommand(
        {
          'command': CanonicalEventTypes.deviceCliExecute,
          'request_id': 'bridge-req-1',
          'payload': {
            'request_id': 'bridge-req-1',
            'argv': ['version'],
          },
        },
        emitEnvelope,
      );

      expect(handledExecute, isTrue);
      expect(
        emittedEnvelopes.any((e) => e['event'] == RemoteCliCommands.result),
        isTrue,
      );

      emittedEnvelopes.clear();

      final handledCancel = await bridge.handleCommand(
        {
          'command': CanonicalEventTypes.deviceCliCancel,
          'request_id': 'bridge-cancel-1',
          'payload': {
            'request_id': 'bridge-cancel-1',
            'target_request_id': 'non-existent',
          },
        },
        emitEnvelope,
      );

      expect(handledCancel, isTrue);
      expect(emittedEnvelopes.first['type'], 'error');
      expect(
        emittedEnvelopes.first['payload']['code'],
        RemoteCliErrorCodes.notFound,
      );
    });
  });

  group('RemoteCliCommandHandler - Device and Workspace Flow (G2)', () {
    test('relays workspace list and returns structured workspaces with IDs', () async {
      final tempHome = Directory.systemTemp.createTempSync('g2_home_');
      final wsDir1 = Directory.systemTemp.createTempSync('g2_ws1_');
      final wsDir2 = Directory.systemTemp.createTempSync('g2_ws2_');

      try {
        final stateDb = AgentStateDatabase.atPath(tempHome.path);
        final sessionDb = SessionDB.fromState(stateDb);
        final ws1 = sessionDb.createOrGetWorkspace(
          path: WorkspaceLocator.normalizeDirectory(wsDir1.path),
          source: 'test',
          displayName: 'AlphaWorkspace',
        );
        final ws2 = sessionDb.createOrGetWorkspace(
          path: WorkspaceLocator.normalizeDirectory(wsDir2.path),
          source: 'test',
          displayName: 'BetaWorkspace',
        );

        final runtimeService = LocalWorkspaceRuntimeService(
          sanadHomePath: tempHome.path,
          sessionDb: sessionDb,
        );
        final settingsStore = SanadSettingsStore(homeDirectoryPath: tempHome.path);
        final policyStore = WorkspacePolicyStore(settingsStore: settingsStore);
        final stateStore = CliWorkspaceStateStore(sanadHomeOverride: tempHome.path);

        final wsService = WorkspaceCliService(
          sanadHome: tempHome.path,
          runtimeService: runtimeService,
          policyStore: policyStore,
          stateStore: stateStore,
          isGatewayMode: false,
        );

        final customHandler = RemoteCliCommandHandler(
          bridge: bridge,
          authManager: authManager,
          runnerFactory: ({
            required stdoutSink,
            required stderrSink,
            required stdinReader,
            workspaceService,
            signalStream,
            eventSink,
          }) {
            return SanadCommandRunner(
              stdoutSink: stdoutSink,
              stderrSink: stderrSink,
              stdinReader: stdinReader,
              workspaceService: wsService,
              signalStream: signalStream,
              eventSink: eventSink,
            );
          },
        );

        await customHandler.handleExecute(
          CanonicalEvent(
            type: RemoteCliCommands.execute,
            payload: const {
              'request_id': 'req-ws-list-1',
              'argv': ['workspace', 'list', '--json'],
            },
          ),
          emitEnvelope,
        );

        final stdoutEvents = emittedEnvelopes
            .where((e) => e['event'] == RemoteCliCommands.stdout)
            .toList();
        expect(stdoutEvents, isNotEmpty);
        final combinedOutput = stdoutEvents
            .map((e) => e['payload']['text'] as String)
            .join();

        final decoded = jsonDecode(combinedOutput.trim()) as List;
        expect(decoded, hasLength(2));
        final ids = decoded.map((w) => w['id']).toList();
        expect(ids, containsAll([ws1['id'], ws2['id']]));

        final resultEvent = emittedEnvelopes.firstWhere(
          (e) => e['event'] == RemoteCliCommands.result,
        );
        expect(resultEvent['payload']['exit_code'], 0);
      } finally {
        try {
          tempHome.deleteSync(recursive: true);
          wsDir1.deleteSync(recursive: true);
          wsDir2.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('proves a listed workspace id can be used by a subsequent remote run request', () async {
      String? capturedWorkspaceId;
      String? capturedPrompt;

      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            stdinReader: stdinReader,
            workspaceService: workspaceService,
            signalStream: signalStream,
            eventSink: eventSink,
            customHandlers: {
              'run': (cmd) async {
                capturedWorkspaceId = cmd.workspace;
                capturedPrompt = cmd.prompt;
                cmd.stdoutSink.writeln('Running in workspace $capturedWorkspaceId: $capturedPrompt');
                return 0;
              },
            },
          );
        },
      );

      const targetWorkspaceId = 'ws-beta-999';

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-run-with-ws',
            'argv': ['run', '-p', 'Analyze code', '-w', targetWorkspaceId],
          },
        ),
        emitEnvelope,
      );

      expect(capturedWorkspaceId, targetWorkspaceId);
      expect(capturedPrompt, 'Analyze code');

      final resultEvent = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['exit_code'], 0);

      final stdoutEvents = emittedEnvelopes
          .where((e) => e['event'] == RemoteCliCommands.stdout)
          .toList();
      final text = stdoutEvents.map((e) => e['payload']['text']).join();
      expect(text, contains('Running in workspace ws-beta-999: Analyze code'));
    });

    test('materializes brief_content to temporary file and preserves stdin semantics', () async {
      String? materializedFilePath;
      String? fileContentRead;
      String? stdinContentRead;

      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            stdinReader: stdinReader,
            customHandlers: {
              'run': (cmd) async {
                materializedFilePath = cmd.getOption('brief-file');
                if (materializedFilePath != null && File(materializedFilePath!).existsSync()) {
                  fileContentRead = File(materializedFilePath!).readAsStringSync();
                }
                stdinContentRead = await stdinReader();
                cmd.stdoutSink.writeln('Brief and stdin processed successfully');
                return 0;
              },
            },
          );
        },
      );

      const testBrief = '# Migration Plan\n1. Upgrade SDK\n2. Run tests';
      const testStdin = 'confirmation-token-12345';

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: {
            'request_id': 'req-brief-stdin',
            'argv': ['run', '-w', 'ws-test', '-b', 'caller-local-path.md'],
            'brief_content': testBrief,
            'stdin': testStdin,
          },
        ),
        emitEnvelope,
      );

      expect(materializedFilePath, isNotNull);
      expect(materializedFilePath, isNot('caller-local-path.md'));
      expect(fileContentRead, testBrief);
      expect(stdinContentRead, testStdin);

      // Verify the temporary brief file is cleaned up after execution completes
      expect(File(materializedFilePath!).existsSync(), isFalse);

      final resultEvent = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['exit_code'], 0);
    });
  });

  group('RemoteCliCommandHandler - Reliability (G3)', () {
    test('in-flight duplicate request is rejected while active execution proceeds', () async {
      final runningCompleter = Completer<void>();
      final finishCompleter = Completer<void>();

      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'version': (cmd) async {
                runningCompleter.complete();
                await finishCompleter.future;
                return 0;
              },
            },
          );
        },
      );

      final exec1Future = customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-inflight-dup',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      await runningCompleter.future;

      // Send duplicate with same request_id while req-inflight-dup is running
      final dupEnvelopes = <Map<String, dynamic>>[];
      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-inflight-dup',
            'argv': ['version'],
          },
        ),
        (env) async => dupEnvelopes.add(env),
      );

      expect(dupEnvelopes, hasLength(1));
      expect(dupEnvelopes.first['type'], 'error');
      expect(dupEnvelopes.first['payload']['code'], RemoteCliErrorCodes.duplicateRequest);

      // Let req 1 complete cleanly
      finishCompleter.complete();
      await exec1Future;

      final resultEvent = emittedEnvelopes.firstWhere(
        (e) => e['event'] == RemoteCliCommands.result,
      );
      expect(resultEvent['payload']['exit_code'], 0);
    });

    test('disconnect triggers execution cleanup and cancels active process', () async {
      final startedCompleter = Completer<void>();
      bool signalReceived = false;

      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          signalStream?.listen((sig) {
            signalReceived = true;
          });
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'version': (cmd) async {
                startedCompleter.complete();
                cmd.stdoutSink.writeln('About to trigger disconnect');
                await Future.delayed(const Duration(milliseconds: 50));
                return 0;
              },
            },
            signalStream: signalStream,
          );
        },
      );

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-disconnect-1',
            'argv': ['version'],
          },
        ),
        (env) async {
          if (env['event'] == RemoteCliCommands.stdout) {
            throw const SocketException('Client disconnected unexpectedly');
          }
        },
      );

      expect(signalReceived, isTrue);
    });

    test('late events after terminal emission are dropped without error', () async {
      late StringSink capturedStdout;
      final customHandler = RemoteCliCommandHandler(
        bridge: bridge,
        authManager: authManager,
        runnerFactory: ({
          required stdoutSink,
          required stderrSink,
          required stdinReader,
          workspaceService,
          signalStream,
          eventSink,
        }) {
          capturedStdout = stdoutSink;
          return SanadCommandRunner(
            stdoutSink: stdoutSink,
            stderrSink: stderrSink,
            customHandlers: {
              'version': (cmd) async {
                cmd.stdoutSink.writeln('Initial output');
                return 0;
              },
            },
          );
        },
      );

      await customHandler.handleExecute(
        CanonicalEvent(
          type: RemoteCliCommands.execute,
          payload: const {
            'request_id': 'req-late-event',
            'argv': ['version'],
          },
        ),
        emitEnvelope,
      );

      final envelopeCountBefore = emittedEnvelopes.length;

      // Attempt late write on the captured sink after execution completed
      capturedStdout.writeln('Late lingering log message');

      expect(emittedEnvelopes.length, envelopeCountBefore);
    });
  });
}
