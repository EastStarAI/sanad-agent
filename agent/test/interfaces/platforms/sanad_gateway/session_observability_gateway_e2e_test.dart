import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/cli/client/local_gateway_cli_client.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/colocated_auth_coupling.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:test/test.dart';

import '../../../support/isolated_sanad_test_home.dart';
import '../../../support/memory_agent_secret_store.dart';

class _TestConfig extends Config {
  _TestConfig(this._port);

  final int _port;

  @override
  String get localGatewayHost => '127.0.0.1';

  @override
  int get localGatewayPort => _port;

  @override
  String get localGatewayUrl => 'http://127.0.0.1:$_port';
}

class _TestAuthManager extends AuthManager {
  _TestAuthManager() : super(secretStore: MemoryAgentSecretStore());

  final _controller = StreamController<void>.broadcast();
  String? cloudDeviceCredential;

  @override
  String? get deviceToken => cloudDeviceCredential;

  @override
  String? get hardwareId => 'hardware-e2e-1';

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async => true;

  @override
  Future<void> logout() async {
    cloudDeviceCredential = null;
    _controller.add(null);
  }

  Future<void> close() => _controller.close();
}

class _E2EFakeSuspendedResumeService extends SuspendedResumeService {
  _E2EFakeSuspendedResumeService()
    : super(
        checkpointStore: SuspendedCheckpointStore(
          sessionManager: SessionManager(),
        ),
        sessionManager: SessionManager(),
        runtimeCatalog: LocalRuntimeCatalog(
          workspaceRuntimeService: LocalWorkspaceRuntimeService(
            skillRegistry: const SkillRegistry(),
            skillLoadService: SkillLoadService(registry: const SkillRegistry()),
          ),
          permissionManager: PermissionManager(
            policyStore: const WorkspacePolicyStore(),
            platformRuntimeBridge: PlatformRuntimeBridge(),
            checkpointStore: SuspendedCheckpointStore(
              sessionManager: SessionManager(),
            ),
          ),
          platformRuntimeBridge: PlatformRuntimeBridge(),
        ),
        runtimeContextBuilder: const RuntimeContextBuilder(
          skillRegistry: SkillRegistry(),
        ),
        workspaceRuntimeService: LocalWorkspaceRuntimeService(
          skillRegistry: const SkillRegistry(),
          skillLoadService: SkillLoadService(registry: const SkillRegistry()),
        ),
        permissionManager: PermissionManager(
          policyStore: const WorkspacePolicyStore(),
          platformRuntimeBridge: PlatformRuntimeBridge(),
          checkpointStore: SuspendedCheckpointStore(
            sessionManager: SessionManager(),
          ),
        ),
      );

  int callCount = 0;
  String? lastRequestId;
  Map<String, dynamic>? lastDecision;

  @override
  Future<bool> resumeFromDecision({
    required String requestId,
    required Map<String, dynamic> decision,
    required SuspendedResponseEmitter emitResponse,
    SuspendedDecisionClaimed? onClaimed,
  }) async {
    callCount++;
    SessionManager().claimSuspendedCheckpointDecision(
      requestId: requestId,
      status: 'resuming',
    );
    await onClaimed?.call();
    lastRequestId = requestId;
    lastDecision = decision;
    return true;
  }
}

