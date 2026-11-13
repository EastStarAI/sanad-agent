/// Plan 174 — the Client-side facts the Agent needs to render and target one
/// notification: the interface locale and whether the instance can notify.
///
/// Both routes register here. A local Client sends them in its authenticated
/// `client.hello`; a cloud Client's connection carries no locale today, so an
/// absent value is a supported state rather than an error. Registration is
/// display metadata only: it never grants permission, changes command
/// execution, or authenticates anything.
library;

import 'notification_copy.dart';
import 'notification_kind.dart';
import 'notification_preferences.dart';

/// One registered Client instance.
final class ClientInstanceProfile {
  const ClientInstanceProfile({
    required this.clientInstanceId,
    required this.locale,
    required this.canNotify,
    this.preferences = ClientNotificationPreferences.productDefault,
  });

  final String clientInstanceId;

  /// The interface locale copy is rendered in.
  final NotificationLocale locale;

  /// Whether this instance can raise a notification at all.
  ///
  /// An instance that never declared anything is assumed capable: a running
  /// Sanad Client raises its own OS notification on every platform. Only an
  /// explicit `notification_capable: false` (a headless driver client, a build
  /// without notification support) makes the Agent skip the origin step.
  final bool canNotify;

  /// The choices this device declared for itself.
  ///
  /// A device that declared nothing holds the product default, which is the
  /// same answer as a device the Agent has never met.
  final ClientNotificationPreferences preferences;
}

