import 'package:equatable/equatable.dart';

import 'notification_kind.dart';

/// The display policy the page mirrors for the service worker.
///
/// The page reads the user's preferences directly. A worker with no page has no
/// access to them, so the page publishes this small record to the Cache API and
/// the worker refuses to wake the user for a disabled kind or with
/// notifications globally off. It carries no copy and no conversation content.
class WebPushDisplayPolicy extends Equatable {
  const WebPushDisplayPolicy({
    required this.enabled,
    this.mutedKinds = const <NotificationKind>{},
  });

  final bool enabled;
  final Set<NotificationKind> mutedKinds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'enabled': enabled,
    'muted_kinds': <String>[for (final kind in mutedKinds) kind.wire],
  };

  @override
  List<Object?> get props => [enabled, mutedKinds];
}
