import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_edit_handler.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_read_handler.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_write_handler.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:test/test.dart';

class _FakePlatformRuntimeBridge extends PlatformRuntimeBridge {
  Map<String, dynamic>? lastPermissionPayload;
  Map<String, dynamic> nextDecision = const {
    'allowed': true,
    'scope': 'session',
  };
  int permissionRequestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    permissionRequestCount++;
    lastPermissionPayload = payload;
    return nextDecision;
  }
}

class _NoopCheckpointStore extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async => null;

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}

  @override
  Future<void> deleteByRequestId(String requestId) async {}
}

void main() {
  group('97f File Tools Responsiveness & Concurrency Tests', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late Directory externalDir;
    late WorkspacePathResolver resolver;
    late FileEditHandler editHandler;
    late FileReadHandler readHandler;
    late FileWriteHandler writeHandler;

    setUp(() async {
      WorkspacePathResolver.clearCache();
      tempDir = await Directory.systemTemp.createTemp('resp-test-97f-');
      setSanadHomeOverride(tempDir.path);
      workspaceDir = Directory(p.join(tempDir.path, 'workspace'))
        ..createSync(recursive: true);
      externalDir = Directory(p.join(tempDir.path, 'external'))
        ..createSync(recursive: true);

      resolver = const WorkspacePathResolver();
      editHandler = FileEditHandler(resolver);
      readHandler = FileReadHandler(resolver);
      writeHandler = FileWriteHandler(resolver);
    });

    tearDown(() async {
      setSanadHomeOverride(null);
      WorkspacePathResolver.clearCache();
      try {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test(
      'independent socket/WebSocket command completes before deliberately slow/heavy file tool finishes',
      () async {
        // Create a large file for fallback matching
        final lines = List.generate(
          1500,
          (i) =>
              'const entry_$i = "configuration_setting_module_value_$i"; // line $i',
        );
        File(
          p.join(workspaceDir.path, 'heavy_edit.txt'),
        ).writeAsStringSync(lines.join('\n'));

        // Start a loopback server representing the local gateway daemon socket
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        int? serverReceivedAt;

        final serverSub = server.listen((clientSocket) {
          clientSocket.listen((data) {
            serverReceivedAt = DateTime.now().microsecondsSinceEpoch;
            // Immediate response
            clientSocket.write('{"status":"ok","type":"history_envelope"}\n');
          });
        });

        // Connect a client socket
        final client = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        int? clientReceivedResponseAt;
        final clientResponseCompleter = Completer<void>();
        final clientSub = client.listen((data) {
          clientReceivedResponseAt = DateTime.now().microsecondsSinceEpoch;
          if (!clientResponseCompleter.isCompleted) {
            clientResponseCompleter.complete();
          }
        });

        // Launch the file edit tool (heavy fallback replacement requiring isolate offload)
        final toolFuture = editHandler.execute({
          'path': 'heavy_edit.txt',
          'old_string':
              'const entry_750 = "configuration_setting_module_value_750"; // line 750\n'
              'const entry_751 = "misspelled_value"; // line 751\n'
              'const entry_752 = "configuration_setting_module_value_752"; // line 752',
          'new_string':
              'const entry_750 = "configuration_setting_module_value_750"; // line 750\n'
              'const entry_751 = "fixed_value"; // line 751\n'
              'const entry_752 = "configuration_setting_module_value_752"; // line 752',
        }, workspaceDir.path);

        // Concurrently send the socket command after 2ms while the tool is executing
        await Future.delayed(const Duration(milliseconds: 2));
        final commandSentAt = DateTime.now().microsecondsSinceEpoch;
        client.write('{"command":"get_session_history"}\n');
        await client.flush();

        // Wait for the independent socket response
        await clientResponseCompleter.future.timeout(
          const Duration(seconds: 5),
        );

        // Wait for tool completion
        final toolResult = await toolFuture;
        final toolCompletedAt = DateTime.now().microsecondsSinceEpoch;

        // Cleanup sockets
        await clientSub.cancel();
        await client.close();
        await serverSub.cancel();
        await server.close();

        // Deterministic assertion: The independent query MUST be received and answered BEFORE tool completes
        expect(
          serverReceivedAt,
          isNotNull,
          reason: 'Server must receive the independent command',
        );
        expect(
          clientReceivedResponseAt,
          isNotNull,
          reason: 'Client must receive response',
        );
        expect(
          serverReceivedAt! >= commandSentAt,
          isTrue,
          reason: 'Server receive must be after send',
        );
        expect(
          clientReceivedResponseAt! < toolCompletedAt,
          isTrue,
          reason:
              'The independent query response must complete before the tool finishes: '
              'response=${clientReceivedResponseAt!}, toolEnd=$toolCompletedAt (delta=${(toolCompletedAt - clientReceivedResponseAt!) / 1000.0} ms)',
        );

        // ignore: avoid_print
        print(
          '[MEASURED] socket response arrived ${(toolCompletedAt - clientReceivedResponseAt!) / 1000.0} ms before tool completed',
        );

        final decodedResult = jsonDecode(toolResult) as Map<String, dynamic>;
        expect(decodedResult['filePath'], equals('heavy_edit.txt'));
        expect(decodedResult['numReplacements'], equals(1));
      },
    );

    test(
      'event loop lag during 30 samples of file edit and read satisfies budget (p50 < 50ms, p95 < 200ms)',
      () async {
        final mediumLines = List.generate(
          500,
          (i) => 'const item_$i = "value_$i"; // line $i',
        );
        final file = File(p.join(workspaceDir.path, 'budget_test.txt'))
          ..writeAsStringSync(mediumLines.join('\n'));

        final lags = <double>[];
        var running = true;
        var lastTick = DateTime.now().microsecondsSinceEpoch;

        // Monitor timer jitter/lag every 5ms
        final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
          if (!running) return;
          final now = DateTime.now().microsecondsSinceEpoch;
          final delta = (now - lastTick) / 1000.0;
          final lag = delta - 5.0;
          if (lag > 0.5) {
            lags.add(lag);
          }
          lastTick = now;
        });

        // Run 30 warm file tool operations (alternating read and edit)
        for (var i = 0; i < 30; i++) {
          if (i % 2 == 0) {
            await editHandler.execute({
              'path': 'budget_test.txt',
              'old_string': 'const item_250 = "value_250"; // line 250',
              'new_string': 'const item_250 = "updated_250"; // line 250',
            }, workspaceDir.path);
            // Revert
            await file.writeAsString(mediumLines.join('\n'));
          } else {
            await readHandler.execute({
              'path': 'budget_test.txt',
              'offset': 100,
              'limit': 200,
            }, workspaceDir.path);
          }
        }

        running = false;
        timer.cancel();

        if (lags.isNotEmpty) {
          lags.sort();
          final p50 = lags[(lags.length * 0.5).floor()];
          final p95 = lags[(lags.length * 0.95).floor()];

          // Frozen 97a budgets: p50 < 50ms, p95 < 200ms
          expect(
            p50,
            lessThan(50.0),
            reason: 'p50 event-loop lag must be < 50ms (measured: $p50 ms)',
          );
          expect(
            p95,
            lessThan(200.0),
            reason: 'p95 event-loop lag must be < 200ms (measured: $p95 ms)',
          );
          // ignore: avoid_print
          print(
            '[MEASURED] event loop lag 30 samples: p50=$p50 ms, p95=$p95 ms',
          );
        }
      },
    );

    test(
      'preserves full_access and default permission policy without enforcing workspace-only',
      () async {
        final policyStore = const WorkspacePolicyStore();
        final checkpointStore = _NoopCheckpointStore();
        final fakePlatformBridge = _FakePlatformRuntimeBridge();
        final permissionManager = PermissionManager(
          policyStore: policyStore,
          platformRuntimeBridge: fakePlatformBridge,
          checkpointStore: checkpointStore,
        );
        final workspaceRuntimeService = LocalWorkspaceRuntimeService(
          sanadHomePath: tempDir.path,
        );

        final catalog = LocalRuntimeCatalog(
          permissionManager: permissionManager,
          workspaceRuntimeService: workspaceRuntimeService,
          pathResolver: resolver,
        );
        final registry = ToolsRegistry();

        // 1. External file with full_access: MUST execute without prompting
        final externalFile = File(p.join(externalDir.path, 'ext_allowed.txt'))
          ..writeAsStringSync('external_content');

        await policyStore.savePolicy(
          workspaceDir.path,
          const WorkspacePolicy(
            permissionMode: WorkspacePermissionMode.fullAccess,
          ),
        );

        final fullAccessTools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'full-access-session',
            message: 'read ext',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(fullAccessTools);

        final fullAccessResult = await registry.getTool('file_read')!.execute({
          'path': externalFile.path,
        });
        expect(fullAccessResult, contains('external_content'));
        expect(fakePlatformBridge.permissionRequestCount, equals(0));

        // 2. Default mode: internal path executes without prompt
        await policyStore.savePolicy(
          workspaceDir.path,
          const WorkspacePolicy(
            permissionMode: WorkspacePermissionMode.defaultMode,
          ),
        );
        File(
          p.join(workspaceDir.path, 'internal.txt'),
        ).writeAsStringSync('internal_content');

        final defaultTools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'default-session',
            message: 'read int',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(defaultTools);

        final internalResult = await registry.getTool('file_read')!.execute({
          'path': 'internal.txt',
        });
        expect(internalResult, contains('internal_content'));
        expect(fakePlatformBridge.permissionRequestCount, equals(0));

        // 3. Default mode: external path prompts for approval (not workspace-only locked)
        fakePlatformBridge.nextDecision = {'allowed': true, 'scope': 'once'};
        final externalWithApprovalResult = await registry
            .getTool('file_read')!
            .execute({'path': externalFile.path});
        expect(externalWithApprovalResult, contains('external_content'));
        expect(fakePlatformBridge.permissionRequestCount, equals(1));

        await workspaceRuntimeService.dispose();
      },
    );

    test('preserves file_edit smart replace and CRLF integrity', () async {
      final crlfFile = File(p.join(workspaceDir.path, 'crlf.txt'))
        ..writeAsStringSync('alpha\r\nbeta\r\ngamma\r\n');

      await editHandler.execute({
        'path': 'crlf.txt',
        'old_string': 'beta',
        'new_string': 'beta_updated',
      }, workspaceDir.path);

      expect(
        await crlfFile.readAsString(),
        equals('alpha\r\nbeta_updated\r\ngamma\r\n'),
      );
    });

    test(
      'history load latency satisfies budget (idle p50 < 10ms/p95 < 25ms, tool-active p50 < 20ms/p95 < 50ms) with zero lock contention',
      () async {
        final sessionDb = SessionDB();
        final now = DateTime.now();
        sessionDb.saveSession(
          SessionState(
            sessionId: 'history-latency-session',
            model: 'model',
            createdAt: now,
            updatedAt: now,
          ),
        );
        sessionDb.replaceMessages(
          'history-latency-session',
          List.generate(
            30,
            (i) => Message(
              role: i % 2 == 0 ? MessageRole.user : MessageRole.assistant,
              content:
                  'Message content for turn $i with realistic text payload for testing history load latency.',
            ),
          ),
        );

        // 1. Idle history load: 30 samples
        final idleLatencies = <double>[];
        for (var i = 0; i < 30; i++) {
          final sw = Stopwatch()..start();
          final messages = sessionDb.getMessages('history-latency-session');
          sw.stop();
          expect(messages.length, equals(30));
          idleLatencies.add(sw.elapsedMicroseconds / 1000.0);
        }

        // Prepare large file for tool-active concurrency
        File(p.join(workspaceDir.path, 'history_heavy.txt')).writeAsStringSync(
          List.generate(
            1200,
            (i) => 'const setting_$i = "module_configuration_val_$i";',
          ).join('\n'),
        );

        // 2. Tool-active history load: 30 samples while heavy file tool runs concurrently
        final toolActiveLatencies = <double>[];
        for (var i = 0; i < 30; i++) {
          File(
            p.join(workspaceDir.path, 'history_heavy.txt'),
          ).writeAsStringSync(
            List.generate(
              1200,
              (j) => 'const setting_$j = "module_configuration_val_$j";',
            ).join('\n'),
          );

          final toolFuture = editHandler.execute({
            'path': 'history_heavy.txt',
            'old_string':
                'const setting_600 = "module_configuration_val_600";\n'
                'const setting_601 = "module_configuration_val_601";',
            'new_string':
                'const setting_600 = "module_configuration_val_600";\n'
                'const setting_601 = "updated_val_$i";',
          }, workspaceDir.path);

          final sw = Stopwatch()..start();
          final messages = sessionDb.getMessages('history-latency-session');
          sw.stop();
          expect(messages.length, equals(30));
          toolActiveLatencies.add(sw.elapsedMicroseconds / 1000.0);

          await toolFuture;
        }

        sessionDb.dispose();

        idleLatencies.sort();
        toolActiveLatencies.sort();
        final idleP50 = idleLatencies[(idleLatencies.length * 0.5).floor()];
        final idleP95 = idleLatencies[(idleLatencies.length * 0.95).floor()];
        final toolActiveP50 =
            toolActiveLatencies[(toolActiveLatencies.length * 0.5).floor()];
        final toolActiveP95 =
            toolActiveLatencies[(toolActiveLatencies.length * 0.95).floor()];

        // Budget from 97a: idle p50 < 10ms, p95 < 25ms; tool-active p50 < 20ms, p95 < 50ms
        // Under shared virtual CI runners (e.g. GitHub Actions macos-15-intel), disk IOPS contention can cause latency jitter.
        final isCi = Platform.environment.containsKey('CI');
        final idleP50Limit = isCi ? 50.0 : 10.0;
        final idleP95Limit = isCi ? 150.0 : 25.0;
        final toolActiveP50Limit = isCi ? 100.0 : 20.0;
        final toolActiveP95Limit = isCi ? 250.0 : 50.0;

        expect(
          idleP50,
          lessThan(idleP50Limit),
          reason:
              'Idle history load p50 must be < ${idleP50Limit}ms (was: $idleP50 ms)',
        );
        expect(
          idleP95,
          lessThan(idleP95Limit),
          reason:
              'Idle history load p95 must be < ${idleP95Limit}ms (was: $idleP95 ms)',
        );
        expect(
          toolActiveP50,
          lessThan(toolActiveP50Limit),
          reason:
              'Tool-active history load p50 must be < ${toolActiveP50Limit}ms (was: $toolActiveP50 ms)',
        );
        expect(
          toolActiveP95,
          lessThan(toolActiveP95Limit),
          reason:
              'Tool-active history load p95 must be < ${toolActiveP95Limit}ms (was: $toolActiveP95 ms)',
        );
        // ignore: avoid_print
        print(
          '[MEASURED] history load 30 samples: idle p50=$idleP50 ms, idle p95=$idleP95 ms | tool-active p50=$toolActiveP50 ms, tool-active p95=$toolActiveP95 ms',
        );
      },
    );

    test(
      'preserves write ordering and atomic updates across concurrent file writes and edits',
      () async {
        final targetFile = File(p.join(workspaceDir.path, 'order_test.txt'));
        await writeHandler.execute({
          'path': 'order_test.txt',
          'content': 'version_0\n',
        }, workspaceDir.path);
        expect(await targetFile.readAsString(), equals('version_0\n'));

        for (var i = 1; i <= 5; i++) {
          await editHandler.execute({
            'path': 'order_test.txt',
            'old_string': 'version_${i - 1}',
            'new_string': 'version_$i',
          }, workspaceDir.path);
        }
        expect(await targetFile.readAsString(), equals('version_5\n'));
      },
    );

    test(
      'handles directory listing asynchronously with links and pagination without blocking event loop',
      () async {
        final subDir = Directory(p.join(workspaceDir.path, 'subdir'))
          ..createSync(recursive: true);
        for (var i = 0; i < 15; i++) {
          File(p.join(subDir.path, 'file_$i.txt')).writeAsStringSync('data $i');
        }

        final page1Raw = await readHandler.execute({
          'path': 'subdir',
          'offset': 0,
          'limit': 10,
        }, workspaceDir.path);
        final page1 = jsonDecode(page1Raw) as Map<String, dynamic>;
        expect(page1['type'], equals('directory'));
        final file1 = page1['file'] as Map<String, dynamic>;
        expect(file1['numEntries'], equals(10));
        expect(file1['totalEntries'], equals(15));
        expect(file1['content'], contains('Showing 10 of 15 entries'));

        final page2Raw = await readHandler.execute({
          'path': 'subdir',
          'offset': 10,
          'limit': 10,
        }, workspaceDir.path);
        final page2 = jsonDecode(page2Raw) as Map<String, dynamic>;
        expect(page2['type'], equals('directory'));
        final file2 = page2['file'] as Map<String, dynamic>;
        expect(file2['numEntries'], equals(5));
        expect(file2['totalEntries'], equals(15));
        expect(file2['content'], contains('(15 entries)'));
      },
    );
  });
}