/// Bounded, in-memory registry of per-instance display facts.
///
/// Keys are the Client-owned instance ids already used by delivery presence,
/// lowercased. Nothing in this registry is persisted or published: a reconnecting
/// Client re-registers, and an unregistered instance renders in the fallback
/// locale.
///
/// Registration is scoped to the connection that announced it, because instance
/// identity outlives one socket: a Client that reconnects, or two Clients that
/// report the same instance id, hold the same registration. Forgetting one
/// connection therefore drops only that connection's claim and keeps the facts
/// for as long as another connection still holds the instance.
class ClientInstanceProfiles {
  ClientInstanceProfiles({this.capacity = defaultCapacity}) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'must be positive');
    }
  }

  static const int defaultCapacity = 512;

  /// Maximum number of remembered instances; the oldest entry is evicted.
  final int capacity;

  final Map<String, ClientInstanceProfile> _profiles = {};

  /// Connections holding each registered instance, keyed by the instance id.
  ///
  /// A connection key is the transport's own socket handle; it is carried only
  /// so [forget] can tell "this socket is gone" from "this instance is gone".
  final Map<String, Set<Object>> _connections = {};

  /// Number of remembered instances.
  int get length => _profiles.length;

  /// Reads a locale, notification capability, and this device's notification
  /// choices from an authenticated `client.hello` envelope and registers them
  /// for [connectionKey].
  ///
  /// The envelope's top-level `locale` is authoritative. `metadata.locale` and
  /// the cloud `origin_client.locale` shape are accepted as the same value so a
  /// transport that nests display metadata does not lose it. Returns the
  /// registered profile, or `null` when the envelope names no valid instance.
  ClientInstanceProfile? registerFromHello(
    Map<String, dynamic> hello, {
    Object? connectionKey,
  }) {
    final instanceId = hello['client_instance_id'];
    if (instanceId is! String || instanceId.trim().isEmpty) return null;
    final metadata = hello['metadata'];
    final nestedLocale = metadata is Map ? metadata['locale'] : null;
    return register(
      clientInstanceId: instanceId,
      locale: hello['locale'] ?? nestedLocale,
      canNotify:
          hello['notification_capable'] ??
          (metadata is Map ? metadata['notification_capable'] : null),
      notifications:
          hello['notifications'] ??
          (metadata is Map ? metadata['notifications'] : null),
      connectionKey: connectionKey,
    );
  }

  /// Registers display facts for [clientInstanceId], keeping previously known
  /// values for the fields [locale], [canNotify], and [notifications] leave
  /// unstated.
  ///
  /// [connectionKey] names the connection that announced the facts, when the
  /// caller has one; it is what lets [forget] release one connection without
  /// erasing an instance another connection still holds. A malformed or
  /// unsupported locale is ignored rather than stored, so the instance keeps a
  /// defined fallback.
  ///
  /// [notifications] is the device's own declaration. An absent or unreadable
  /// value keeps the previous choice, while a well-formed but empty declaration
  /// is a deliberate reset to the product default.
  ClientInstanceProfile? register({
    required String clientInstanceId,
    Object? locale,
    Object? canNotify,
    Object? notifications,
    Object? connectionKey,
  }) {
    final normalizedId = _normalize(clientInstanceId);
    if (normalizedId == null) return null;
    final previous = _profiles[normalizedId];
    final parsedLocale = NotificationLocale.tryParse(locale);
    final parsedCapability = _parseBool(canNotify);
    final profile = ClientInstanceProfile(
      clientInstanceId: normalizedId,
      locale: parsedLocale ?? previous?.locale ?? NotificationLocale.fallback,
      canNotify: parsedCapability ?? previous?.canNotify ?? true,
      preferences: ClientNotificationPreferences.tryParse(notifications) ??
          previous?.preferences ??
          ClientNotificationPreferences.productDefault,
    );
    _profiles.remove(normalizedId);
    _profiles[normalizedId] = profile;
    if (connectionKey != null) {
      _connections
          .putIfAbsent(normalizedId, () => <Object>{})
          .add(connectionKey);
    }
    while (_profiles.length > capacity) {
      final evicted = _profiles.keys.first;
      _profiles.remove(evicted);
      _connections.remove(evicted);
    }
    return profile;
  }

  /// The registered profile for [clientInstanceId], or `null` when unknown.
  ClientInstanceProfile? profileFor(String? clientInstanceId) {
    final normalizedId = _normalize(clientInstanceId);
    if (normalizedId == null) return null;
    return _profiles[normalizedId];
  }

  /// The copy locale for [clientInstanceId].
  ///
  /// Falls back to [NotificationLocale.fallback] when the instance is unknown
  /// or registered no supported locale.
  NotificationLocale localeFor(String? clientInstanceId) =>
      profileFor(clientInstanceId)?.locale ?? NotificationLocale.fallback;

  /// Whether [clientInstanceId] can raise a notification.
  ///
  /// An unknown instance is assumed capable: the Agent cannot prove otherwise,
  /// and treating an unregistered origin as incapable would turn every first
  /// ask into an immediate account-wide fan-out.
  bool canNotify(String? clientInstanceId) =>
      profileFor(clientInstanceId)?.canNotify ?? true;

  /// Whether [clientInstanceId] wants a notification of [kind].
  ///
  /// An unknown instance wants it: the product default is enabled, and guessing
  /// "off" for a device the Agent has never met would silently drop the first
  /// notification a new device ever receives.
  bool allows(
    String? clientInstanceId,
    NotificationKind kind,
  ) =>
      profileFor(clientInstanceId)?.preferences.allowsKind(kind) ?? true;

  /// The urgency to dispatch [kind] to [clientInstanceId] with.
  ///
  /// The Agent's own decision is the ceiling for a device with no declaration,
  /// and a declared preference can only lower it.
  NotificationUrgency urgencyFor(
    String? clientInstanceId,
    NotificationKind kind,
    NotificationUrgency fromAgent,
  ) {
    final profile = profileFor(clientInstanceId);
    if (profile == null) return fromAgent;
    return profile.preferences.urgencyFor(kind, fromAgent);
  }

  /// Forgets [clientInstanceId] for one connection, or for every connection.
  ///
  /// When [connectionKey] is supplied, only that connection's claim is
  /// released: the registration survives while another live connection still
  /// holds the same instance id, because a reconnect or a second window with
  /// the same identity is the same Client and its locale and capability are
  /// still true. Without a key the call cannot prove the instance is gone, so
  /// it erases nothing while a connection still holds it; [clear] is the
  /// explicit "forget everything" path.
  void forget(String? clientInstanceId, {Object? connectionKey}) {
    final normalizedId = _normalize(clientInstanceId);
    if (normalizedId == null) return;
    final holders = _connections[normalizedId];
    if (holders != null && connectionKey != null) {
      holders.remove(connectionKey);
    }
    if (holders != null && holders.isNotEmpty) return;
    _connections.remove(normalizedId);
    _profiles.remove(normalizedId);
  }

  /// Drops every registration, for every connection. Used when identity changes
  /// or the runtime stops.
  void clear() {
    _profiles.clear();
    _connections.clear();
  }

  static String? _normalize(String? value) {
    final normalized = value?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty || normalized.length > 64) return null;
    return normalized;
  }

  static bool? _parseBool(Object? value) {
    if (value is bool) return value;
    if (value == null) return null;
    final normalized = value.toString().trim().toLowerCase();
    if (normalized == 'true') return true;
    if (normalized == 'false') return false;
    return null;
  }
}
