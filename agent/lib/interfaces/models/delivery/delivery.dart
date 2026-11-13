/// Phase 27 — Canonical delivery contract models.
///
/// The agent runtime owns the semantic meaning and destination of every event.
/// These value objects express that policy in a typed, transport-agnostic way
/// so `GatewayManager` can route by declarative scope instead of by platform-id
/// strings or event-name lists.
///
/// See `sanad-agent/docs/plans/27-unified-cross-transport-event-delivery.md`
/// section 7 for the canonical envelope contract.
library;

import 'package:uuid/uuid.dart';

/// A platform family identifier — a typed, extensible value object.
///
/// `platform_family` is NOT a closed enum inside `GatewayManager`. A new
/// adapter may declare its own identifier without adding a semantic branch to
/// the manager. The well-known families used in this phase are exposed as
/// static constants for convenience and documentation.
class PlatformFamily {
  final String value;

  const PlatformFamily._(this.value);

  /// The Sanad Client family — local daemon and cloud gateway transports.
  /// These two transports synchronize live Sanad events between them.
  static const sanadClient = PlatformFamily._('sanad_client');

  /// External isolated families (Plan 27 prepares their isolation contracts).
  static const telegram = PlatformFamily._('telegram');
  static const whatsapp = PlatformFamily._('whatsapp');
  static const cli = PlatformFamily._('cli');

  /// Construct a custom family identifier. Adapters added in future phases
  /// declare their own family here without touching `GatewayManager`.
  factory PlatformFamily(String value) {
    if (value.isEmpty) {
      throw ArgumentError('platform_family cannot be empty');
    }
    return PlatformFamily._(value);
  }

  bool get isSanadClient =>
      identical(this, sanadClient) || value == 'sanad_client';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlatformFamily && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;

  Map<String, dynamic> toJson() => {'platform_family': value};

  static PlatformFamily fromJson(Map<String, dynamic> json) =>
      PlatformFamily(json['platform_family'] as String);
}

/// The transport medium of a platform instance.
///
/// `local` and `cloud` are the two `sanad_client` transports. External
/// adapters declare their own transport identifiers (e.g. `telegram_api`).
class PlatformTransport {
  final String value;

  const PlatformTransport._(this.value);

  static const local = PlatformTransport._('local');
  static const cloud = PlatformTransport._('cloud');
  static const telegramApi = PlatformTransport._('telegram_api');
  static const whatsappApi = PlatformTransport._('whatsapp_api');
  static const cli = PlatformTransport._('cli');

