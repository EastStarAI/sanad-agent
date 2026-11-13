import 'dart:collection';

import 'package:meta/meta.dart';

const deliveryPresenceProtocol = 'sanad.identity_presence';
const deliveryPresenceVersion = 1;
const deliveryPresenceCapability = 'delivery_presence_v1';
const deliveryPresenceMaxRecipientInstances = 128;
const deliveryPresenceMaxPendingLocalEvents = 256;

final _clientInstancePattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Whether [value] is a well-formed Client instance identity.
///
/// One owner for the shape, so presence membership, origin capture, and
/// notification targeting cannot disagree about what names an instance.
bool isValidClientInstanceId(Object? value) {
  if (value is! String) return false;
  return _clientInstancePattern.hasMatch(value.trim().toLowerCase());
}

/// Transport-owned Plan 49 state shared by the Agent's local and cloud
/// adapters. Local membership never leaves this in-memory owner.
class DeliveryPresenceController {
  DeliveryPresenceController({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<Object, String> _localInstances = {};
  final LinkedHashMap<String, Set<String>> _localDeliveryByEvent =
      LinkedHashMap();

  int _interestRevision = 0;
  Set<String>? _cloudInstances;
  DateTime? _interestExpiresAt;
  int _cloudEvents = 0;
  int _suppressedCloudEvents = 0;
  int _localEvents = 0;

  @visibleForTesting
  Set<String> get localInstanceIds => Set.unmodifiable(_localInstances.values);

  @visibleForTesting
  Set<String>? get freshCloudOnlyInstanceIds {
    if (!_hasFreshInterest) return null;
    return Set.unmodifiable(_cloudInstances!.difference(localInstanceIds));
  }

  bool get _hasFreshInterest =>
      _cloudInstances != null &&
      _interestExpiresAt != null &&
      _now().isBefore(_interestExpiresAt!);

  bool get shouldEmitCloud {
    final cloudOnly = freshCloudOnlyInstanceIds;
    return cloudOnly == null || cloudOnly.isNotEmpty;
  }

  /// Whether [clientInstanceId] is provably attached by any route right now.
  ///
  /// Local membership is authoritative and in-memory. The cloud recipient set
  /// counts only while its Gateway lease is fresh: a stale, malformed, or
  /// missing set proves nothing, and an unknown target must not be reported as
  /// reachable.
  bool isInstanceAttached(String clientInstanceId) {
    final normalized = clientInstanceId.trim().toLowerCase();
    if (!_clientInstancePattern.hasMatch(normalized)) return false;
    if (_localInstances.containsValue(normalized)) return true;
    final cloudInstances = freshCloudOnlyInstanceIds;
    if (cloudInstances == null) return false;
    return _cloudInstances!.contains(normalized);
  }

  /// Claims cloud egress for one event and records the outcome.
  ///
  /// [always] is the explicit override for an event that must leave the device
  /// whether or not the live interest set names a cloud-only recipient. A
  /// notification instruction is the one such event: the hosted relay owns the
  /// push tokens, so suppressing the copy because every known recipient is
  /// local strands exactly the device that is offline, which is the case an
  /// account-wide escalation exists for. Ordinary family events keep the gate.
  bool claimCloudEgress({bool always = false}) {
    final emit = always || shouldEmitCloud;
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
  }) {
    final normalized = clientInstanceId.toLowerCase();
    if (!_clientInstancePattern.hasMatch(normalized)) return false;
    if (_localInstances[connectionKey] == normalized) return false;
    _localInstances[connectionKey] = normalized;
    return true;
  }

  bool removeLocalMember(Object connectionKey) =>
      _localInstances.remove(connectionKey) != null;

  void recordLocalDelivery(String eventId, Iterable<String> instanceIds) {
    if (eventId.isEmpty) return;
    final delivered = instanceIds
        .map((value) => value.toLowerCase())
        .where(_clientInstancePattern.hasMatch)
        .take(deliveryPresenceMaxRecipientInstances)
        .toSet();
    _localDeliveryByEvent[eventId] = delivered;
    while (_localDeliveryByEvent.length >
        deliveryPresenceMaxPendingLocalEvents) {
      _localDeliveryByEvent.remove(_localDeliveryByEvent.keys.first);
    }
  }

  Set<String> takeLocalDelivery(String eventId) {
    final delivered = _localDeliveryByEvent.remove(eventId) ?? const <String>{};
    if (!_hasFreshInterest) return const <String>{};
    return Set.unmodifiable(delivered.intersection(_cloudInstances!));
  }

  /// Accepts only a complete, bounded, monotonic Gateway-authored Cloud set.
  /// Invalid or ambiguous input clears suppression immediately.
  bool acceptInterest(Map<String, dynamic> payload) {
    final revision = _asInt(payload['revision']);
    final leaseMs = _asInt(payload['lease_ms']);
    final rawInstances = payload['cloud_recipient_instance_ids'];
    final complete = payload['cloud_recipient_instances_complete'] == true;
    final validEnvelope =
        payload['protocol'] == deliveryPresenceProtocol &&
        payload['version'] == deliveryPresenceVersion &&
        payload['type'] == 'cloud.delivery_interest' &&
        revision != null &&
        revision > 0 &&
        leaseMs != null &&
        leaseMs > 0 &&
        complete &&
        rawInstances is List &&
        rawInstances.length <= deliveryPresenceMaxRecipientInstances;
    if (!validEnvelope) {
      clearInterest();
      return false;
    }
    if (revision < _interestRevision) return false;

    final instances = <String>{};
    for (final value in rawInstances) {
      if (value is! String) {
        clearInterest();
        return false;
      }
      final normalized = value.toLowerCase();
      if (!_clientInstancePattern.hasMatch(normalized) ||
          !instances.add(normalized)) {
        clearInterest();
        return false;
      }
    }

    _interestRevision = revision;
    _cloudInstances = instances;
    _interestExpiresAt = _now().add(Duration(milliseconds: leaseMs));
    return true;
  }

  void clearInterest() {
    _cloudInstances = null;
    _interestExpiresAt = null;
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }

  Future<void> dispose() async {}
}
