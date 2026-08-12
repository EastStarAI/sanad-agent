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
  DeviceAuthorizationEnrollment? _enrollment;
  Future<ColocatedCouplingSnapshot>? _startFuture;
  int _generation = 0;

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
    final activeStart = _startFuture;
    if (activeStart != null) return activeStart;
    final ownedStart = _start();
    _startFuture = ownedStart;
    return ownedStart.whenComplete(() {
      if (identical(_startFuture, ownedStart)) {
        _startFuture = null;
      }
    });
  }

  Future<ColocatedCouplingSnapshot> _start() async {
    final generation = ++_generation;
    try {
      final enrollment = await authorizationClient.startEnrollment(
        clientId: clientId,
        deviceName: deviceName,
        platform: platform,
        hardwareId: authManager.hardwareId,
      );
      if (generation != _generation) {
        await authorizationClient.cancelEnrollment(enrollment);
        return snapshot;
      }
      final pending = ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.pending,
        enrollmentRequestId: enrollment.transactionId,
        expiresIn: enrollment.expiresIn,
      );
      _enrollment = enrollment;
      _snapshot = pending;
      unawaited(_redeem(enrollment, generation));
      return pending;
    } on Object {
      if (generation != _generation) rethrow;
      return _snapshot = const ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.failed,
        error: 'temporarily_unavailable',
      );
    }
  }

  Future<void> cancel() async {
    final enrollment = _enrollment;
    _generation += 1;
    _startFuture = null;
    _enrollment = null;
    _snapshot = null;
    if (enrollment != null) {
      unawaited(_cancelEnrollment(enrollment));
    }
  }

  Future<void> _cancelEnrollment(
    DeviceAuthorizationEnrollment enrollment,
  ) async {
    try {
      await authorizationClient.cancelEnrollment(enrollment);
    } on Object {
      // Local generation invalidation remains authoritative for this process.
    }
  }

  Future<void> _redeem(
    DeviceAuthorizationEnrollment enrollment,
    int generation,
  ) async {
    try {
      await authorizationClient.redeemEnrollment(
        enrollment,
        isActive: () => generation == _generation,
      );
      if (generation != _generation) return;
      _enrollment = null;
      _snapshot = ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.completed,
        enrollmentRequestId: enrollment.transactionId,
      );
    } on Object {
      if (generation != _generation) return;
      _enrollment = null;
      _snapshot = ColocatedCouplingSnapshot(
        status: ColocatedCouplingStatus.failed,
        enrollmentRequestId: enrollment.transactionId,
        error: 'authorization_incomplete',
      );
    }
  }
}
