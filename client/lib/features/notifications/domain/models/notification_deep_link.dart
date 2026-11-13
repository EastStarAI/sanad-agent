import 'package:equatable/equatable.dart';

/// Where a notification points when the user opens it.
///
/// The deep link is intentionally the smallest identity that can restore the
/// surface: the session and, for an ask, the exact request. A stale request is
/// rejected by the session surface itself, so the link never carries a
/// decision.
class NotificationDeepLink extends Equatable {
  const NotificationDeepLink({
    required this.sessionId,
    this.requestId,
  });

  final String sessionId;

  /// The request the notification is about, when it has one.
  final String? requestId;

  bool get hasRequest => requestId != null && requestId!.isNotEmpty;

  @override
  List<Object?> get props => [sessionId, requestId];
}
