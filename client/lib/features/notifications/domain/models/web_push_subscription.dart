import 'package:equatable/equatable.dart';

/// One browser push subscription, as the page observes it.
///
/// The endpoint is a capability: anyone holding it can deliver to this browser,
/// so it is never logged, never placed in workspace state, and sent only to the
/// authenticated relay over HTTPS. The keys are the payload-encryption keys the
/// relay needs; they are equally opaque to the Agent.
class WebPushSubscription extends Equatable {
  const WebPushSubscription({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  });

  /// Rebuilds a subscription a service worker forwarded after rotation. A
  /// message missing any identity field is rejected rather than half-registered.
  static WebPushSubscription? fromMessage(Object? raw) {
    if (raw is! Map) return null;
    final endpoint = _read(raw['endpoint']);
    final keys = raw['keys'];
    if (endpoint == null || keys is! Map) return null;
    final p256dh = _read(keys['p256dh']);
    final auth = _read(keys['auth']);
    if (p256dh == null || auth == null) return null;
    return WebPushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth);
  }

  final String endpoint;
  final String p256dh;
  final String auth;

  /// The registration body the relay stores against the signed-in account.
  ///
  /// It carries identity and transport data only: no conversation, no usable
  /// authorization material, and nothing the relay is expected to interpret.
  Map<String, dynamic> toRegistrationJson({
    required String clientInstanceId,
    DateTime? createdAt,
  }) {
    return <String, dynamic>{
      'platform': 'web',
      'client_instance_id': clientInstanceId,
      'endpoint': endpoint,
      'keys': <String, String>{'p256dh': p256dh, 'auth': auth},
      if (createdAt != null) 'created_at': createdAt.toUtc().toIso8601String(),
    };
  }

  @override
  List<Object?> get props => [endpoint, p256dh, auth];

  static String? _read(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
