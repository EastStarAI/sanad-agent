import 'dart:async';

import 'package:meta/meta.dart';

const deliveryPresenceProtocol = 'sanad.identity_presence';
const deliveryPresenceVersion = 1;
const deliveryPresenceCapability = 'delivery_presence_v1';
const deliveryPresenceRenewalInterval = Duration(seconds: 20);

@immutable
class LocalPresenceMember {
  const LocalPresenceMember({
    required this.clientInstanceId,
    required this.presenceAssertion,
  });

  final String clientInstanceId;
  final String presenceAssertion;

  Map<String, dynamic> toJson() => {
    'client_instance_id': clientInstanceId,
    'presence_assertion': presenceAssertion,
  };
}

@immutable
class LocalPresenceSnapshot {
  const LocalPresenceSnapshot({required this.revision, required this.members});

  final int revision;
  final List<LocalPresenceMember> members;
}

/// Transport-owned Plan 49 state shared by the Agent's local and cloud
/// adapters. It never owns runtime events or durable conversation state.
class DeliveryPresenceController {
  DeliveryPresenceController({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<Object, LocalPresenceMember> _localMembers = {};
  final StreamController<LocalPresenceSnapshot> _localChanges =
      StreamController<LocalPresenceSnapshot>.broadcast(sync: true);

  int _localRevision = 0;
  int _interestRevision = 0;
  int? _cloudRecipientCount;
  DateTime? _interestExpiresAt;
  int _cloudEvents = 0;
  int _suppressedCloudEvents = 0;
  int _localEvents = 0;

  Stream<LocalPresenceSnapshot> get localChanges => _localChanges.stream;
  LocalPresenceSnapshot get localSnapshot => LocalPresenceSnapshot(
    revision: _localRevision,
    members: List.unmodifiable(_localMembers.values),
  );

  bool get hasFreshZeroInterest =>
      _cloudRecipientCount == 0 &&
      _interestExpiresAt != null &&
      _now().isBefore(_interestExpiresAt!);

  bool get shouldEmitCloud => !hasFreshZeroInterest;

  bool claimCloudEgress() {
    final emit = shouldEmitCloud;
    if (emit) {
      _cloudEvents += 1;
    } else {
      _suppressedCloudEvents += 1;
    }
    return emit;
  }

  void recordLocalEvent() => _localEvents += 1;

  Map<String, int> get metrics => {
    'local': _localEvents,
    'cloud': _cloudEvents,
    'suppressed': _suppressedCloudEvents,
  };

  bool updateLocalMember(
    Object connectionKey, {
    required String clientInstanceId,
    required String presenceAssertion,
  }) {
    if (clientInstanceId.isEmpty || presenceAssertion.isEmpty) return false;
    final next = LocalPresenceMember(
      clientInstanceId: clientInstanceId,
      presenceAssertion: presenceAssertion,
    );
    final current = _localMembers[connectionKey];
    if (current?.clientInstanceId == next.clientInstanceId &&
        current?.presenceAssertion == next.presenceAssertion) {
      return false;
    }
    _localMembers[connectionKey] = next;
    _publishLocalChange();
    return true;
  }

  bool removeLocalMember(Object connectionKey) {
    if (_localMembers.remove(connectionKey) == null) return false;
    _publishLocalChange();
    return true;
  }

  LocalPresenceSnapshot renewLocalSnapshot() {
    _publishLocalChange();
    return localSnapshot;
  }

  /// Accepts only a valid, monotonic Gateway-authored lease. Invalid or
  /// ambiguous input clears suppression immediately (safe Cloud fallback).
  bool acceptInterest(Map<String, dynamic> payload) {
    final revision = _asInt(payload['revision']);
    final count = _asInt(payload['cloud_recipient_count']);
    final leaseMs = _asInt(payload['lease_ms']);
    final valid =
        payload['protocol'] == deliveryPresenceProtocol &&
        payload['version'] == deliveryPresenceVersion &&
        payload['type'] == 'cloud.delivery_interest' &&
        revision != null &&
        revision > 0 &&
        count != null &&
        count >= 0 &&
        leaseMs != null &&
        leaseMs > 0;
    if (!valid) {
      clearInterest();
      return false;
    }
    if (revision < _interestRevision) return false;
    _interestRevision = revision;
    _cloudRecipientCount = count;
    _interestExpiresAt = _now().add(Duration(milliseconds: leaseMs));
    return true;
  }

  void clearInterest() {
    _cloudRecipientCount = null;
    _interestExpiresAt = null;
  }

  void _publishLocalChange() {
    _localRevision += 1;
    if (!_localChanges.isClosed) _localChanges.add(localSnapshot);
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  Future<void> dispose() => _localChanges.close();
}