Future<int> _reserveFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  useIsolatedSanadTestHome();

  group('Session Observability and Safe Intervention E2E Gateway', () {
    const token = LocalGatewayCredential('test-e2e-token');
    late LocalDaemonServerPlatform platform;
    late DeliveryPresenceController deliveryPresence;
    late _TestAuthManager authManager;
    late AgentStateDatabase stateDb;
    late SessionDB sessionDb;
    late SessionManager sessionManager;
    late PlatformRuntimeBridge runtimeBridge;
    late _E2EFakeSuspendedResumeService resumeService;
    late LocalGatewayCliClient client;
    late int port;

    void seedSession(
      String sessionId, {
      String? title,
      String model = 'mock-model',
    }) {
      final now = DateTime.now().toUtc();
      sessionDb.saveSession(
        SessionState(
          sessionId: sessionId,
          model: model,
          title: title,
          titleStatus: SessionTitleStatus.finalized,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }

    setUp(() async {
      await getIt.reset();
      SessionManager.resetForTesting();

      stateDb = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(stateDb);

      sessionDb = SessionDB.fromState(stateDb);
      sessionManager = SessionManager();
      getIt.registerSingleton<SessionManager>(sessionManager);

      final checkpointStore = SuspendedCheckpointStore(
        sessionManager: sessionManager,
      );
      getIt.registerSingleton<SuspendedCheckpointStore>(checkpointStore);

      port = await _reserveFreePort();
      getIt.registerSingleton<Config>(_TestConfig(port));

      authManager = _TestAuthManager()
        ..cloudDeviceCredential = 'credential-e2e-test';
      getIt.registerSingleton<AuthManager>(
        authManager,
        dispose: (manager) => authManager.close(),
      );

      runtimeBridge = PlatformRuntimeBridge();
      getIt.registerSingleton<PlatformRuntimeBridge>(runtimeBridge);

      resumeService = _E2EFakeSuspendedResumeService();
      getIt.registerSingleton<SuspendedResumeService>(resumeService);

      final protocolBridge = SanadProtocolBridge();
      getIt.registerSingleton<SanadProtocolBridge>(protocolBridge);

      deliveryPresence = DeliveryPresenceController();

      platform = LocalDaemonServerPlatform(
        deliveryPresence: deliveryPresence,
        authCoupling: ColocatedAuthCoupling(
          authManager: authManager,
          authorizationClient: DeviceAuthorizationClient(
            portalUrl: 'https://portal.test',
            authManager: authManager,
          ),
        ),
        security: LocalGatewaySecurity(
          config: LocalGatewaySecurityConfig(
            allowedPort: port,
            preauthBudgetPerPeer: 1,
          ),
          expectedToken: token,
        ),
      );
      await platform.initialize();

      client = LocalGatewayCliClient(
        gatewayUri: Uri.parse('ws://127.0.0.1:$port/gateway'),
        token: token.value,
        deviceId: 'cli-e2e-tester',
        autoReconnect: false,
      );
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
      await platform.dispose();
      await deliveryPresence.dispose();
      SessionManager.resetForTesting();
      await getIt.reset();
      stateDb.dispose();
    });

    test(
      'session list and show expose pending intervention and in_flight execution over real gateway',
      () async {
        final now = DateTime.now().toUtc();

        seedSession('session-alpha', title: 'Database Design');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-1',
            sessionId: 'session-alpha',
            requestId: 'ask-req-1',
            toolCallId: 'tc-1',
            toolName: 'system_ask_user',
            status: 'awaiting_permission',
            toolArguments: {
              'questions': [
                {
                  'question': 'Which database?',
                  'options': ['postgres', 'sqlite'],
                },
              ],
            },
            permissionPayload: {
              'request_id': 'ask-req-1',
              'tool_name': 'system_ask_user',
              'session_id': 'session-alpha',
              'questions': [
                {
                  'question': 'Which database?',
                  'options': ['postgres', 'sqlite'],
                },
              ],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        seedSession('session-beta', title: 'Shell Task');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-2',
            sessionId: 'session-beta',
            requestId: 'perm-req-2',
            toolCallId: 'tc-2',
            toolName: 'run_terminal_command',
            status: 'awaiting_permission',
            toolArguments: {'command': 'ls -la'},
            permissionPayload: {
              'request_id': 'perm-req-2',
              'tool_name': 'run_terminal_command',
              'session_id': 'session-beta',
              'tool_input': {'command': 'ls -la'},
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        // 1. Session list over real WebSocket
        final sessions = await client.getSessions();
        expect(sessions.length, greaterThanOrEqualTo(2));
        final alphaSummary = sessions.firstWhere(
          (s) =>
              s['session_id'] == 'session-alpha' || s['id'] == 'session-alpha',
        );
        final isAlphaPending =
            alphaSummary['has_pending_permission_request'] == true ||
            (alphaSummary['metadata'] is Map &&
                alphaSummary['metadata']['has_pending_permission_request'] ==
                    true);
        expect(isAlphaPending, isTrue);

        final betaSummary = sessions.firstWhere(
          (s) => s['session_id'] == 'session-beta' || s['id'] == 'session-beta',
        );
        final isBetaPending =
            betaSummary['has_pending_permission_request'] == true ||
            (betaSummary['metadata'] is Map &&
                betaSummary['metadata']['has_pending_permission_request'] ==
                    true);
        expect(isBetaPending, isTrue);

        // 2. Session show over real WebSocket (alpha: clarification -> needs_input)
        final alphaHistory = await client.getSessionHistory(
          sessionId: 'session-alpha',
        );
        final alphaPayload = alphaHistory['payload'] is Map
            ? alphaHistory['payload'] as Map<String, dynamic>
            : alphaHistory;
        expect(alphaPayload['pending_permission_request'], isNotNull);
        final alphaPending =
            alphaPayload['pending_permission_request'] as Map<String, dynamic>;
        expect(alphaPending['tool_name'], 'system_ask_user');
        expect(alphaPending['request_id'], 'ask-req-1');

        // 3. CLI runner running session show in --json mode
        final stdoutBuf = StringBuffer();
        final runner = SanadCommandRunner(
          client: client,
          stdoutSink: stdoutBuf,
          stderrSink: StringBuffer(),
        );

        final exitCodeAlpha = await runner.run([
          'session',
          'show',
          'session-alpha',
          '--json',
        ]);
        expect(exitCodeAlpha, 0);
        final alphaCli =
            jsonDecode(stdoutBuf.toString()) as Map<String, dynamic>;
        expect(alphaCli['status'], 'needs_input');
        expect(alphaCli['session_id'], 'session-alpha');

        stdoutBuf.clear();
        final exitCodeBeta = await runner.run([
          'session',
          'show',
          'session-beta',
          '--json',
        ]);
        expect(exitCodeBeta, 0);
        final betaCli =
            jsonDecode(stdoutBuf.toString()) as Map<String, dynamic>;
        expect(betaCli['status'], 'needs_permission');
        expect(betaCli['session_id'], 'session-beta');

        // The default --json projection is bounded: the full messages payload
        // is NOT embedded, while owner identities and count summaries are.
        expect(alphaCli.containsKey('messages'), isFalse);
        expect(betaCli.containsKey('messages'), isFalse);
        expect(alphaCli.containsKey('summary'), isTrue);
        expect(alphaCli.containsKey('identities'), isTrue);
        expect(alphaCli['identities']['session_id'], 'session-alpha');
        expect(alphaCli['message_count'], 0);

        stdoutBuf.clear();
        final exitCodeFull = await runner.run([
          'session',
          'show',
          'session-alpha',
          '--json',
          '--include-messages',
        ]);
        expect(exitCodeFull, 0);
        final alphaFull =
            jsonDecode(stdoutBuf.toString()) as Map<String, dynamic>;
        expect(alphaFull.containsKey('messages'), isTrue);
        expect(alphaFull['messages'], isEmpty);
        expect(alphaFull['summary'], isNotNull);
      },
    );

    test(
      'explicit answer resumes pending clarification over WebSocket gateway',
      () async {
        final now = DateTime.now().toUtc();
        seedSession('session-alpha');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-1',
            sessionId: 'session-alpha',
            requestId: 'ask-req-1',
            toolCallId: 'tc-1',
            toolName: 'system_ask_user',
            status: 'awaiting_permission',
            toolArguments: {
              'questions': [
                {'question': 'Preferred dialect?'},
              ],
            },
            permissionPayload: {
              'request_id': 'ask-req-1',
              'tool_name': 'system_ask_user',
              'session_id': 'session-alpha',
              'questions': [
                {'question': 'Preferred dialect?'},
              ],
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        final result = await client.respondAnswer(
          sessionId: 'session-alpha',
          requestId: 'ask-req-1',
          answer: 'PostgreSQL',
        );

        final payload = result['payload'] as Map<String, dynamic>;
        expect(payload['success'], isTrue);
        expect(payload['outcome'], 'resolved');

        expect(resumeService.callCount, 1);
        expect(resumeService.lastRequestId, 'ask-req-1');
        expect(resumeService.lastDecision?['answer'], 'PostgreSQL');
        expect(resumeService.lastDecision?['allowed'], isTrue);
      },
    );

    test(
      'ordinary tool permission intervention succeeds over WebSocket gateway',
      () async {
        final now = DateTime.now().toUtc();
        seedSession('session-beta');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-2',
            sessionId: 'session-beta',
            requestId: 'perm-req-2',
            toolCallId: 'tc-2',
            toolName: 'run_terminal_command',
            status: 'awaiting_permission',
            toolArguments: {'command': 'cat build.gradle'},
            permissionPayload: {
              'request_id': 'perm-req-2',
              'tool_name': 'run_terminal_command',
              'session_id': 'session-beta',
              'tool_input': {'command': 'cat build.gradle'},
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        final result = await client.respondToolPermission(
          sessionId: 'session-beta',
          requestId: 'perm-req-2',
          allowed: true,
          decision: 'allow',
          scope: 'session',
          comment: 'Approved by developer',
        );

        final payload = result['payload'] as Map<String, dynamic>;
        expect(payload['success'], isTrue);
        expect(payload['outcome'], 'resolved');

        expect(resumeService.callCount, 1);
        expect(resumeService.lastRequestId, 'perm-req-2');
        expect(resumeService.lastDecision?['allowed'], isTrue);
        expect(resumeService.lastDecision?['decision'], 'allow');
        expect(resumeService.lastDecision?['scope'], 'session');
        expect(resumeService.lastDecision?['comment'], 'Approved by developer');
      },
    );

    test(
      'rejects cross-session intervention attempts over WebSocket gateway',
      () async {
        final now = DateTime.now().toUtc();
        seedSession('session-legit');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-3',
            sessionId: 'session-legit',
            requestId: 'perm-req-3',
            toolCallId: 'tc-3',
            toolName: 'run_terminal_command',
            status: 'awaiting_permission',
            toolArguments: {'command': 'whoami'},
            permissionPayload: {
              'request_id': 'perm-req-3',
              'tool_name': 'run_terminal_command',
              'session_id': 'session-legit',
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        expect(
          () => client.respondToolPermission(
            sessionId: 'session-attacker',
            requestId: 'perm-req-3',
            allowed: true,
          ),
          throwsA(
            isA<CliClientException>().having(
              (e) => e.code,
              'code',
              'CROSS_SESSION_MISMATCH',
            ),
          ),
        );

        // Verify request was NOT claimed or resolved
        expect(resumeService.callCount, 0);
        final chk = sessionManager.getSuspendedCheckpointByRequestId(
          'perm-req-3',
        );
        expect(chk?.status, 'awaiting_permission');
      },
    );

    test(
      'rejects invalid intervention kinds over WebSocket gateway without claiming request',
      () async {
        final now = DateTime.now().toUtc();
        seedSession('session-tool');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-4',
            sessionId: 'session-tool',
            requestId: 'perm-req-4',
            toolCallId: 'tc-4',
            toolName: 'run_terminal_command',
            status: 'awaiting_permission',
            toolArguments: {'command': 'git status'},
            permissionPayload: {
              'request_id': 'perm-req-4',
              'tool_name': 'run_terminal_command',
              'session_id': 'session-tool',
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Attempting to answer a non-clarification tool permission request
        expect(
          () => client.respondAnswer(
            sessionId: 'session-tool',
            requestId: 'perm-req-4',
            answer: 'Not a question!',
          ),
          throwsA(
            isA<CliClientException>().having(
              (e) => e.code,
              'code',
              'INVALID_INTERVENTION_KIND',
            ),
          ),
        );

        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-empty',
            sessionId: 'session-tool',
            requestId: 'ask-req-empty',
            toolCallId: 'tc-empty',
            toolName: 'system_ask_user',
            status: 'awaiting_permission',
            toolArguments: {'question': 'Empty?'},
            permissionPayload: {
              'request_id': 'ask-req-empty',
              'tool_name': 'system_ask_user',
              'session_id': 'session-tool',
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Attempting to send empty answer to a clarification question
        expect(
          () => client.respondAnswer(
            sessionId: 'session-tool',
            requestId: 'ask-req-empty',
            answer: '   ',
          ),
          throwsA(
            isA<CliClientException>().having(
              (e) => e.code,
              'code',
              'INVALID_ANSWER',
            ),
          ),
        );

        expect(resumeService.callCount, 0);
      },
    );

    test(
      'handles duplicate responses gracefully with already_resolved and cross_session_mismatch',
      () async {
        final now = DateTime.now().toUtc();
        seedSession('session-dup');
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'chk-5',
            sessionId: 'session-dup',
            requestId: 'perm-req-5',
            toolCallId: 'tc-5',
            toolName: 'run_terminal_command',
            status: 'awaiting_permission',
            toolArguments: {'command': 'pwd'},
            permissionPayload: {
              'request_id': 'perm-req-5',
              'tool_name': 'run_terminal_command',
              'session_id': 'session-dup',
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        // First resolution succeeds
        final firstRes = await client.respondToolPermission(
          sessionId: 'session-dup',
          requestId: 'perm-req-5',
          allowed: true,
        );
        expect((firstRes['payload'] as Map)['outcome'], 'resolved');
        expect(resumeService.callCount, 1);

        // Second resolution on same session returns ALREADY_RESOLVED
        expect(
          () => client.respondToolPermission(
            sessionId: 'session-dup',
            requestId: 'perm-req-5',
            allowed: false,
          ),
          throwsA(
            isA<CliClientException>().having(
              (e) => e.code,
              'code',
              'ALREADY_RESOLVED',
            ),
          ),
        );

        // Duplicate resolution across mismatched session returns CROSS_SESSION_MISMATCH
        expect(
          () => client.respondToolPermission(
            sessionId: 'other-session',
            requestId: 'perm-req-5',
            allowed: false,
          ),
          throwsA(
            isA<CliClientException>().having(
              (e) => e.code,
              'code',
              'CROSS_SESSION_MISMATCH',
            ),
          ),
        );

        // Still exactly 1 resume call was made
        expect(resumeService.callCount, 1);
      },
    );

    test(
      'scoped stop dispatches stop event for specific session across real gateway',
      () async {
        final receivedEvents = <GatewayEvent>[];
        final stopSubscription = platform.eventStream.listen((event) {
          receivedEvents.add(event);
        });
        addTearDown(() => stopSubscription.cancel());

        seedSession('session-to-stop');
        seedSession('session-to-keep');

        await client.stop(sessionId: 'session-to-stop');

        // Pump event loop to deliver WebSocket message to platform stream
        await pumpEventQueue();

        final stopEvents = receivedEvents
            .where((e) => e.type == 'stop')
            .toList();
        expect(stopEvents, isNotEmpty);
        expect(stopEvents.first.sessionId, 'session-to-stop');
        expect(
          receivedEvents.any(
            (e) => e.type == 'stop' && e.sessionId == 'session-to-keep',
          ),
          isFalse,
        );
      },
    );
  });
}
