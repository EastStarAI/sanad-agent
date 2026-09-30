import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/device_control_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

import '../../../../support/memory_agent_secret_store.dart';

void main() {
  final getIt = GetIt.instance;

  late DeviceCommandAdmission admission;
  late List<int> exits;
  late _ScriptedUpdateService updater;
  late DeviceControlCommandHandler handler;

  setUp(() {
    getIt.registerSingleton<AuthManager>(_HardwareAuthManager());
    admission = DeviceCommandAdmission(registeredDeviceId: () => 'device-a');
    exits = <int>[];
    updater = _ScriptedUpdateService(
      checkResult: const AgentUpdateResult(
        status: AgentUpdateStatus.updateAvailable,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        manifestTag: 'v1.1.0',
        manifestCommit: 'abc123',
      ),
      applyResult: const AgentUpdateResult(
        status: AgentUpdateStatus.restartRequired,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        message: 'Verified update installed. Restart the Sanad service.',
      ),
    );
    handler = DeviceControlCommandHandler(
      admission: admission,
      bridge: SanadProtocolBridge(),
      restartCoordinator: DaemonRestartCoordinator(exitDaemon: exits.add),
      updateService: () => updater,
      isSupervised: () => true,
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  test(
    'check is read-only and mints a confirmation for an available update',
    () async {
      final first = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.updateCheck,
          payload: const {'request_id': 'req-check'},
        ),
        deviceId: 'device-a',
      );
      expect(first['event'], DeviceControlCommands.updateCheckResult);
      final payload = Map<String, dynamic>.from(first['payload'] as Map);
      expect(payload['status'], 'update_available');
      expect(payload['current_version'], '1.0.0');
      expect(payload['available_version'], '1.1.0');
      expect(payload['confirmation_token'], isNotEmpty);
      expect(payload['manifest_revision'], 'v1.1.0');
      expect(payload['manifest_fingerprint'], 'abc123');
      expect(updater.checkCalls, 1);
      expect(updater.applyCalls, 0);
      expect(exits, isEmpty);
    },
  );

  test('source-managed check does not mint a confirmation ticket', () async {
    updater.checkResult = const AgentUpdateResult(
      status: AgentUpdateStatus.sourceManaged,
      currentVersion: '1.0.0',
    );
    final envelope = await handler.buildEnvelope(
      CanonicalEvent(
        type: DeviceControlCommands.updateCheck,
        payload: const {'request_id': 'req-source'},
      ),
      deviceId: 'device-a',
    );
    final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
    expect(payload['status'], 'source_managed');
    expect(payload.containsKey('confirmation_token'), isFalse);
  });

  test(
    'apply consumes the check ticket and does not accept client URLs',
    () async {
      final check = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.updateCheck,
          payload: const {'request_id': 'req-check'},
        ),
        deviceId: 'device-a',
      );
      final checkPayload = Map<String, dynamic>.from(check['payload'] as Map);

      expect(
        () => DeviceUpdateApplyRequest.parse(
          deviceId: 'device-a',
          payload: {
            'request_id': 'req-url',
            'target_version': '1.1.0',
            'manifest_revision': 'v1.1.0',
            'manifest_fingerprint': 'abc123',
            'confirmation_token': checkPayload['confirmation_token'],
            'url': 'https://evil.example/agent',
          },
        ),
        throwsFormatException,
      );

      final applied = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.updateApply,
          payload: {
            'request_id': 'req-apply',
            'target_version': '1.1.0',
            'manifest_revision': 'v1.1.0',
            'manifest_fingerprint': 'abc123',
            'confirmation_token': checkPayload['confirmation_token'],
          },
        ),
        deviceId: 'device-a',
      );
      expect(applied['event'], DeviceControlCommands.updateApplyAccepted);
      expect(updater.applyCalls, 1);

      final reused = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.updateApply,
          payload: {
            'request_id': 'req-apply-2',
            'target_version': '1.1.0',
            'manifest_revision': 'v1.1.0',
            'manifest_fingerprint': 'abc123',
            'confirmation_token': checkPayload['confirmation_token'],
          },
        ),
        deviceId: 'device-a',
      );
      expect(reused['event'], 'error');
      expect(
        (reused['payload'] as Map)['code'],
        DeviceControlErrorCodes.staleConfirmation,
      );
    },
  );

  test(
    'source-managed apply reports the typed result without restarting',
    () async {
      updater.applyResult = const AgentUpdateResult(
        status: AgentUpdateStatus.sourceManaged,
        currentVersion: '1.0.0',
      );
      final ticket = admission.issueConfirmation(
        deviceId: 'device-a',
        operation: DeviceControlCommands.updateApply,
        fingerprint: 'abc123',
      );
      final envelope = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.updateApply,
          payload: {
            'request_id': 'req-source-apply',
            'target_version': '1.1.0',
            'manifest_revision': 'v1.1.0',
            'manifest_fingerprint': 'abc123',
            'confirmation_token': ticket.token,
          },
        ),
        deviceId: 'device-a',
      );
      expect(envelope['event'], DeviceControlCommands.updateResult);
      expect((envelope['payload'] as Map)['status'], 'source_managed');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(exits, isEmpty);
    },
  );

  test(
    'restart returns accepted before drain and rejects unsupervised hosts',
    () async {
      final accepted = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.runtimeRestart,
          payload: const {'request_id': 'req-restart'},
        ),
        deviceId: 'device-a',
      );
      expect(accepted['event'], DeviceControlCommands.runtimeRestartAccepted);
      expect((accepted['payload'] as Map)['status'], 'accepted');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(exits, [0]);

      final unsupervised = DeviceControlCommandHandler(
        admission: DeviceCommandAdmission(registeredDeviceId: () => 'device-a'),
        bridge: SanadProtocolBridge(),
        restartCoordinator: DaemonRestartCoordinator(exitDaemon: exits.add),
        updateService: () => updater,
        isSupervised: () => false,
      );
      final rejected = await unsupervised.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.runtimeRestart,
          payload: const {'request_id': 'req-unsupervised'},
        ),
        deviceId: 'device-a',
      );
      expect(rejected['event'], 'error');
      expect(
        (rejected['payload'] as Map)['code'],
        DeviceControlErrorCodes.serviceUnavailable,
      );
    },
  );

  test('restart handler forwards the explicit force choice', () async {
    final coordinator = _RecordingRestartCoordinator();
    final forceHandler = DeviceControlCommandHandler(
      admission: DeviceCommandAdmission(registeredDeviceId: () => 'device-a'),
      bridge: SanadProtocolBridge(),
      restartCoordinator: coordinator,
      updateService: () => updater,
      isSupervised: () => true,
    );

    final accepted = await forceHandler.buildEnvelope(
      CanonicalEvent(
        type: DeviceControlCommands.runtimeRestart,
        payload: const {'request_id': 'req-force', 'force': true},
      ),
      deviceId: 'device-a',
    );

    expect(accepted['event'], DeviceControlCommands.runtimeRestartAccepted);
    expect(coordinator.requestedForce, isTrue);
    expect(coordinator.completedForce, isTrue);
  });

  test(
    'lost acknowledgements do not admit the same restart request_id',
    () async {
      final first = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.runtimeRestart,
          payload: const {'request_id': 'req-once'},
        ),
        deviceId: 'device-a',
      );
      expect(first['event'], DeviceControlCommands.runtimeRestartAccepted);
      final duplicate = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.runtimeRestart,
          payload: const {'request_id': 'req-once'},
        ),
        deviceId: 'device-a',
      );
      expect(
        (duplicate['payload'] as Map)['code'],
        DeviceControlErrorCodes.duplicateRequest,
      );
    },
  );

  test(
    'apply rollback fail-injection does not exit and reports a typed error',
    () async {
      updater.applyResult = const AgentUpdateResult(
        status: AgentUpdateStatus.rollbackCompleted,
        currentVersion: '1.0.0',
        availableVersion: '1.1.0',
        message: 'Replacement failed; the previous executable was restored.',
      );
      final ticket = admission.issueConfirmation(
        deviceId: 'device-a',
        operation: DeviceControlCommands.updateApply,
        fingerprint: 'abc123',
      );
      final envelope = await handler.buildEnvelope(
        CanonicalEvent(
          type: DeviceControlCommands.updateApply,
          payload: {
            'request_id': 'req-rollback',
            'target_version': '1.1.0',
            'manifest_revision': 'v1.1.0',
            'manifest_fingerprint': 'abc123',
            'confirmation_token': ticket.token,
          },
        ),
        deviceId: 'device-a',
      );
      expect(envelope['event'], 'error');
      expect(
        (envelope['payload'] as Map)['code'],
        DeviceControlErrorCodes.unsupported,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(exits, isEmpty);
      expect(updater.applyCalls, 1);
    },
  );

  test('checksum fail-injection does not restart', () async {
    updater.applyResult = const AgentUpdateResult(
      status: AgentUpdateStatus.checksumFailed,
      currentVersion: '1.0.0',
      availableVersion: '1.1.0',
      message: 'Downloaded artifact failed size or SHA-256 verification.',
    );
    final ticket = admission.issueConfirmation(
      deviceId: 'device-a',
      operation: DeviceControlCommands.updateApply,
      fingerprint: 'abc123',
    );
    final envelope = await handler.buildEnvelope(
      CanonicalEvent(
        type: DeviceControlCommands.updateApply,
        payload: {
          'request_id': 'req-checksum',
          'target_version': '1.1.0',
          'manifest_revision': 'v1.1.0',
          'manifest_fingerprint': 'abc123',
          'confirmation_token': ticket.token,
        },
      ),
      deviceId: 'device-a',
    );
    expect(envelope['event'], 'error');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(exits, isEmpty);
  });

  test(
    'isDaemonRestartSupervised follows launcher, service, and packaged runtimes',
    () {
      expect(
        isDaemonRestartSupervised(
          environment: const {'SANAD_DEV_LAUNCHER_ID': 'wt-1'},
          isSourceRun: true,
        ),
        isTrue,
      );
      expect(
        isDaemonRestartSupervised(
          environment: const {'SANAD_SERVICE_INSTANCE': ''},
          isSourceRun: true,
        ),
        isTrue,
      );
      expect(
        isDaemonRestartSupervised(environment: const {}, isSourceRun: false),
        isTrue,
      );
      expect(
        isDaemonRestartSupervised(environment: const {}, isSourceRun: true),
        isFalse,
      );
    },
  );
}

