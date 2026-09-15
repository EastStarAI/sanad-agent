import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/cli/cli.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

class MockWebSocket implements WebSocket {
  final _incomingController = StreamController<dynamic>();
  final List<String> sentMessages = [];
  bool _closed = false;
  final Completer<void> _doneCompleter = Completer<void>();

  void emitFromServer(dynamic data) {
    if (!_closed) {
      _incomingController.add(data);
    }
  }

  void simulateClose([int? closeCode, String? closeReason]) {
    if (!_closed) {
      _closed = true;
      _incomingController.close();
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  @override
  void add(dynamic data) {
    if (_closed) throw const SocketException('Socket closed');
    sentMessages.add(data.toString());
  }

  @override
  Future close([int? code, String? reason]) async {
    simulateClose(code, reason);
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _incomingController.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  useIsolatedSanadTestHome();
  group('WorkspaceLocator Unit Tests', () {
    late Directory tempDir;
    late String rootWorkspacePath;
    late String subWorkspacePath;
    late List<Map<String, dynamic>> workspaces;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('locator_test_');
      final rootDir = Directory(p.join(tempDir.path, 'root_project'))
        ..createSync(recursive: true);
      rootWorkspacePath = WorkspaceLocator.normalizeDirectory(rootDir.path);
      final subDir = Directory(
        p.join(rootWorkspacePath, 'packages', 'sub_project'),
      )..createSync(recursive: true);
      subWorkspacePath = WorkspaceLocator.normalizeDirectory(subDir.path);

      workspaces = [
        {
          'id': 'ws-root-1',
          'name': 'RootProject',
          'display_name': 'RootProject',
          'path': rootWorkspacePath,
          'source': 'test',
        },
        {
          'id': 'ws-sub-2',
          'name': 'SubProject',
          'display_name': 'SubProject',
          'path': subWorkspacePath,
          'source': 'test',
        },
      ];
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('exact match returns exact WorkspaceMatch', () {
      final match = WorkspaceLocator.findMatchingWorkspace(
        workspaces: workspaces,
        directoryPath: rootWorkspacePath,
      );

      expect(match, isNotNull);
      expect(match!.isExact, isTrue);
      expect(match.workspaceId, 'ws-root-1');
      expect(match.workspaceName, 'RootProject');
      expect(match.matchedPath, rootWorkspacePath);
      expect(match.relativeSubpath, isEmpty);
    });

    test(
      'nested subdirectory matches parent workspace and calculates relativeSubpath',
      () {
        final nestedDir = p.join(rootWorkspacePath, 'src', 'utils', 'helpers');
        Directory(nestedDir).createSync(recursive: true);

        final match = WorkspaceLocator.findMatchingWorkspace(
          workspaces: workspaces,
          directoryPath: nestedDir,
        );

        expect(match, isNotNull);
        expect(match!.isExact, isFalse);
        expect(match.workspaceId, 'ws-root-1');
        expect(match.matchedPath, rootWorkspacePath);
        expect(match.relativeSubpath, p.join('src', 'utils', 'helpers'));
      },
    );

    test(
      'deeply nested folder inside nested workspace matches closest enclosing workspace',
      () {
        final deepSub = p.join(subWorkspacePath, 'lib', 'core');
        Directory(deepSub).createSync(recursive: true);

        final match = WorkspaceLocator.findMatchingWorkspace(
          workspaces: workspaces,
          directoryPath: deepSub,
        );

        expect(match, isNotNull);
        expect(match!.isExact, isFalse);
        expect(match.workspaceId, 'ws-sub-2');
        expect(match.workspaceName, 'SubProject');
        expect(match.matchedPath, subWorkspacePath);
        expect(match.relativeSubpath, p.join('lib', 'core'));
      },
    );

    test('unregistered directory returns null', () {
      final outsideDir = WorkspaceLocator.normalizeDirectory(
        p.join(tempDir.path, 'unregistered_folder'),
      );
      Directory(outsideDir).createSync(recursive: true);

      final match = WorkspaceLocator.findMatchingWorkspace(
        workspaces: workspaces,
        directoryPath: outsideDir,
      );

      expect(match, isNull);
    });

    test('normalizes relative dot segments and slashes', () {
      final relativeTarget = p.join(rootWorkspacePath, 'src', '..', 'src', '.');
      Directory(p.join(rootWorkspacePath, 'src')).createSync(recursive: true);

      final match = WorkspaceLocator.findMatchingWorkspace(
        workspaces: workspaces,
        directoryPath: relativeTarget,
      );

      expect(match, isNotNull);
      expect(match!.workspaceId, 'ws-root-1');
      expect(match.relativeSubpath, 'src');
    });

    test(
      'resolveActiveWorkspace prioritizes explicit target, then CWD, then stored state',
      () async {
        final stateStore = CliWorkspaceStateStore(
          sanadHomeOverride: tempDir.path,
        );
        await stateStore.setActiveWorkspace(
          workspaceId: 'ws-root-1',
          workspacePath: rootWorkspacePath,
        );

        final locator = WorkspaceLocator(stateStore: stateStore);

        // 1. Explicit ID wins over everything
        final explicitResolved = await locator.resolveActiveWorkspace(
          explicitIdOrPath: 'ws-sub-2',
          cwd: rootWorkspacePath,
          knownWorkspaces: workspaces,
        );
        expect(explicitResolved?['id'], 'ws-sub-2');

        // 2. Explicit name wins (case-insensitive)
        final nameResolved = await locator.resolveActiveWorkspace(
          explicitIdOrPath: 'subproject',
          cwd: rootWorkspacePath,
          knownWorkspaces: workspaces,
        );
        expect(nameResolved?['id'], 'ws-sub-2');

        // 3. CWD auto-discovery wins when no explicit target provided
        final cwdResolved = await locator.resolveActiveWorkspace(
          cwd: subWorkspacePath,
          knownWorkspaces: workspaces,
        );
        expect(cwdResolved?['id'], 'ws-sub-2');

        // 4. Stored state wins when CWD is in an unregistered directory
        final outsideDir = p.join(tempDir.path, 'outside');
        Directory(outsideDir).createSync();
        final storedResolved = await locator.resolveActiveWorkspace(
          cwd: outsideDir,
          knownWorkspaces: workspaces,
        );
        expect(storedResolved?['id'], 'ws-root-1');
      },
    );
  });

  group('CliWorkspaceStateStore Tests', () {
    late Directory tempHome;
    late CliWorkspaceStateStore store;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('cli_state_test_');
      store = CliWorkspaceStateStore(sanadHomeOverride: tempHome.path);
    });

    tearDown(() {
      try {
        tempHome.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('reads empty map when state file does not exist', () async {
      final state = await store.readState();
      expect(state, isEmpty);
      expect(await store.getActiveWorkspaceId(), isNull);
    });

    test('saves and retrieves active workspace', () async {
      await store.setActiveWorkspace(
        workspaceId: 'ws-123',
        workspacePath: '/path/to/my-app',
        workspaceName: 'MyApp',
      );

      expect(await store.getActiveWorkspaceId(), 'ws-123');
      expect(await store.getActiveWorkspacePath(), '/path/to/my-app');

      final rawState = await store.readState();
      expect(rawState['active_workspace_id'], 'ws-123');
      expect(rawState['active_workspace_name'], 'MyApp');
      expect(rawState['updated_at'], isNotEmpty);
    });

    test('clears active workspace correctly', () async {
      await store.setActiveWorkspace(
        workspaceId: 'ws-123',
        workspacePath: '/path/to/my-app',
      );
      await store.clearActiveWorkspace();

      expect(await store.getActiveWorkspaceId(), isNull);
      expect(await store.getActiveWorkspacePath(), isNull);
    });
  });

  group('WorkspaceCommand Execution & Dual-Mode Services', () {
    late Directory tempSanadHome;
    late Directory workspaceDir1;
    late Directory workspaceDir2;
    late SessionDB sessionDb;
    late AgentStateDatabase stateDb;
    late LocalWorkspaceRuntimeService runtimeService;
    late WorkspacePolicyStore policyStore;
    late CliWorkspaceStateStore stateStore;
    late WorkspaceCliService service;
    late StringBuffer stdoutBuf;
    late StringBuffer stderrBuf;

    setUp(() async {
      tempSanadHome = Directory.systemTemp.createTempSync('sanad_home_ws_');
      workspaceDir1 = Directory.systemTemp.createTempSync('ws1_');
      workspaceDir2 = Directory.systemTemp.createTempSync('ws2_');

      stateDb = AgentStateDatabase.atPath(tempSanadHome.path);
      sessionDb = SessionDB.fromState(stateDb);

      sessionDb.createOrGetWorkspace(
        path: WorkspaceLocator.normalizeDirectory(workspaceDir1.path),
        source: 'test',
        displayName: 'AlphaProject',
      );
      sessionDb.createOrGetWorkspace(
        path: WorkspaceLocator.normalizeDirectory(workspaceDir2.path),
        source: 'test',
        displayName: 'BetaProject',
      );

      runtimeService = LocalWorkspaceRuntimeService(
        sanadHomePath: tempSanadHome.path,
        sessionDb: sessionDb,
      );

      final settingsStore = SanadSettingsStore(
        homeDirectoryPath: tempSanadHome.path,
      );
      policyStore = WorkspacePolicyStore(settingsStore: settingsStore);
      stateStore = CliWorkspaceStateStore(
        sanadHomeOverride: tempSanadHome.path,
      );

      service = WorkspaceCliService(
        sanadHome: tempSanadHome.path,
        runtimeService: runtimeService,
        policyStore: policyStore,
        stateStore: stateStore,
        isGatewayMode: false,
      );

      stdoutBuf = StringBuffer();
      stderrBuf = StringBuffer();
    });

    tearDown(() {
      try {
        stateDb.dispose();
        tempSanadHome.deleteSync(recursive: true);
        workspaceDir1.deleteSync(recursive: true);
        workspaceDir2.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
      'list command outputs formatted table with columns and active mark',
      () async {
        // Switch active workspace to BetaProject
        final workspaces = await service.listWorkspaces();
        final betaWs = workspaces.firstWhere((w) => w['name'] == 'BetaProject');
        await stateStore.setActiveWorkspace(
          workspaceId: betaWs['id'],
          workspacePath: betaWs['path'],
        );

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          workspaceService: service,
        );

        final exitCode = await runner.run(['workspace', 'list']);
        expect(exitCode, 0);

        final output = stdoutBuf.toString();
        expect(output, contains('Registered Workspaces:'));
        expect(output, contains('NAME'));
        expect(output, contains('POLICY'));
        expect(output, contains('PATH'));
        expect(output, contains('AlphaProject'));
        expect(output, contains('BetaProject'));
        // Check active marker on BetaProject
        expect(output, contains('* BetaProject'));
      },
    );

    test('current command shows active workspace details and policy', () async {
      final workspaces = await service.listWorkspaces();
      final alphaWs = workspaces.firstWhere((w) => w['name'] == 'AlphaProject');
      await stateStore.setActiveWorkspace(
        workspaceId: alphaWs['id'],
        workspacePath: alphaWs['path'],
        workspaceName: 'AlphaProject',
      );

      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        workspaceService: service,
      );

      final exitCode = await runner.run(['workspace', 'current']);
      expect(exitCode, 0);

      final output = stdoutBuf.toString();
      expect(output, contains('Active Workspace:'));
      expect(output, contains('Name:        AlphaProject'));
      expect(output, contains('Path:        ${alphaWs['path']}'));
      expect(output, contains('Policy:      default'));
      expect(output, contains('Connected MCP Servers:'));
    });

    test(
      'switch command changes active workspace and saves to stateStore',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          workspaceService: service,
        );

        // Switch by name
        final exitCode = await runner.run([
          'workspace',
          'switch',
          'BetaProject',
        ]);
        expect(exitCode, 0);
        expect(
          stdoutBuf.toString(),
          contains('Switched active workspace to: BetaProject'),
        );

        final storedPath = await stateStore.getActiveWorkspacePath();
        expect(
          storedPath,
          WorkspaceLocator.normalizeDirectory(workspaceDir2.path),
        );
      },
    );

    test('switch command with unknown workspace returns 1 and error', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        workspaceService: service,
      );

      final exitCode = await runner.run([
        'workspace',
        'switch',
        'NonExistentProject',
      ]);
      expect(exitCode, 1);
      expect(
        stderrBuf.toString(),
        contains('Error: Workspace "NonExistentProject" not found.'),
      );
    });

    test(
      'add command registers existing directory and updates active state',
      () async {
        final newDir = Directory.systemTemp.createTempSync('new_ws_to_add_');
        try {
          final runner = SanadCommandRunner(
            stdoutSink: stdoutBuf,
            stderrSink: stderrBuf,
            workspaceService: service,
          );

          final exitCode = await runner.run([
            'workspace',
            'add',
            newDir.path,
            '--name',
            'GammaProject',
          ]);
          expect(exitCode, 0);
          expect(
            stdoutBuf.toString(),
            contains('Registered workspace: "GammaProject"'),
          );

          final storedName = (await stateStore
              .readState())['active_workspace_name'];
          expect(storedName, 'GammaProject');

          // Adding again acknowledges already registered
          stdoutBuf.clear();
          final duplicateCode = await runner.run([
            'workspace',
            'add',
            newDir.path,
          ]);
          expect(duplicateCode, 0);
          expect(
            stdoutBuf.toString(),
            contains('Workspace already registered: "GammaProject"'),
          );
        } finally {
          newDir.deleteSync(recursive: true);
        }
      },
    );

    test('create command creates folder and registers workspace', () async {
      final parentDir = Directory.systemTemp.createTempSync('create_parent_');
      try {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuf,
          stderrSink: stderrBuf,
          workspaceService: service,
        );

        final exitCode = await runner.run([
          'workspace',
          'create',
          'DeltaProject',
          '--path',
          parentDir.path,
        ]);
        expect(exitCode, 0);
        expect(
          stdoutBuf.toString(),
          contains('Created workspace "DeltaProject"'),
        );

        final createdFolder = Directory(p.join(parentDir.path, 'DeltaProject'));
        expect(createdFolder.existsSync(), isTrue);
      } finally {
        parentDir.deleteSync(recursive: true);
      }
    });

    test('tree command renders directory tree structure', () async {
      // Create some files and subdirectories inside workspaceDir1
      File(
        p.join(workspaceDir1.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: alpha\n');
      final libDir = Directory(p.join(workspaceDir1.path, 'lib'))..createSync();
      File(
        p.join(libDir.path, 'main.dart'),
      ).writeAsStringSync('void main() {}\n');

      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        workspaceService: service,
      );

      final exitCode = await runner.run([
        'workspace',
        'tree',
        '--workspace',
        WorkspaceLocator.normalizeDirectory(workspaceDir1.path),
      ]);
      expect(exitCode, 0);

      final output = stdoutBuf.toString();
      expect(output, contains('lib/'));
      expect(output, contains('pubspec.yaml'));
      expect(output, anyOf(contains('├── '), contains('└── ')));
    });

    test('policy command views and mutates security policy mode', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        workspaceService: service,
      );

      final normPath1 = WorkspaceLocator.normalizeDirectory(workspaceDir1.path);

      // 1. View default policy
      var exitCode = await runner.run([
        'workspace',
        'policy',
        '--workspace',
        normPath1,
      ]);
      expect(exitCode, 0);
      expect(stdoutBuf.toString(), contains('Permission Mode: default'));

      // 2. Change policy to full_access
      stdoutBuf.clear();
      exitCode = await runner.run([
        'workspace',
        'policy',
        'full_access',
        '--workspace',
        normPath1,
      ]);
      expect(exitCode, 0);
      expect(
        stdoutBuf.toString(),
        contains('Updated security policy for "AlphaProject" to full_access.'),
      );

      // 3. Confirm policy changed
      stdoutBuf.clear();
      exitCode = await runner.run([
        'workspace',
        'policy',
        '--workspace',
        normPath1,
      ]);
      expect(exitCode, 0);
      expect(stdoutBuf.toString(), contains('Permission Mode: full_access'));

      // 4. Reject invalid policy
      stderrBuf.clear();
      exitCode = await runner.run([
        'workspace',
        'policy',
        'invalid_mode',
        '--workspace',
        normPath1,
      ]);
      expect(exitCode, 1);
      expect(
        stderrBuf.toString(),
        contains('Error: Invalid policy mode "invalid_mode".'),
      );
    });

