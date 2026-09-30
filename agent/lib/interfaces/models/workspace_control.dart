import 'package:sanad_agent/interfaces/models/device_control.dart';

/// Typed remote workspace-management protocol models. Command names are
/// canonical protocol identifiers, never UI labels.
class WorkspaceCommandErrorCodes {
  static const wrongDevice = DeviceControlErrorCodes.wrongDevice;
  static const duplicateRequest = DeviceControlErrorCodes.duplicateRequest;
  static const staleConfirmation = DeviceControlErrorCodes.staleConfirmation;
  static const confirmationRequired =
      DeviceControlErrorCodes.confirmationRequired;
  static const invalidRequest = DeviceControlErrorCodes.invalidRequest;
  static const pathNotAllowed = 'path_not_allowed';
}

class WorkspaceCommandException implements Exception {
  const WorkspaceCommandException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class WorkspaceMutationPreview {
  const WorkspaceMutationPreview({
    required this.operation,
    required this.path,
    required this.fingerprint,
    required this.summary,
    required this.entryCount,
    required this.truncated,
  });

  final String operation;
  final String path;
  final String fingerprint;
  final String summary;
  final int entryCount;
  final bool truncated;

  Map<String, dynamic> toPayload({
    required String? requestId,
    required String confirmationToken,
    required DateTime expiresAt,
  }) {
    return {
      'request_id': requestId,
      'confirmation_token': confirmationToken,
      'confirmation_fingerprint': fingerprint,
      'expires_at': expiresAt.toUtc().toIso8601String(),
      'operation': operation,
      'path': path,
      'summary': {
        'message': summary,
        'entry_count': entryCount,
        'truncated': truncated,
      },
    };
  }
}
