import 'package:sanad_agent/interfaces/models/device_control.dart';

/// Daemon-owned admission for remote device-control commands.
///
/// Every Online device supports these commands. This owner correlates the
/// registered device, request id, and confirmation tickets. It does not parse
/// UI labels, inspect capability flags, or mutate state.
class DeviceCommandAdmission {
  DeviceCommandAdmission({
    required String Function() registeredDeviceId,
    Iterable<String> Function()? additionalDeviceIds,
    DateTime Function()? clock,
    this.duplicateTtl = const Duration(minutes: 10),
    this.confirmationTtl = const Duration(minutes: 2),
  }) : _registeredDeviceId = registeredDeviceId,
       _additionalDeviceIds = additionalDeviceIds ?? (() => const []),
       _clock = clock ?? DateTime.now;

  final String Function() _registeredDeviceId;
  final Iterable<String> Function() _additionalDeviceIds;
  final DateTime Function() _clock;
  final Duration duplicateTtl;
  final Duration confirmationTtl;

  final Map<String, DateTime> _seenRequestIds = {};
  final Map<String, ConfirmationTicket> _tickets = {};

  static const confirmationCommands = {DeviceControlCommands.updateApply};

  DeviceControlAdmissionDecision admitCorrelation({
    required String? envelopeDeviceId,
    required String? requestId,
    bool recordRequest = true,
  }) {
    final acceptedDeviceIds = _acceptedDeviceIds();
    final requested = envelopeDeviceId?.trim() ?? '';
    if (acceptedDeviceIds.isNotEmpty && requested.isEmpty) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.invalidRequest,
        message: 'device_id is required.',
      );
    }
    if (acceptedDeviceIds.isNotEmpty &&
        requested.isNotEmpty &&
        !acceptedDeviceIds.contains(requested)) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.wrongDevice,
        message: 'The command targeted a different device.',
      );
    }

    if (requestId == null || requestId.trim().isEmpty) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.invalidRequest,
        message: 'request_id is required.',
      );
    }

    _purgeExpired();
    final duplicateKey = requestId.trim();
    if (_seenRequestIds.containsKey(duplicateKey)) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.duplicateRequest,
        message: 'This request_id was already admitted.',
      );
    }
    if (recordRequest) {
      _seenRequestIds[duplicateKey] = _clock();
    }
    return const DeviceControlAdmissionDecision.allow();
  }

  DeviceControlAdmissionDecision consumeConfirmation({
    required String token,
    required String operation,
    String? fingerprint,
  }) {
    _purgeExpired();
    final acceptedDeviceIds = _acceptedDeviceIds();
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.confirmationRequired,
        message: 'An explicit confirmation ticket is required.',
      );
    }
    final ticket = _tickets.remove(trimmed);
    final now = _clock();
    if (ticket == null ||
        ticket.expiresAt.isBefore(now) ||
        !acceptedDeviceIds.contains(ticket.deviceId) ||
        ticket.operation != operation ||
        (fingerprint != null && fingerprint != ticket.fingerprint)) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.staleConfirmation,
        message: 'The confirmation ticket is stale or does not match.',
      );
    }
    return const DeviceControlAdmissionDecision.allow();
  }

  DeviceControlAdmissionDecision admit({
    required String command,
    required String? envelopeDeviceId,
    required String? requestId,
    String? confirmationToken,
    String? confirmationFingerprint,
    Map<String, dynamic>? payload,
  }) {
    final correlation = admitCorrelation(
      envelopeDeviceId: envelopeDeviceId,
      requestId: requestId,
      recordRequest: false,
    );
    if (!correlation.allowed) return correlation;

    if (!DeviceControlCommands.all.contains(command)) {
      return const DeviceControlAdmissionDecision.reject(
        code: DeviceControlErrorCodes.unsupported,
        message: 'Unknown device-control command.',
      );
    }

    if (command == DeviceControlCommands.runtimeRestart) {
      final force = payload?['force'];
      if (force != null && force is! bool) {
        return const DeviceControlAdmissionDecision.reject(
          code: DeviceControlErrorCodes.invalidRequest,
          message: 'force must be a boolean.',
        );
      }
      final timeout = _readTimeoutSeconds(payload?['timeout_seconds']);
      if (timeout != null && (timeout <= 0 || timeout > 3600)) {
        return const DeviceControlAdmissionDecision.reject(
          code: DeviceControlErrorCodes.invalidRequest,
          message: 'Restart timeout must be a positive bounded value.',
        );
      }
    }

    if (confirmationCommands.contains(command)) {
      final consumed = consumeConfirmation(
        token: confirmationToken ?? '',
        operation: command,
        fingerprint: confirmationFingerprint,
      );
      if (!consumed.allowed) return consumed;
    }

    admitCorrelation(envelopeDeviceId: envelopeDeviceId, requestId: requestId);
    return const DeviceControlAdmissionDecision.allow();
  }

  ConfirmationTicket issueConfirmation({
    required String deviceId,
    required String operation,
    required String fingerprint,
  }) {
    final ticket = ConfirmationTicket(
      token: mintConfirmationToken(),
      deviceId: deviceId,
      operation: operation,
      fingerprint: fingerprint,
      expiresAt: _clock().add(confirmationTtl),
    );
    _tickets[ticket.token] = ticket;
    return ticket;
  }

  DeviceControlError errorEnvelope({
    required String code,
    required String message,
    required String? requestId,
    required String? envelopeDeviceId,
  }) {
    return DeviceControlError(
      code: code,
      message: message,
      requestId: requestId,
      deviceId: envelopeDeviceId?.trim().isNotEmpty == true
          ? envelopeDeviceId!.trim()
          : _registeredDeviceId(),
    );
  }

  static bool isDeviceControlCommand(String? command) =>
      command != null && DeviceControlCommands.all.contains(command);

  static int? _readTimeoutSeconds(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  void _purgeExpired() {
    final now = _clock();
    _seenRequestIds.removeWhere(
      (_, seenAt) => now.difference(seenAt) > duplicateTtl,
    );
    _tickets.removeWhere((_, ticket) => ticket.expiresAt.isBefore(now));
  }

  Set<String> _acceptedDeviceIds() => {
    _registeredDeviceId().trim(),
    ..._additionalDeviceIds().map((value) => value.trim()),
  }..remove('');
}