    test(
      'gateway client mode queries gateway and deserializes envelopes',
      () async {
        final mockSocket = MockWebSocket();
        final client = LocalGatewayCliClient(
          gatewayUri: Uri.parse('ws://127.0.0.1:58085/ws'),
          token: 'test_token',
          autoReconnect: false,
          connector: (uri, {headers, timeout}) async => mockSocket,
        );
        await client.connect();

        final gatewayService = WorkspaceCliService(
          gatewayClient: client,
          sanadHome: tempSanadHome.path,
          runtimeService: runtimeService,
          policyStore: policyStore,
          stateStore: stateStore,
          isGatewayMode: true,
        );

        // Asynchronously respond to list_workspaces
        final futureWorkspaces = gatewayService.listWorkspaces();

        // Wait a microtask for command to be sent over socket
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(mockSocket.sentMessages.length, 1);
        final sentJson =
            jsonDecode(mockSocket.sentMessages.first) as Map<String, dynamic>;
        expect(sentJson['command'], 'list_workspaces');
        final reqId =
            sentJson['request_id'] ?? sentJson['payload']['request_id'];

        // Simulate gateway response envelope
        mockSocket.emitFromServer(
          jsonEncode({
            'type': 'event',
            'event': 'workspaces_list',
            'payload': {
              'request_id': reqId,
              'workspaces': [
                {
                  'id': 'gw-ws-1',
                  'name': 'RemoteProject',
                  'path': '/remote/project',
                },
              ],
            },
          }),
        );

        final result = await futureWorkspaces;
        expect(result.length, 1);
        expect(result.first['name'], 'RemoteProject');
        expect(result.first['id'], 'gw-ws-1');

        await client.dispose();
      },
    );
  });
}
