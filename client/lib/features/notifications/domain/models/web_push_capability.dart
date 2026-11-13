import 'package:equatable/equatable.dart';

/// Whether this browser can deliver a Sanad notification, and if not, why.
///
/// The states are the product's, not a browser's: [installRequired] is the iOS
/// answer (Safari tabs cannot receive web push at all), [unconfigured] means
/// this build carries no VAPID public key, and [unsupported] means the browser
/// exposes no notification surface. Settings states each one instead of offering
/// a permission button that cannot work.
enum WebPushAvailability {
  ready,
  installRequired,
  unconfigured,
  unsupported;

  bool get canSubscribe => this == WebPushAvailability.ready;
}

/// Why an explicit enable attempt did not finish.
enum WebPushFailure {
  none,

  /// The browser refused, or the user dismissed, the permission prompt.
  permissionDenied,

  /// A subscription must belong to an authenticated account, and none exists.
  signInRequired,

  /// The browser subscription exists but the relay did not accept it.
  registrationFailed,
}

/// The browser's subscription state, as the page observes it.
enum WebPushSubscriptionStatus {
  notSubscribed,
  subscribing,
  subscribed,
}

/// The Settings and pipeline projection of web push.
class WebPushSettings extends Equatable {
  const WebPushSettings({
    this.isWebPlatform = false,
    this.availability = WebPushAvailability.unsupported,
    this.status = WebPushSubscriptionStatus.notSubscribed,
    this.failure = WebPushFailure.none,
  });

  /// Whether this build is the web Client at all. A desktop or mobile build
  /// resolves [WebPushAvailability.unsupported] and never renders web copy.
  final bool isWebPlatform;

  final WebPushAvailability availability;
  final WebPushSubscriptionStatus status;
  final WebPushFailure failure;

  bool get isSubscribed => status == WebPushSubscriptionStatus.subscribed;

  bool get canSubscribe => isWebPlatform && availability.canSubscribe;

  WebPushSettings copyWith({
    WebPushAvailability? availability,
    WebPushSubscriptionStatus? status,
    WebPushFailure? failure,
  }) {
    return WebPushSettings(
      isWebPlatform: isWebPlatform,
      availability: availability ?? this.availability,
      status: status ?? this.status,
      failure: failure ?? this.failure,
    );
  }

  @override
  List<Object?> get props => [isWebPlatform, availability, status, failure];
}
