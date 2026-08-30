import 'dart:math';
import 'dart:typed_data';

/// Typed remote device-control protocol models. Command names are canonical
/// protocol identifiers, never UI labels.
class DeviceControlCommands {
  static const updateCheck = 'device.update.check';
  static const updateCheckResult = 'device.update.check.result';
  static const updateApply = 'device.update.apply';
  static const updateApplyAccepted = 'device.update.apply.accepted';
  static const updateProgress = 'device.update.progress';
  static const updateResult = 'device.update.result';
  static const runtimeRestart = 'device.runtime.restart';
  static const runtimeRestartAccepted = 'device.runtime.restart.accepted';

  static const Set<String> all = {updateCheck, updateApply, runtimeRestart};
}

class DeviceControlErrorCodes {
  static const wrongDevice = 'wrong_device';
  static const unsupported = 'unsupported';
  static const duplicateRequest = 'duplicate_request';
  static const staleConfirmation = 'stale_confirmation';
  static const invalidRequest = 'invalid_request';
  static const confirmationRequired = 'confirmation_required';
  static const deviceOffline = 'device_offline';
  static const serviceUnavailable = 'service_unavailable';
}

class DeviceControlAdmissionDecision {
  const DeviceControlAdmissionDecision.allow()
    : allowed = true,
      code = null,
      message = null;

  const DeviceControlAdmissionDecision.reject({
    required this.code,
    required this.message,
  }) : allowed = false;

  final bool allowed;
  final String? code;
  final String? message;
}

class ConfirmationTicket {
  const ConfirmationTicket({
    required this.token,
    required this.deviceId,
    required this.operation,
    required this.fingerprint,
    required this.expiresAt,
  });

  final String token;
  final String deviceId;
  final String operation;
  final String fingerprint;
  final DateTime expiresAt;
}

class DeviceUpdateCheckRequest {
  const DeviceUpdateCheckRequest({
    required this.requestId,
    required this.deviceId,
  });

  final String requestId;
  final String deviceId;

  factory DeviceUpdateCheckRequest.parse({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) {
    final requestId = payload['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) {
      throw const FormatException('request_id is required.');
    }
    return DeviceUpdateCheckRequest(requestId: requestId, deviceId: deviceId);
  }
}

class DeviceUpdateApplyRequest {
  const DeviceUpdateApplyRequest({
    required this.requestId,
    required this.deviceId,
    required this.targetVersion,
    required this.manifestRevision,
    required this.manifestFingerprint,
    required this.confirmationToken,
  });

  final String requestId;
  final String deviceId;
  final String targetVersion;
  final String manifestRevision;
  final String manifestFingerprint;
  final String confirmationToken;

  factory DeviceUpdateApplyRequest.parse({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) {
    final requestId = payload['request_id']?.toString().trim() ?? '';
    final targetVersion = payload['target_version']?.toString().trim() ?? '';
    final manifestRevision =
        payload['manifest_revision']?.toString().trim() ?? '';
    final manifestFingerprint =
        payload['manifest_fingerprint']?.toString().trim() ?? '';
    final confirmationToken =
        payload['confirmation_token']?.toString().trim() ?? '';
    if (requestId.isEmpty ||
        targetVersion.isEmpty ||
        manifestRevision.isEmpty ||
        manifestFingerprint.isEmpty) {
      throw const FormatException(
        'target_version, manifest_revision, manifest_fingerprint, and request_id are required.',
      );
    }
    if (payload['url'] != null || payload['checksum'] != null) {
      throw const FormatException(
        'Client-supplied artifact URLs and checksums are not accepted.',
      );
    }
    return DeviceUpdateApplyRequest(
      requestId: requestId,
      deviceId: deviceId,
      targetVersion: targetVersion,
      manifestRevision: manifestRevision,
      manifestFingerprint: manifestFingerprint,
      confirmationToken: confirmationToken,
    );
  }
}

class DeviceRuntimeRestartRequest {
  const DeviceRuntimeRestartRequest({
    required this.requestId,
    required this.deviceId,
    required this.force,
    this.timeoutSeconds,
  });

