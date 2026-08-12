import 'dart:async';
import 'dart:io';

import 'auth_manager.dart';
import 'device_authorization_client.dart';

enum ColocatedCouplingStatus {
  alreadyAuthorized('already_authorized'),
  pending('pending'),
  completed('completed'),
  failed('failed');

  const ColocatedCouplingStatus(this.wireName);
  final String wireName;
}

class ColocatedCouplingSnapshot {
  const ColocatedCouplingSnapshot({
    required this.status,
    this.enrollmentRequestId,
    this.expiresIn,
    this.error,
  });

  final ColocatedCouplingStatus status;
  final String? enrollmentRequestId;
  final int? expiresIn;
  final String? error;

  Map<String, dynamic> toJson() => {
    'status': status.wireName,
    if (enrollmentRequestId != null)
      'enrollment_request_id': enrollmentRequestId,
    if (expiresIn != null) 'expires_in': expiresIn,
    if (error != null) 'error': error,
  };
}

/// Coordinates the proof-bound Agent half of one co-located sign-in.
///
/// Only [ColocatedCouplingSnapshot] crosses the Local Gateway. The private
/// device code and key-bearing enrollment remain inside [DeviceAuthorizationClient].
class ColocatedAuthCoupling {
  ColocatedAuthCoupling({
    required this.authManager,
    required this.authorizationClient,
    String? deviceName,
    String? platform,
  }) : platform = platform ?? Platform.operatingSystem,
       deviceName =
           deviceName ??
           defaultAgentDeviceName(platform ?? Platform.operatingSystem);

  static const clientId = 'sanad_agent_colocated';

  final AuthManager authManager;
  final DeviceAuthorizationClient authorizationClient;
  final String deviceName;
  final String platform;

  ColocatedCouplingSnapshot? _snapshot;
  Future<ColocatedCouplingSnapshot>? _startFuture;

  ColocatedCouplingSnapshot get snapshot {
    if (authManager.deviceToken != null) {
      return const ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.alreadyAuthorized,
      );
    }
    return _snapshot ??
        const ColocatedCouplingSnapshot(
          status: ColocatedCouplingStatus.failed,
          error: 'not_started',
        );
  }

  Future<ColocatedCouplingSnapshot> start() {
    if (authManager.deviceToken != null) {
      return Future.value(snapshot);
    }
    final current = _snapshot;
    if (current != null && current.status == ColocatedCouplingStatus.pending) {
      return Future.value(current);
    }
    return _startFuture ??= _start().whenComplete(() => _startFuture = null);
  }

  Future<ColocatedCouplingSnapshot> _start() async {
    try {
      final enrollment = await authorizationClient.startEnrollment(
        clientId: clientId,
        deviceName: deviceName,
        platform: platform,
        hardwareId: authManager.hardwareId,
      );
      final pending = ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.pending,
        enrollmentRequestId: enrollment.transactionId,
        expiresIn: enrollment.expiresIn,
      );
      _snapshot = pending;
      unawaited(_redeem(enrollment));
      return pending;
    } on Object {
      return _snapshot = const ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.failed,
        error: 'temporarily_unavailable',
      );
    }
  }

  Future<void> _redeem(DeviceAuthorizationEnrollment enrollment) async {
    try {
      await authorizationClient.redeemEnrollment(enrollment);
      _snapshot = ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.completed,
        enrollmentRequestId: enrollment.transactionId,
      );
    } on Object {
      _snapshot = ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.failed,
        enrollmentRequestId: enrollment.transactionId,
        error: 'authorization_incomplete',
      );
    }
  }
}