  factory PlatformTransport(String value) {
    if (value.isEmpty) {
      throw ArgumentError('transport cannot be empty');
    }
    return PlatformTransport._(value);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlatformTransport && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Describes a platform adapter's identity in the routing topology.
///
/// Two platforms sharing the same `platform_family` but differing in
/// `transport` are treated as alternate delivery paths for the same family
/// (e.g. `sanad_client` local + cloud).
class PlatformDescriptor {
  final PlatformFamily platformFamily;
  final PlatformTransport transport;

  /// Disambiguates multiple adapters/accounts of the same family+transport.
  /// Defaults to `platformId` when only one instance exists per transport.
  final String? platformInstanceId;

  const PlatformDescriptor({
    required this.platformFamily,
    required this.transport,
    this.platformInstanceId,
  });

  const PlatformDescriptor.sanadClient({
    required PlatformTransport transport,
    String? platformInstanceId,
  }) : this(
         platformFamily: PlatformFamily.sanadClient,
         transport: transport,
         platformInstanceId: platformInstanceId,
       );

  Map<String, dynamic> toJson() => {
    'platform_family': platformFamily.value,
    'transport': transport.value,
    if (platformInstanceId != null) 'platform_instance_id': platformInstanceId,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlatformDescriptor &&
          other.platformFamily == platformFamily &&
          other.transport == transport &&
          other.platformInstanceId == platformInstanceId);

  @override
  int get hashCode =>
      Object.hash(platformFamily, transport, platformInstanceId);

  @override
  String toString() =>
      'PlatformDescriptor(${platformFamily.value}:${transport.value}'
      '${platformInstanceId != null ? '@$platformInstanceId' : ''})';
}

/// The canonical delivery scope of an event.
///
/// The event producer decides the scope; `GatewayManager` and the backend
/// route by it without inspecting the event `name`.
enum DeliveryScope {
  /// Return to the originating platform instance and conversation only.
  /// Used for query/snapshot results, save confirmations, pre-run errors.
  origin,

  /// Fan-out to all platform instances of the declared `platformFamily`.
  /// In this phase only `sanad_client` is supported for multicast.
  /// Used for live conversation timeline events and shared state changes.
  platformFamily,

  /// Target a single platform instance owning `targetHardwareId`.
  /// Used for platform-tool execution on a qualified device.
  hardware,

  /// App → daemon direction when a canonical device target is required.
  device,
}

/// Wire serialization of [DeliveryScope]. The canonical contract (plan
/// section 7.1) uses snake_case on the wire; Dart enum `.name` is camelCase,
/// so we map explicitly at the serialization boundary.
String _scopeToWire(DeliveryScope scope) {
  switch (scope) {
    case DeliveryScope.origin:
      return 'origin';
    case DeliveryScope.platformFamily:
      return 'platform_family';
    case DeliveryScope.hardware:
      return 'hardware';
    case DeliveryScope.device:
      return 'device';
  }
}

DeliveryScope _scopeFromWire(String name) {
  switch (name) {
    case 'origin':
      return DeliveryScope.origin;
    case 'platform_family':
    case 'platformFamily': // tolerate camelCase for robustness
      return DeliveryScope.platformFamily;
    case 'hardware':
      return DeliveryScope.hardware;
    case 'device':
      return DeliveryScope.device;
    default:
      throw ArgumentError('unknown delivery scope: $name');
  }
}

/// The delivery policy attached to a canonical event.
///
/// This is part of the transport contract, NOT display metadata. It MUST be
/// typed and ride alongside `event_id` on every canonical envelope copy.
class DeliveryPolicy {
  final DeliveryScope scope;

  /// Required when `scope == platformFamily` or `hardware`.
  /// `sanad_client` is the only multicast family supported in this phase.
  final PlatformFamily? platformFamily;

  /// Required when `scope == hardware`. Targets a single qualified device.
  final String? targetHardwareId;

  /// Required for Sanad Client `origin` resolution over the cloud transport.
  /// Local transports resolve it to the requesting WebSocket inside the agent.
  final String? requestId;

  /// Opaque route identifier owned by the originating platform only.
  /// `GatewayManager` and the backend do not interpret it. External adapters
  /// keep their conversation/chat binding internal and never expose it to the
  /// backend.
  final String? routeId;

  const DeliveryPolicy({
    required this.scope,
    this.platformFamily,
    this.targetHardwareId,
    this.requestId,
    this.routeId,
  });

  /// Convenience constructors for the common scopes.
  const DeliveryPolicy.origin({this.requestId, this.routeId})
    : scope = DeliveryScope.origin,
      platformFamily = null,
      targetHardwareId = null;

  const DeliveryPolicy.platformFamily(PlatformFamily family)
    : scope = DeliveryScope.platformFamily,
      platformFamily = family,
      targetHardwareId = null,
      requestId = null,
      routeId = null;

  const DeliveryPolicy.hardware({
    required this.targetHardwareId,
    PlatformFamily family = PlatformFamily.sanadClient,
  }) : scope = DeliveryScope.hardware,
       platformFamily = family,
       requestId = null,
       routeId = null;

  const DeliveryPolicy.device({this.targetHardwareId})
    : scope = DeliveryScope.device,
      platformFamily = null,
      requestId = null,
      routeId = null;

  /// Validates the policy against the rules in plan section 7.2.
  /// Returns a non-null reason string when invalid, or `null` when valid.
  String? validate() {
    switch (scope) {
      case DeliveryScope.origin:
        // route is optional for local-origin; requestId required for cloud
        // origin resolution but the cloud platform enforces that locally.
        return null;
      case DeliveryScope.platformFamily:
        if (platformFamily == null) {
          return 'platform_family is required for scope=platform_family';
        }
        return null;
      case DeliveryScope.hardware:
        if (targetHardwareId == null || targetHardwareId!.isEmpty) {
          return 'target_hardware_id is required for scope=hardware';
        }
        if (platformFamily == null) {
          return 'platform_family is required for scope=hardware';
        }
        return null;
      case DeliveryScope.device:
        return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'scope': _scopeToWire(scope),
    if (platformFamily != null) 'platform_family': platformFamily!.value,
    if (targetHardwareId != null) 'target_hardware_id': targetHardwareId,
    if (requestId != null) 'request_id': requestId,
    if (routeId != null) 'route_id': routeId,
  };

  factory DeliveryPolicy.fromJson(Map<String, dynamic> json) {
    final scopeName = json['scope'] as String;
    final scope = _scopeFromWire(scopeName);
    return DeliveryPolicy(
      scope: scope,
      platformFamily: json['platform_family'] != null
          ? PlatformFamily(json['platform_family'] as String)
          : null,
      targetHardwareId: json['target_hardware_id'] as String?,
      requestId: json['request_id'] as String?,
      routeId: json['route_id'] as String?,
    );
  }

  DeliveryPolicy copyWith({
    DeliveryScope? scope,
    PlatformFamily? platformFamily,
    String? targetHardwareId,
    String? requestId,
    String? routeId,
  }) => DeliveryPolicy(
    scope: scope ?? this.scope,
    platformFamily: platformFamily ?? this.platformFamily,
    targetHardwareId: targetHardwareId ?? this.targetHardwareId,
    requestId: requestId ?? this.requestId,
    routeId: routeId ?? this.routeId,
  );
}

/// Origin context carried internally by the agent when forwarding an event.
///
/// Describes where an event came from so `GatewayManager` can resolve
/// `DeliveryScope.origin`. The route id is opaque to the manager and backend;
/// only the owning platform interprets it.
class OriginContext {
  final PlatformFamily platformFamily;
  final PlatformTransport transport;
  final String? platformInstanceId;

  /// Opaque route identifier inside the owning platform only.
  final String? routeId;

  /// The platform id string from `BasePlatform.platformId` — kept for
  /// backward compatibility with the existing `GatewayResponse.platformId`
  /// field during the transition.
  final String? platformId;

  /// Hardware identity of the originating connection, if known.
  final String? hardwareId;

  /// Authenticated Client instance identity of the connection that started the
  /// turn, when the transport could prove it (the local `client.hello` instance
  /// id or the cloud `origin_client.client_instance_id`).
  ///
  /// This is internal routing identity for notification targeting. It is
  /// deliberately not serialized: the canonical origin envelope is unchanged,
  /// and no existing event gains a field.
  final String? clientInstanceId;

  final String? requestId;
  final String? sessionId;
  final String? deviceId;

  const OriginContext({
    required this.platformFamily,
    required this.transport,
    this.platformInstanceId,
    this.routeId,
    this.platformId,
    this.hardwareId,
    this.clientInstanceId,
    this.requestId,
    this.sessionId,
    this.deviceId,
  });

  PlatformDescriptor toDescriptor() => PlatformDescriptor(
    platformFamily: platformFamily,
    transport: transport,
    platformInstanceId: platformInstanceId ?? platformId,
  );

  Map<String, dynamic> toJson() => {
    'platform_family': platformFamily.value,
    'transport': transport.value,
    if (platformInstanceId != null) 'platform_instance_id': platformInstanceId,
    if (routeId != null) 'route_id': routeId,
    if (platformId != null) 'origin_platform_id': platformId,
    if (hardwareId != null) 'origin_hardware_id': hardwareId,
    if (requestId != null) 'request_id': requestId,
    if (sessionId != null) 'session_id': sessionId,
    if (deviceId != null) 'device_id': deviceId,
  };
}

/// Generates canonical, collision-resistant event identifiers.
///
/// `event_id` is minted once at event creation and preserved across all local
/// and cloud copies. It is NOT regenerated per transport, NOT derived from
/// content or timestamp alone, and NOT reused for another semantic event.
class EventId {
  EventId._();

  /// Generate a new unique event id.
  /// UUID v4 keeps ids collision-resistant across independent daemon
  /// processes, not merely unique inside one process.
  static String generate() => 'evt_${const Uuid().v4()}';
}