class _HardwareAuthManager extends AuthManager {
  _HardwareAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String get hardwareId => 'device-a';
}

class _RecordingRestartCoordinator extends DaemonRestartCoordinator {
  _RecordingRestartCoordinator() : super(exitDaemon: (_) {});

  bool? requestedForce;
  bool? completedForce;

  @override
  Future<DaemonRestartPreparation> prepareRestart({
    bool force = false,
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    String? requesterSessionId,
    String? requesterToolCallId,
  }) async {
    requestedForce = force;
    return DaemonRestartPreparation(
      accepted: true,
      force: force,
      timeout: timeout,
      outcome: force ? 'forced' : 'safe',
    );
  }

  @override
  Future<void> completePreparedRestart(
    DaemonRestartPreparation preparation, {
    Duration acknowledgementDelay = Duration.zero,
  }) async {
    completedForce = preparation.force;
  }
}

class _ScriptedUpdateService extends AgentUpdateService {
  _ScriptedUpdateService({required this.checkResult, required this.applyResult})
    : super(
        currentVersion: '1.0.0',
        executablePath: '/tmp/sanad-agent',
        isSourceManaged: false,
        client: http.Client(),
      );

  AgentUpdateResult checkResult;
  AgentUpdateResult applyResult;
  int checkCalls = 0;
  int applyCalls = 0;

  @override
  Future<AgentUpdateResult> check({String? targetVersion}) async {
    checkCalls += 1;
    return checkResult;
  }

  @override
  Future<AgentUpdateResult> update({
    String? targetVersion,
    String? expectedManifestTag,
    String? expectedManifestCommit,
  }) async {
    applyCalls += 1;
    return applyResult;
  }
}
