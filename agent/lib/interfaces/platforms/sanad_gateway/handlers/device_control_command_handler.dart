import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/core/app_config.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';

import '../sanad_protocol_bridge.dart';

/// Owns remote update and restart after [DeviceCommandAdmission].
///
/// Every Online device may send these commands. Capability flags are not
/// consulted. MCP mutations remain outside this handler until G4.
class DeviceControlCommandHandler {
  DeviceControlCommandHandler({
    required DeviceCommandAdmission admission,
    required SanadProtocolBridge bridge,
    required DaemonRestartCoordinator restartCoordinator,
    required AgentUpdateService Function() updateService,
    bool Function()? isSupervised,
  }) : _admission = admission,
       _bridge = bridge,
       _restartCoordinator = restartCoordinator,
       _updateService = updateService,
       _isSupervised = isSupervised ?? isDaemonRestartSupervised;

  final DeviceCommandAdmission _admission;
  final SanadProtocolBridge _bridge;
  final DaemonRestartCoordinator _restartCoordinator;
  final AgentUpdateService Function() _updateService;
  final bool Function() _isSupervised;

  Future<Map<String, dynamic>> buildEnvelope(
    CanonicalEvent event, {
    String? deviceId,
  }) async {
    final requestId = event.payload['request_id']?.toString();
    final decision = _admission.admit(
      command: event.type,
      envelopeDeviceId: deviceId,
      requestId: requestId,
      confirmationToken: event.payload['confirmation_token']?.toString(),
      confirmationFingerprint:
          event.payload['confirmation_fingerprint']?.toString() ??
          event.payload['manifest_fingerprint']?.toString(),
      payload: event.payload,
    );
    if (!decision.allowed) {
      return _errorEnvelope(
        event: event,
        code: decision.code!,
        message: decision.message!,
        requestId: requestId,
        deviceId: deviceId,
      );
    }

    try {
      switch (event.type) {
        case DeviceControlCommands.updateCheck:
          return await _handleCheck(event, deviceId: deviceId);
        case DeviceControlCommands.updateApply:
          return await _handleApply(event, deviceId: deviceId);
        case DeviceControlCommands.runtimeRestart:
          return await _handleRestart(event, deviceId: deviceId);
        default:
          return _errorEnvelope(
            event: event,
            code: DeviceControlErrorCodes.unsupported,
            message: 'Unknown device-control command.',
            requestId: requestId,
            deviceId: deviceId,
          );
      }
    } on FormatException catch (error) {
      return _errorEnvelope(
        event: event,
        code: DeviceControlErrorCodes.invalidRequest,
        message: error.message,
        requestId: requestId,
        deviceId: deviceId,
      );
    }
  }

  Future<Map<String, dynamic>> _handleCheck(
    CanonicalEvent event, {
    required String? deviceId,
  }) async {
    final request = DeviceUpdateCheckRequest.parse(
      deviceId: deviceId ?? '',
      payload: event.payload,
    );
    final result = await _updateService().check();
    String? confirmationToken;
    final fingerprint =
        result.manifestCommit ??
        result.availableVersion ??
        result.status.wireName;
    if (result.status == AgentUpdateStatus.updateAvailable) {
      final ticket = _admission.issueConfirmation(
        deviceId: deviceId?.trim().isNotEmpty == true
            ? deviceId!.trim()
            : request.deviceId,
        operation: DeviceControlCommands.updateApply,
        fingerprint: fingerprint,
      );
      confirmationToken = ticket.token;
    }
    return _resultEnvelope(
      event: event,
      type: DeviceControlCommands.updateCheckResult,
      payload: DeviceUpdateCheckResult(
        requestId: request.requestId,
        deviceId: request.deviceId,
        status: result.status.wireName,
        currentVersion: result.currentVersion,
        availableVersion: result.availableVersion,
        message: result.message,
        confirmationToken: confirmationToken,
        manifestRevision: result.manifestTag ?? result.availableVersion,
        manifestFingerprint: result.status == AgentUpdateStatus.updateAvailable
            ? fingerprint
            : result.manifestCommit,
      ).toPayload(),
    );
  }