  final String requestId;
  final String deviceId;
  final bool force;
  final int? timeoutSeconds;

  factory DeviceRuntimeRestartRequest.parse({
    required String deviceId,
    required Map<String, dynamic> payload,
  }) {
    final requestId = payload['request_id']?.toString().trim() ?? '';
    if (requestId.isEmpty) {
      throw const FormatException('request_id is required.');
    }
    final rawForce = payload['force'];
    if (rawForce != null && rawForce is! bool) {
      throw const FormatException('force must be a boolean.');
    }
    final rawTimeout = payload['timeout_seconds'];
    int? timeoutSeconds;
    if (rawTimeout != null) {
      timeoutSeconds = rawTimeout is int
          ? rawTimeout
          : int.tryParse(rawTimeout.toString());
      if (timeoutSeconds == null || timeoutSeconds <= 0) {
        throw const FormatException(
          'Restart timeout must be a positive bounded value.',
        );
      }
    }
    return DeviceRuntimeRestartRequest(
      requestId: requestId,
      deviceId: deviceId,
      force: rawForce == true,
      timeoutSeconds: timeoutSeconds,
    );
  }
}

class DeviceControlError {
  const DeviceControlError({
    required this.code,
    required this.message,
    required this.requestId,
    required this.deviceId,
  });

  final String code;
  final String message;
  final String? requestId;
  final String deviceId;

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'code': code,
    'message': message,
    'device_id': deviceId,
  };
}

class DeviceUpdateCheckResult {
  const DeviceUpdateCheckResult({
    required this.requestId,
    required this.deviceId,
    required this.status,
    required this.currentVersion,
    this.availableVersion,
    this.message,
    this.confirmationToken,
    this.manifestRevision,
    this.manifestFingerprint,
  });

  final String requestId;
  final String deviceId;
  final String status;
  final String currentVersion;
  final String? availableVersion;
  final String? message;
  final String? confirmationToken;
  final String? manifestRevision;
  final String? manifestFingerprint;

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'device_id': deviceId,
    'status': status,
    'current_version': currentVersion,
    if (availableVersion != null) 'available_version': availableVersion,
    if (message != null) 'message': message,
    if (confirmationToken != null) 'confirmation_token': confirmationToken,
    if (manifestRevision != null) 'manifest_revision': manifestRevision,
    if (manifestFingerprint != null)
      'manifest_fingerprint': manifestFingerprint,
  };
}

class DeviceUpdateApplyResult {
  const DeviceUpdateApplyResult({
    required this.requestId,
    required this.deviceId,
    required this.status,
    required this.currentVersion,
    this.availableVersion,
    this.message,
  });

  final String requestId;
  final String deviceId;
  final String status;
  final String currentVersion;
  final String? availableVersion;
  final String? message;

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'device_id': deviceId,
    'status': status,
    'current_version': currentVersion,
    if (availableVersion != null) 'available_version': availableVersion,
    if (message != null) 'message': message,
  };
}

class DeviceRuntimeRestartAccepted {
  const DeviceRuntimeRestartAccepted({
    required this.requestId,
    required this.deviceId,
    this.timeoutSeconds,
    this.message = 'Restart accepted. The agent will drain work and reconnect.',
  });

  final String requestId;
  final String deviceId;
  final int? timeoutSeconds;
  final String message;

  Map<String, dynamic> toPayload() => {
    'request_id': requestId,
    'device_id': deviceId,
    'status': 'accepted',
    if (timeoutSeconds != null) 'timeout_seconds': timeoutSeconds,
    'message': message,
  };
}

final _tokenRandom = Random.secure();

String mintConfirmationToken() {
  final bytes = Uint8List(16);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = _tokenRandom.nextInt(256);
  }
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
