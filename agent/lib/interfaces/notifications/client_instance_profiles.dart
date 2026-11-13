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

/// One registered Client instance.
final class ClientInstanceProfile {
  const ClientInstanceProfile({
    required this.clientInstanceId,
    required this.locale,
    required this.canNotify,
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
}

/// Bounded, in-memory registry of per-instance display facts.
///
/// Keys are the Client-owned instance ids already used by delivery presence,
/// lowercased. Nothing in this registry is persisted or published: a reconnecting
/// Client re-registers, and an unregistered instance renders in the fallback
/// locale.
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

  /// Number of remembered instances.
  int get length => _profiles.length;

  /// Reads a locale and notification capability from an authenticated
  /// `client.hello` envelope and registers them.
  ///
  /// The envelope's top-level `locale` is authoritative. `metadata.locale` and
  /// the cloud `origin_client.locale` shape are accepted as the same value so a
  /// transport that nests display metadata does not lose it. Returns the
  /// registered profile, or `null` when the envelope names no valid instance.
  ClientInstanceProfile? registerFromHello(Map<String, dynamic> hello) {
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
    );
  }

  /// Registers display facts for [clientInstanceId], keeping previously known
  /// values for the fields [locale] and [canNotify] leave unstated.
  ///
  /// A malformed or unsupported locale is ignored rather than stored, so the
  /// instance keeps a defined fallback.
  ClientInstanceProfile? register({
    required String clientInstanceId,
    Object? locale,
    Object? canNotify,
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
    );
    _profiles.remove(normalizedId);
    _profiles[normalizedId] = profile;
    while (_profiles.length > capacity) {
      _profiles.remove(_profiles.keys.first);
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

  /// Forgets [clientInstanceId]; called when its last connection is gone.
  void forget(String? clientInstanceId) {
    final normalizedId = _normalize(clientInstanceId);
    if (normalizedId == null) return;
    _profiles.remove(normalizedId);
  }

  /// Drops every registration. Used when identity changes or the runtime stops.
  void clear() => _profiles.clear();

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
