import '../models/web_push_subscription.dart';

/// What the relay did with one registration or revocation.
enum WebPushRegistrationOutcome {
  /// The relay accepted the subscription for the authenticated account.
  registered,

  /// The relay dropped the subscription.
  revoked,

  /// The account session was rejected; nothing was changed.
  unauthorized,

  /// This deployment does not serve the web push contract (404/405/501).
  unavailable,

  /// A transport, timeout, or server failure.
  failed,
}

/// The hosted relay boundary for web push credentials.
///
/// The public Client owns no push provider credential. It registers the browser
/// endpoint it was given against the authenticated account, and the relay
/// resolves that endpoint when the Agent names this Client instance or the whole
/// account. Nothing here reads the Agent's payload or decides a notification.
abstract class WebPushSubscriptionRegistrar {
  /// Registers or refreshes [subscription] for the signed-in account.
  Future<WebPushRegistrationOutcome> register(
    WebPushSubscription subscription, {
    required String accessToken,
    required String clientInstanceId,
    DateTime? createdAt,
  });

  /// Removes a subscription the account no longer owns.
  Future<WebPushRegistrationOutcome> revoke(
    String endpoint, {
    required String accessToken,
  });
}
