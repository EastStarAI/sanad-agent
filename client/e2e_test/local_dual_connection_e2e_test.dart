import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/conversation_client_registry_impl.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client_impl.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'reconciles credential-free authentication exchanges through a spawned daemon',
    () async {
      final port = _pickPort();
      final agentDir = Directory(
        '${Directory.current.parent.path}${Platform.pathSeparator}agent',
      );
      final daemon = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: port,
      );
      addTearDown(daemon.stop);
      final socket = _localSocket(
        daemon,
        url: 'http://127.0.0.1:$port',
        hardwareId: 'auth-exchange-e2e',
      );
      addTearDown(socket.dispose);
      await _waitForLocalSocket(socket);

      final authFile = File(
        '${daemon.isolatedSanadHome.path}${Platform.pathSeparator}auth.json',
      );
      final authDocument =
          Map<String, dynamic>.from(
              jsonDecode(await authFile.readAsString()) as Map,
            )
            ..['access_token'] = 'e2e-access'
            ..['refresh_token'] = 'e2e-refresh';
      await authFile.writeAsString(jsonEncode(authDocument), flush: true);

      var exchange = _waitForAuthenticationExchange(socket);
      socket.emit('authentication_exchange', const {});
      expect(await exchange, {'type': 'authentication_exchange'});

      authDocument
        ..remove('access_token')
        ..remove('refresh_token');
      await authFile.writeAsString(jsonEncode(authDocument), flush: true);
      exchange = _waitForAuthenticationExchange(socket);
      socket.emit('authentication_exchange', const {});
      expect(await exchange, {'type': 'authentication_exchange'});
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'runs a complete deterministic conversation through the local daemon websocket',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory('${Directory.current.parent.path}${Platform.pathSeparator}agent');
      expect(sanadagentLocalDir.existsSync(), isTrue);
      final localGatewayUrl = 'http://127.0.0.1:$port';
      final currentDeviceId = 'local-device-e2e';
      final agent = DeviceConfig(
        id: 'sanadagent-local-e2e',
        name: 'SanadAgent Local',
        hardwareId: currentDeviceId,
        isOnline: true,
      );

      final daemon = await _startDaemon(sanadagentLocalDir: sanadagentLocalDir, port: port);
      addTearDown(daemon.stop);

      final cloudSocket = SanadSocketService(url: 'http://127.0.0.1:65535', hardwareId: currentDeviceId);
      final localSocket = _localSocket(
        daemon,
        url: localGatewayUrl,
        hardwareId: currentDeviceId,
      );
      addTearDown(() {
        localSocket.dispose();
        cloudSocket.dispose();
      });

      await _waitForLocalSocket(localSocket);
      expect(localSocket.isConnected, isTrue);

      final resolver = DeviceConnectionCoordinator(
        cloudSocketService: cloudSocket,
        localSocketService: localSocket,
        currentDeviceId: currentDeviceId,
      );
      final capabilitiesStore = DeviceCapabilitiesStore(resolver);
      final conversationRegistry = ConversationClientRegistryImpl(resolver, capabilitiesStore);
      addTearDown(() {
        conversationRegistry.dispose();
        capabilitiesStore.dispose();
        resolver.dispose();
      });

      await resolver.ensureLocalConnection();
      final endpoint = resolver.resolve(agent);
      expect(endpoint.scope, ConnectionScope.local);
      expect(endpoint.isLocalReachable, isTrue);

      final caps = await capabilitiesStore.ensureFreshForAgent(agent, force: true);
      expect(caps.supportsStop, isTrue);
      expect(caps.thinkingModesList, isNotEmpty);

      final conversationClient = conversationRegistry.getOrCreateConversationClientForAgent(agent);
      final sessionsBefore = await conversationClient.getSessions();
      expect(sessionsBefore.sessions, isA<List>());

      final createdSession = await conversationClient.createSession(
        title: 'Deterministic E2E Session',
      );
      expect(createdSession.id, isNotEmpty);
      expect(createdSession.deviceId, equals(agent.id));

      final sessionId = createdSession.id;
      final finalAnswer = await _runThinkE2e(
        socket: localSocket,
        conversationClient: conversationClient,
        sessionId: sessionId,
        model: null,
        thinkingMode: caps.thinkingModesList.isEmpty ? null : caps.thinkingModesList.first,
      );

      expect(finalAnswer, 'e2e-success');

      final history = await conversationClient.loadSessionHistory(sessionId);
      expect(history, isNotEmpty);

      await conversationClient.updateSessionTitle(sessionId, 'Local E2E Updated');
      final sessionsAfterUpdate = await conversationClient.getSessions();
      final updatedSession = sessionsAfterUpdate.sessions.where((session) => session.id == sessionId).firstOrNull;
      expect(updatedSession, isNotNull);
      expect(updatedSession!.title, 'Local E2E Updated');

      await conversationClient.deleteSession(sessionId);
      final sessionsAfterDelete = await conversationClient.getSessions();
      expect(sessionsAfterDelete.sessions.any((session) => session.id == sessionId), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'mutates workspace folders through the spawned daemon protocol',
    () async {
      final port = _pickPort();
      final agentDir = Directory(
        '${Directory.current.parent.path}${Platform.pathSeparator}agent',
      );
      final parent = await Directory.systemTemp.createTemp(
        'sanad-folder-mutation-e2e-',
      );
      addTearDown(() async {
        if (parent.existsSync()) {
          await parent.delete(recursive: true);
        }
      });

      final daemon = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: port,
      );
      addTearDown(daemon.stop);
      final socket = _localSocket(
        daemon,
        url: 'http://127.0.0.1:$port',
        hardwareId: 'workspace-folder-e2e',
      );
      addTearDown(socket.dispose);
      await _waitForLocalSocket(socket);

      final created = await _requestLocalRuntime(
        socket: socket,
        command: 'workspace.create_folder',
        payload: {'parent_path': parent.path, 'name': 'created'},
        expectedEvent: 'workspace.folder_created',
      );
      final createdPath = created['path'] as String;
      expect(Directory(createdPath).existsSync(), isTrue);

      final renamed = await _requestLocalRuntime(
        socket: socket,
        command: 'workspace.rename_folder',
        payload: {'path': createdPath, 'new_name': 'renamed'},
        expectedEvent: 'workspace.folder_renamed',
      );
      final renamedPath = renamed['path'] as String;
      expect(Directory(createdPath).existsSync(), isFalse);
      expect(Directory(renamedPath).existsSync(), isTrue);
      await File(
        '$renamedPath${Platform.pathSeparator}nested.txt',
      ).writeAsString('recursive delete');

      final deleted = await _requestLocalRuntime(
        socket: socket,
        command: 'workspace.delete_folder',
        payload: {'path': renamedPath},
        expectedEvent: 'workspace.folder_deleted',
      );
      expect(deleted['path'], renamedPath);
      expect(Directory(renamedPath).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'exposes MCP runtime queries and mutations through the local daemon websocket',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory('${Directory.current.parent.path}${Platform.pathSeparator}agent');
      final currentDeviceId = 'local-device-mcp-e2e';
      var workspacePath =
          '${Directory.systemTemp.path}${Platform.pathSeparator}sanad-mcp-e2e-${DateTime.now().millisecondsSinceEpoch}';

      await Directory(workspacePath).create(recursive: true);
      addTearDown(() async {
        final directory = Directory(workspacePath);
        if (directory.existsSync()) {
          await directory.delete(recursive: true);
        }
      });

      final daemon = await _startDaemon(sanadagentLocalDir: sanadagentLocalDir, port: port);
      addTearDown(daemon.stop);

      final localSocket = _localSocket(
        daemon,
        url: 'http://127.0.0.1:$port',
        hardwareId: currentDeviceId,
      );
      addTearDown(localSocket.dispose);

      await _waitForLocalSocket(localSocket);

      final createdWorkspacePayload = await _requestLocalRuntime(
        socket: localSocket,
        command: 'create_workspace',
        payload: {'path': workspacePath, 'name': 'E2E Workspace'},
        expectedEvent: 'workspace_created',
      );
      final createdWorkspace = Map<String, dynamic>.from(
        createdWorkspacePayload['workspace'] as Map,
      );
      final workspaceId = createdWorkspace['id'] as String;
      expect(workspaceId, isNot(workspacePath));

      final renamedWorkspacePayload = await _requestLocalRuntime(
        socket: localSocket,
        command: 'workspace.rename',
        payload: {
          'workspace_id': workspaceId,
          'display_name': 'Renamed E2E Workspace',
        },
        expectedEvent: 'workspace.renamed',
      );
      expect(
        (renamedWorkspacePayload['workspace'] as Map)['name'],
        'Renamed E2E Workspace',
      );

      final movedPath = '$workspacePath-moved';
      await Directory(workspacePath).rename(movedPath);
      workspacePath = movedPath;
      final missingList = await _requestLocalRuntime(
        socket: localSocket,
        command: 'list_workspaces',
        payload: const {},
        expectedEvent: 'workspaces_list',
      );
      final missingWorkspace = (missingList['workspaces'] as List).whereType<Map>().firstWhere(
        (workspace) => workspace['id'] == workspaceId,
      );
      expect(missingWorkspace['availability'], 'missing');

      final relocatedWorkspacePayload = await _requestLocalRuntime(
        socket: localSocket,
        command: 'workspace.relocate',
        payload: {'workspace_id': workspaceId, 'new_path': workspacePath},
        expectedEvent: 'workspace.relocated',
      );
      final relocatedWorkspace = relocatedWorkspacePayload['workspace'] as Map;
      expect(relocatedWorkspace['id'], workspaceId);
      expect(relocatedWorkspace['availability'], 'available');

      final saved = await _requestLocalRuntime(
        socket: localSocket,
        command: 'save_mcp_server',
        payload: {
          'scope': 'workspace',
          'workspace_id': workspaceId,
          'config': {
            'name': 'filesystem',
            'command': 'npx',
            'args': ['-y', '@modelcontextprotocol/server-filesystem'],
          },
        },
        expectedEvent: 'mcp_server_saved',
      );
      final savedWorkspaceServers = (saved['workspace'] as Map<String, dynamic>)['servers'] as List<dynamic>;
      expect(savedWorkspaceServers.single['name'], 'filesystem');

      final listed = await _requestLocalRuntime(
        socket: localSocket,
        command: 'list_mcp_servers',
        payload: {
          'workspace_id': workspaceId,
        },
        expectedEvent: 'mcp_servers_list',
      );
      final effectiveServers = (listed['effective'] as Map<String, dynamic>)['servers'] as List<dynamic>;
      expect(effectiveServers.any((entry) => entry['name'] == 'filesystem'), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'hydrates waiting recovery after client recreation, then stop clears it and the next message can run',
    () async {
      final port = _pickPort();
      final sanadagentLocalDir = Directory(
        '${Directory.current.parent.path}${Platform.pathSeparator}agent',
      );
      expect(sanadagentLocalDir.existsSync(), isTrue);
      final localGatewayUrl = 'http://127.0.0.1:$port';
      final currentDeviceId = 'local-device-recovery-e2e';
      final agent = DeviceConfig(
        id: 'sanadagent-local-recovery-e2e',
        name: 'SanadAgent Local Recovery',
        hardwareId: currentDeviceId,
        isOnline: true,
      );

      final daemon = await _startDaemon(
        sanadagentLocalDir: sanadagentLocalDir,
        port: port,
      );
      addTearDown(daemon.stop);

      final firstCloudSocket = SanadSocketService(
        url: 'http://127.0.0.1:65535',
        hardwareId: currentDeviceId,
      );
      final firstLocalSocket = _localSocket(
        daemon,
        url: localGatewayUrl,
        hardwareId: currentDeviceId,
      );
      var firstStackDisposed = false;
      addTearDown(() {
        firstLocalSocket.dispose();
        firstCloudSocket.dispose();
      });

      await _waitForLocalSocket(firstLocalSocket);
      final firstResolver = DeviceConnectionCoordinator(
        cloudSocketService: firstCloudSocket,
        localSocketService: firstLocalSocket,
        currentDeviceId: currentDeviceId,
      );
      final firstCapabilitiesStore = DeviceCapabilitiesStore(firstResolver);
      final firstRegistry = ConversationClientRegistryImpl(
        firstResolver,
        firstCapabilitiesStore,
      );
      addTearDown(() {
        if (!firstStackDisposed) {
          firstRegistry.dispose();
          firstCapabilitiesStore.dispose();
          firstResolver.dispose();
        }
      });

      await firstResolver.ensureLocalConnection();
      final firstClient = firstRegistry.getOrCreateConversationClientForAgent(
        agent,
      );
      final createdSession = await firstClient.createSession(
        title: 'Recovery E2E Session',
      );
      firstClient.activateSession(createdSession.id);

      firstLocalSocket.emit('protocol_event', {
        'event': {
          'type': 'debug.runtime_notice_wait',
          'session_id': createdSession.id,
          'payload': {
            'session_id': createdSession.id,
            'request_id': 'recovery-request-1',
            'provider_instance_id': 'e2e-provider',
            'retry_after_ms': 45000,
            'requests_per_minute': 38,
          },
        },
      });

      await _waitForRuntimeNotice(
        firstClient,
        sessionId: createdSession.id,
        expectedStatus: 'waiting',
      );

      firstRegistry.dispose();
      firstCapabilitiesStore.dispose();
      firstResolver.dispose();
      firstStackDisposed = true;

      final reconnectCloudSocket = SanadSocketService(
        url: 'http://127.0.0.1:65535',
        hardwareId: currentDeviceId,
      );
      final reconnectLocalSocket = _localSocket(
        daemon,
        url: localGatewayUrl,
        hardwareId: currentDeviceId,
      );
      addTearDown(() {
        reconnectLocalSocket.dispose();
        reconnectCloudSocket.dispose();
      });

      await _waitForLocalSocket(reconnectLocalSocket);
      final reconnectResolver = DeviceConnectionCoordinator(
        cloudSocketService: reconnectCloudSocket,
        localSocketService: reconnectLocalSocket,
        currentDeviceId: currentDeviceId,
      );
      final reconnectCapabilitiesStore = DeviceCapabilitiesStore(
        reconnectResolver,
      );
      final reconnectRegistry = ConversationClientRegistryImpl(
        reconnectResolver,
        reconnectCapabilitiesStore,
      );
      addTearDown(() {
        reconnectRegistry.dispose();
        reconnectCapabilitiesStore.dispose();
        reconnectResolver.dispose();
      });

      await reconnectResolver.ensureLocalConnection();
      final reconnectClient = reconnectRegistry.getOrCreateConversationClientForAgent(agent);
      reconnectClient.activateSession(createdSession.id);

      final rehydratedHistory = await reconnectClient.loadSessionHistory(
        createdSession.id,
      );
      expect(rehydratedHistory, isA<List>());

      await _waitForRuntimeNotice(
        reconnectClient,
        sessionId: createdSession.id,
        expectedStatus: 'waiting',
      );
      expect(
        reconnectClient.currentRuntimeNotice?.requestsPerMinuteLimit,
        equals(38),
      );
      expect(reconnectClient.currentQueuedMessages, isEmpty);

      final stopEvents = <String>[];
      final stopCompleter = Completer<void>();
      late final StreamSubscription<Map<String, dynamic>> stopSubscription;
      stopSubscription = reconnectLocalSocket.events.listen((event) {
        if (event['type'] != 'device_event') {
          return;
        }
        final payload = event['payload'] is Map
            ? Map<String, dynamic>.from(event['payload'] as Map)
            : <String, dynamic>{};
        final eventSessionId = event['session_id'] as String? ?? payload['session_id'] as String?;
        if (eventSessionId != createdSession.id) {
          return;
        }
        final eventType = event['event'] as String? ?? payload['type'] as String?;
        if (eventType == 'stopped' || eventType == 'session.runtime_notice_cleared') {
          stopEvents.add(eventType!);
        }
        if (stopEvents.contains('stopped') &&
            stopEvents.contains('session.runtime_notice_cleared') &&
            !stopCompleter.isCompleted) {
          stopCompleter.complete();
        }
      });

      try {
        await reconnectClient.stop(sessionId: createdSession.id);
        await stopCompleter.future.timeout(const Duration(seconds: 20));
      } finally {
        await stopSubscription.cancel();
      }

      await _waitForRuntimeNoticeCleared(
        reconnectClient,
        sessionId: createdSession.id,
      );
      expect(reconnectClient.currentQueuedMessages, isEmpty);

      final finalAnswer = await _runThinkE2e(
        socket: reconnectLocalSocket,
        conversationClient: reconnectClient,
        sessionId: createdSession.id,
        model: null,
        thinkingMode: null,
        message: 'Continue after recovery.',
      );
      expect(finalAnswer, equals('e2e-success'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'migrates a legacy Home and reconnects after daemon restart without touching workspace files',
    () async {
      final agentDir = Directory(
        '${Directory.current.parent.path}${Platform.pathSeparator}agent',
      );
      final home = await Directory.systemTemp.createTemp(
        'sanad-legacy-home-e2e-',
      );
      final stateHome = await Directory.systemTemp.createTemp(
        'sanad-legacy-state-e2e-',
      );
      final workspace = await Directory.systemTemp.createTemp(
        'sanad-workspace-marker-e2e-',
      );
      addTearDown(() async {
        for (final directory in [home, stateHome, workspace]) {
          if (directory.existsSync()) await directory.delete(recursive: true);
        }
      });
      final legacyAuth = File(
        '${home.path}${Platform.pathSeparator}auth.json',
      )..writeAsStringSync('{"hardware_id":"legacy-e2e"}');
      final marker = File(
        '${workspace.path}${Platform.pathSeparator}unchanged.txt',
      )..writeAsStringSync('workspace-untouched');
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['644', legacyAuth.path]);
      }

      final firstPort = _pickPort();
      final first = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: firstPort,
        existingStateHome: stateHome,
        existingSanadHome: home,
      );
      addTearDown(first.stop);
      final firstSocket = _localSocket(
        first,
        url: 'http://127.0.0.1:$firstPort',
        hardwareId: 'legacy-restart-e2e',
      );
      await _waitForLocalSocket(firstSocket);
      final firstToken = await LocalGatewayCredentialProvider(
        sanadHomePath: home.path,
      ).read();
      firstSocket.dispose();
      await first.stop();

      if (!Platform.isWindows) {
        expect(legacyAuth.statSync().mode & 0x1ff, 0x180);
        expect(home.statSync().mode & 0x1ff, 0x1c0);
        expect(stateHome.statSync().mode & 0x1ff, 0x1c0);
      }
      expect(marker.readAsStringSync(), 'workspace-untouched');

      final secondPort = firstPort == 58185 ? 58184 : firstPort + 1;
      final second = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: secondPort,
        existingStateHome: stateHome,
        existingSanadHome: home,
      );
      addTearDown(second.stop);
      final secondSocket = _localSocket(
        second,
        url: 'http://127.0.0.1:$secondPort',
        hardwareId: 'legacy-restart-e2e',
      );
      addTearDown(secondSocket.dispose);
      await _waitForLocalSocket(secondSocket);
      final secondToken = await LocalGatewayCredentialProvider(
        sanadHomePath: home.path,
      ).read();

      expect(secondToken, firstToken);
      expect(marker.readAsStringSync(), 'workspace-untouched');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'connects two isolated daemon and client pairs on distinct Homes and ports',
    () async {
      final agentDir = Directory(
        '${Directory.current.parent.path}${Platform.pathSeparator}agent',
      );
      final firstPort = _pickPort();
      final secondPort = firstPort + 1;
      final first = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: firstPort,
      );
      final second = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: secondPort,
      );
      addTearDown(first.stop);
      addTearDown(second.stop);
      final firstSocket = _localSocket(
        first,
        url: 'http://127.0.0.1:$firstPort',
        hardwareId: 'isolated-pair-one',
      );
      final secondSocket = _localSocket(
        second,
        url: 'http://127.0.0.1:$secondPort',
        hardwareId: 'isolated-pair-two',
      );
      addTearDown(firstSocket.dispose);
      addTearDown(secondSocket.dispose);

      await Future.wait([
        _waitForLocalSocket(firstSocket),
        _waitForLocalSocket(secondSocket),
      ]);
      final firstToken = await LocalGatewayCredentialProvider(
        sanadHomePath: first.isolatedSanadHome.path,
      ).read();
      final secondToken = await LocalGatewayCredentialProvider(
        sanadHomePath: second.isolatedSanadHome.path,
      ).read();

      expect(firstSocket.isConnected, isTrue);
      expect(secondSocket.isConnected, isTrue);
      expect(first.isolatedSanadHome.path, isNot(second.isolatedSanadHome.path));
      expect(firstToken, isNot(secondToken));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'queries and resets provider usage through a spawned daemon and local HTTP fixture',
    () async {
      final fixture = await _ProviderUsageFixture.start();
      addTearDown(fixture.stop);
      final port = _pickPort();
      final agentDir = Directory(
        '${Directory.current.parent.path}${Platform.pathSeparator}agent',
      );
      final daemon = await _startDaemon(
        sanadagentLocalDir: agentDir,
        port: port,
        isolateSanadHome: true,
      );
      addTearDown(daemon.stop);

      const hardwareId = 'provider-usage-e2e-hardware';
      final cloudSocket = SanadSocketService(
        url: 'http://127.0.0.1:65535',
        hardwareId: hardwareId,
      );
      final localSocket = _localSocket(
        daemon,
        url: 'http://127.0.0.1:$port',
        hardwareId: hardwareId,
      );
      addTearDown(() {
        localSocket.dispose();
        cloudSocket.dispose();
      });
      await _waitForLocalSocket(localSocket);

      final coordinator = DeviceConnectionCoordinator(
        cloudSocketService: cloudSocket,
        localSocketService: localSocket,
        currentDeviceId: hardwareId,
      );
      addTearDown(coordinator.dispose);
      final client = ProviderSetupClientImpl(
        connectionCoordinator: coordinator,
      );
      final agent = DeviceConfig(
        id: 'provider-usage-e2e-device',
        name: 'Provider Usage E2E',
        hardwareId: hardwareId,
        isOnline: true,
      );
      await coordinator.ensureLocalConnection();

      final instance = await client.createInstance(
        templateId: 'openai-codex',
        displayName: 'Fixture ChatGPT',
        authMethod: 'api_key',
        baseUrl: '${fixture.baseUrl}/backend-api/codex',
        agent: agent,
      );
      await client.updateCredential(
        providerInstanceId: instance.id,
        action: 'replace',
        apiKey: 'fixture-token',
        agent: agent,
      );

      final support = await client.usageSupport(
        providerInstanceIds: [instance.id],
        agent: agent,
      );
      expect(support.support[instance.id], isTrue);

      final before = await client.usageGet(
        providerInstanceId: instance.id,
        agent: agent,
      );
      expect(before.status, 'available');
      expect(before.snapshot!.availableResets, 1);
      expect(before.snapshot!.windows.single.remainingPercent, 0);

      final reset = await client.usageReset(
        providerInstanceId: instance.id,
        idempotencyKey: 'provider-usage-e2e-reset',
        agent: agent,
      );
      expect(reset.status, 'reset');
      expect(reset.refreshFailed, isFalse);
      expect(reset.snapshot!.availableResets, 0);
      expect(reset.snapshot!.windows.single.remainingPercent, 100);
      expect(fixture.consumeCalls, 1);
      expect(fixture.authorizationHeaders, everyElement('Bearer fixture-token'));
      expect(
        fixture.paths,
        containsAllInOrder([
          '/backend-api/wham/usage',
          '/backend-api/wham/usage',
          '/backend-api/wham/rate-limit-reset-credits/consume',
          '/backend-api/wham/usage',
        ]),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

int _pickPort() {
  const basePort = 58120;
  return basePort + (DateTime.now().millisecondsSinceEpoch % 200);
}

String _getDartExecutablePath() {
  final resolved = Platform.resolvedExecutable;
  if (resolved.contains('flutter_tester')) {
    final file = File(resolved);
    final cacheDir = file.parent.parent.parent.parent;
    final dartSdkBin = Directory('${cacheDir.path}${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin');
    final dartExe = Platform.isWindows ? 'dart.exe' : 'dart';
    final dartFile = File('${dartSdkBin.path}${Platform.pathSeparator}$dartExe');
    if (dartFile.existsSync()) {
      return dartFile.path;
    }
  }
  return resolved;
}

class _E2eDaemon {
  _E2eDaemon(
    this.process,
    this.stateHome,
    this.isolatedSanadHome, {
    required this.deleteStateHome,
    required this.deleteSanadHome,
  });

  final Process process;
  final Directory stateHome;
  final Directory isolatedSanadHome;
  final bool deleteStateHome;
  final bool deleteSanadHome;
  bool _stopped = false;

  Future<void> stop() async {
    if (!_stopped) {
      _stopped = true;
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
    if (deleteStateHome && stateHome.existsSync()) {
      await stateHome.delete(recursive: true);
    }
    if (deleteSanadHome && isolatedSanadHome.existsSync()) {
      await isolatedSanadHome.delete(recursive: true);
    }
  }
}

Future<_E2eDaemon> _startDaemon({
  required Directory sanadagentLocalDir,
  required int port,
  bool isolateSanadHome = false,
  Directory? existingStateHome,
  Directory? existingSanadHome,
}) async {
  final stateHome = existingStateHome ?? await Directory.systemTemp.createTemp('sanad-local-daemon-e2e-');
  final ownsStateHome = existingStateHome == null;
  final liveStateHome = Platform.environment['SANAD_STATE_HOME']?.trim().isNotEmpty == true
      ? Platform.environment['SANAD_STATE_HOME']!.trim()
      : Platform.environment['SANAD_HOME']?.trim().isNotEmpty == true
      ? Platform.environment['SANAD_HOME']!.trim()
      : '${Platform.environment['HOME']}${Platform.pathSeparator}.sanad';
  if (stateHome.absolute.path == Directory(liveStateHome).absolute.path) {
    if (ownsStateHome) await stateHome.delete(recursive: true);
    throw StateError('E2E state must not use the live Sanad state directory.');
  }

  final isolatedSanadHome =
      existingSanadHome ??
      await Directory.systemTemp.createTemp(
        isolateSanadHome ? 'sanad-provider-usage-home-e2e-' : 'sanad-local-home-e2e-',
      );
  final ownsSanadHome = existingSanadHome == null;
  final environment = <String, String>{
    ...Platform.environment,
    'ENABLE_GATEWAY': 'false',
    'ENABLE_LOCAL_GATEWAY': 'true',
    'LOCAL_GATEWAY_PORT': '$port',
    'SANAD_E2E_TEST_MODE': 'true',
    'SANAD_STATE_HOME': stateHome.path,
    'SANAD_HOME': isolatedSanadHome.path,
    if (isolateSanadHome) ...{
      'LLM_MODEL': 'sanad-e2e-model',
      'LLM_BASE_URL': 'http://127.0.0.1:1/e2e',
    },
    'DUMP_REQUESTS': 'false',
  };

  late final Process process;
  try {
    process = await Process.start(
      _getDartExecutablePath(),
      ['bin/daemon.dart'],
      workingDirectory: sanadagentLocalDir.path,
      environment: environment,
    );
  } catch (_) {
    if (ownsStateHome) await stateHome.delete(recursive: true);
    if (ownsSanadHome && isolatedSanadHome.existsSync()) {
      await isolatedSanadHome.delete(recursive: true);
    }
    rethrow;
  }

  unawaited(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stdout.writeln('[daemon] $line'))
        .asFuture<void>(),
  );
  unawaited(
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[daemon] $line'))
        .asFuture<void>(),
  );

  return _E2eDaemon(
    process,
    stateHome,
    isolatedSanadHome,
    deleteStateHome: ownsStateHome,
    deleteSanadHome: ownsSanadHome,
  );
}

SanadSocketService _localSocket(
  _E2eDaemon daemon, {
  required String url,
  required String hardwareId,
}) {
  return SanadSocketService.local(
    url: url,
    hardwareId: hardwareId,
    credentialProvider: LocalGatewayCredentialProvider(
      sanadHomePath: daemon.isolatedSanadHome.path,
    ),
  );
}

class _ProviderUsageFixture {
  _ProviderUsageFixture(this.server);

  final HttpServer server;
  final List<String> paths = [];
  final List<String?> authorizationHeaders = [];
  var consumeCalls = 0;
  var resetApplied = false;
  StreamSubscription<HttpRequest>? _subscription;

  String get baseUrl => 'http://${server.address.address}:${server.port}';

  static Future<_ProviderUsageFixture> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = _ProviderUsageFixture(server);
    fixture._subscription = server.listen(fixture._handle);
    return fixture;
  }

  Future<void> _handle(HttpRequest request) async {
    paths.add(request.uri.path);
    authorizationHeaders.add(request.headers.value(HttpHeaders.authorizationHeader));
    request.response.headers.contentType = ContentType.json;
    if (request.method == 'GET' && request.uri.path == '/backend-api/wham/usage') {
      request.response.write(
        jsonEncode({
          'plan_type': 'plus',
          'rate_limit': {
            'primary_window': {
              'used_percent': resetApplied ? 0 : 100,
              'reset_at': 1780230796,
            },
          },
          'rate_limit_reset_credits': {
            'available_count': resetApplied ? 0 : 1,
          },
        }),
      );
    } else if (request.method == 'POST' && request.uri.path == '/backend-api/wham/rate-limit-reset-credits/consume') {
      consumeCalls++;
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      if (body is! Map || body['redeem_request_id'] == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write(jsonEncode({'code': 'invalid_request'}));
      } else {
        resetApplied = true;
        request.response.write(jsonEncode({'code': 'reset'}));
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'code': 'not_found'}));
    }
    await request.response.close();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    await server.close(force: true);
  }
}

Future<Map<String, dynamic>> _waitForAuthenticationExchange(
  SanadSocketService socket,
) async {
  return socket.events
      .firstWhere((event) => event['type'] == 'authentication_exchange')
      .timeout(const Duration(seconds: 10));
}

Future<void> _waitForLocalSocket(SanadSocketService socket) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  Object? lastError;

  while (DateTime.now().isBefore(deadline)) {
    try {
      await socket.connect();
      if (socket.isConnected) {
        return;
      }
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  throw StateError('Local socket did not become ready in time. Last error: $lastError');
}

Future<String> _runThinkE2e({
  required SanadSocketService socket,
  required ConversationClient conversationClient,
  required String sessionId,
  required String? model,
  required String? thinkingMode,
  String message = 'Reply with one short word for the local dual connection e2e test.',
}) async {
  final completer = Completer<String>();
  late final StreamSubscription<Map<String, dynamic>> subscription;

  subscription = socket.events.listen((event) {
    if (event['type'] != 'device_event') {
      return;
    }

    final payload = event['payload'] is Map ? Map<String, dynamic>.from(event['payload'] as Map) : <String, dynamic>{};
    final eventType = event['event'] as String?;
    final eventSessionId = event['session_id'] as String? ?? payload['session_id'] as String?;
    if (eventSessionId != sessionId) {
      return;
    }

    if (eventType == 'error' && !completer.isCompleted) {
      completer.completeError(StateError(payload['content']?.toString() ?? 'Local think failed.'));
      return;
    }

    if (eventType == 'final_answer') {
      final content = payload['content']?.toString() ?? '';
      final runId = event['run_id'] as String? ?? payload['run_id'] as String?;
      if (content.trim().isEmpty) {
        completer.completeError(StateError('Received an empty final_answer payload.'));
        return;
      }
      if (runId == null || runId.isEmpty) {
        completer.completeError(StateError('final_answer is missing run_id.'));
        return;
      }
      if (!completer.isCompleted) {
        completer.complete(content);
      }
    }
  });

  try {
    await conversationClient.sendMessage(
      message,
      sessionId: sessionId,
      model: model,
      thinkingMode: thinkingMode,
    );

    return await completer.future.timeout(const Duration(seconds: 90));
  } finally {
    await subscription.cancel();
  }
}

Future<void> _waitForRuntimeNotice(
  ConversationClient client, {
  required String sessionId,
  required String expectedStatus,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final notice = client.currentRuntimeNotice;
    if (notice != null && notice.sessionId == sessionId && notice.status == expectedStatus) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
    'Timed out waiting for runtime notice $expectedStatus on session $sessionId.',
  );
}

Future<void> _waitForRuntimeNoticeCleared(
  ConversationClient client, {
  required String sessionId,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final notice = client.currentRuntimeNotice;
    if (notice == null || notice.sessionId != sessionId) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError(
    'Timed out waiting for runtime notice to clear on session $sessionId.',
  );
}

Future<Map<String, dynamic>> _requestLocalRuntime({
  required SanadSocketService socket,
  required String command,
  required Map<String, dynamic> payload,
  required String expectedEvent,
}) async {
  final requestId = 'req-${DateTime.now().microsecondsSinceEpoch}';
  final completer = Completer<Map<String, dynamic>>();
  late final StreamSubscription<Map<String, dynamic>> subscription;

  subscription = socket.events.listen((event) {
    if (event['type'] != 'device_event') {
      return;
    }
    if (event['event'] != expectedEvent) {
      return;
    }

    final eventPayload = event['payload'] is Map
        ? Map<String, dynamic>.from(event['payload'] as Map)
        : <String, dynamic>{};
    if (eventPayload['request_id'] != requestId) {
      return;
    }
    if (!completer.isCompleted) {
      completer.complete(eventPayload);
    }
  });

  socket.sendDeviceCommand(deviceId: '', command: command, payload: {'request_id': requestId, ...payload});

  try {
    return await completer.future.timeout(const Duration(seconds: 20));
  } finally {
    await subscription.cancel();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (!iterator.moveNext()) {
      return null;
    }
    return iterator.current;
  }
}