  Future<Map<String, dynamic>> _handleApply(
    CanonicalEvent event, {
    required String? deviceId,
  }) async {
    final request = DeviceUpdateApplyRequest.parse(
      deviceId: deviceId ?? '',
      payload: event.payload,
    );
    final updater = _updateService();
    var result = await updater.update(
      targetVersion: request.targetVersion,
      expectedManifestTag: request.manifestRevision,
      expectedManifestCommit: request.manifestFingerprint,
    );
    if (Platform.isWindows && result.stagedPath != null) {
      final scheduled = await updater.scheduleWindowsReplacement(result);
      if (!scheduled) {
        result = result.copyWith(
          status: AgentUpdateStatus.scheduleFailed,
          message:
              'Verified replacement could not be scheduled; the running agent was kept.',
        );
      }
    }

    if (result.status == AgentUpdateStatus.sourceManaged) {
      return _resultEnvelope(
        event: event,
        type: DeviceControlCommands.updateResult,
        payload: DeviceUpdateApplyResult(
          requestId: request.requestId,
          deviceId: request.deviceId,
          status: result.status.wireName,
          currentVersion: result.currentVersion,
          availableVersion: result.availableVersion,
          message: result.message,
        ).toPayload(),
      );
    }

    if (!result.isSuccess) {
      return _errorEnvelope(
        event: event,
        code: result.status == AgentUpdateStatus.downgradeRejected
            ? DeviceControlErrorCodes.invalidRequest
            : DeviceControlErrorCodes.unsupported,
        message: result.message ?? 'The update could not be applied.',
        requestId: request.requestId,
        deviceId: request.deviceId,
      );
    }

    if (result.status == AgentUpdateStatus.restartRequired) {
      unawaited(
        Platform.isWindows
            ? _restartCoordinator.stop()
            : _restartCoordinator.restart(),
      );
      return _resultEnvelope(
        event: event,
        type: DeviceControlCommands.updateApplyAccepted,
        payload: DeviceUpdateApplyResult(
          requestId: request.requestId,
          deviceId: request.deviceId,
          status: result.status.wireName,
          currentVersion: result.currentVersion,
          availableVersion: result.availableVersion,
          message: result.message,
        ).toPayload(),
      );
    }

    return _resultEnvelope(
      event: event,
      type: DeviceControlCommands.updateResult,
      payload: DeviceUpdateApplyResult(
        requestId: request.requestId,
        deviceId: request.deviceId,
        status: result.status.wireName,
        currentVersion: result.currentVersion,
        availableVersion: result.availableVersion,
        message: result.message,
      ).toPayload(),
    );
  }

  Future<Map<String, dynamic>> _handleRestart(
    CanonicalEvent event, {
    required String? deviceId,
  }) async {
    final request = DeviceRuntimeRestartRequest.parse(
      deviceId: deviceId ?? '',
      payload: event.payload,
    );
    if (!_isSupervised()) {
      return _errorEnvelope(
        event: event,
        code: DeviceControlErrorCodes.serviceUnavailable,
        message:
            'This agent is not supervised and cannot restart itself remotely.',
        requestId: request.requestId,
        deviceId: request.deviceId,
      );
    }

    final timeout = Duration(
      seconds:
          request.timeoutSeconds ??
          SessionRunOrchestrator.controlledRestartCheckpointTimeout.inSeconds,
    );
    final preparation = await _restartCoordinator.prepareRestart(
      force: request.force,
      timeout: timeout,
    );
    if (!preparation.accepted) {
      return _errorEnvelope(
        event: event,
        code: preparation.outcome == 'already_in_progress'
            ? DeviceControlErrorCodes.duplicateRequest
            : DeviceControlErrorCodes.serviceUnavailable,
        message:
            preparation.toJson()['message']?.toString() ??
            'Restart was not accepted.',
        requestId: request.requestId,
        deviceId: request.deviceId,
      );
    }

    unawaited(
      _restartCoordinator.completePreparedRestart(
        preparation,
        acknowledgementDelay: const Duration(milliseconds: 500),
      ),
    );
    return _resultEnvelope(
      event: event,
      type: DeviceControlCommands.runtimeRestartAccepted,
      payload: DeviceRuntimeRestartAccepted(
        requestId: request.requestId,
        deviceId: request.deviceId,
        timeoutSeconds: timeout.inSeconds,
      ).toPayload(),
    );
  }

  Map<String, dynamic> _errorEnvelope({
    required CanonicalEvent event,
    required String code,
    required String message,
    required String? requestId,
    required String? deviceId,
  }) {
    final error = _admission.errorEnvelope(
      code: code,
      message: message,
      requestId: requestId,
      envelopeDeviceId: deviceId,
    );
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: 'error',
        sessionId: event.sessionId,
        payload: error.toPayload(),
      ),
    );
  }

  Map<String, dynamic> _resultEnvelope({
    required CanonicalEvent event,
    required String type,
    required Map<String, dynamic> payload,
  }) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(type: type, sessionId: event.sessionId, payload: payload),
    );
  }
}

bool isDaemonRestartSupervised({
  Map<String, String>? environment,
  bool? isSourceRun,
}) {
  final env = environment ?? Platform.environment;
  if (env['SANAD_DEV_LAUNCHER_ID']?.trim().isNotEmpty == true) return true;
  if (env.containsKey('SANAD_SERVICE_INSTANCE')) return true;
  if (env['SANAD_DEV_RUNTIME_NONCE']?.trim().isNotEmpty == true) return true;
  return !(isSourceRun ?? AppConfig.isSourceRun);
}
