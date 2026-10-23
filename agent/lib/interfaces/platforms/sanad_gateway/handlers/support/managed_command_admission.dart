import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';

import 'agent_event_envelope.dart';

/// Single owner of the managed and cloud admission decisions that the gateway
/// command families share.
///
/// Every clause below (`managed_remote`, `cloud_admitted`, the envelope device
/// identity, the recorded-request exemptions, and the confirmation ticket
/// lifecycle) is decided here exactly once, so a handler can never duplicate or
/// quietly drift from it.
class ManagedCommandAdmission {
  ManagedCommandAdmission(this._admission);

  final DeviceCommandAdmission? _admission;

  /// Whether the daemon can admit managed and cloud commands at all.
  bool get isAvailable => _admission != null;

  bool isManagedRemote(CanonicalEvent event) =>
      event.payload['managed_remote'] == true;

  bool isCloudAdmitted(CanonicalEvent event) =>
      event.payload['cloud_admitted'] == true;

  String? envelopeDeviceId(CanonicalEvent event) {
    final value = event.payload['device_id']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  Map<String, dynamic>? rejectManagedRemote(
    CanonicalEvent event,
    String? requestId,
  ) {
    if (!isManagedRemote(event)) {
      return null;
    }
    if (_admission == null) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'admit workspace command',
        error: const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.invalidRequest,
          'Managed remote workspace admission is unavailable.',
        ),
      );
    }
    final decision = _admission.admitCorrelation(
      envelopeDeviceId: envelopeDeviceId(event),
      requestId: requestId,
      recordRequest:
          event.type != CanonicalEventTypes.deleteFolder &&
          event.type != CanonicalEventTypes.relocateWorkspace,
    );
    if (decision.allowed) return null;
    return buildCommandMutationErrorEnvelope(
      requestId: requestId,
      action: 'admit workspace command',
      error: WorkspaceCommandException(decision.code!, decision.message!),
    );
  }

  DeviceControlAdmissionDecision admitCorrelation({
    required String? envelopeDeviceId,
    required String? requestId,
    bool recordRequest = true,
  }) => _admission!.admitCorrelation(
    envelopeDeviceId: envelopeDeviceId,
    requestId: requestId,
    recordRequest: recordRequest,
  );

  ConfirmationTicket issueConfirmation({
    required String deviceId,
    required String operation,
    required String fingerprint,
  }) => _admission!.issueConfirmation(
    deviceId: deviceId,
    operation: operation,
    fingerprint: fingerprint,
  );

  DeviceControlAdmissionDecision consumeConfirmation({
    required String token,
    required String operation,
    String? fingerprint,
  }) => _admission!.consumeConfirmation(
    token: token,
    operation: operation,
    fingerprint: fingerprint,
  );
}

/// Reads a required, non-blank string from a command payload.
String requiredCommandString(CanonicalEvent event, String key) {
  final value = event.payload[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key is required.');
  }
  return value.trim();
}
