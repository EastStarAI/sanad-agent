import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/mobile_foreground_policy.dart';

/// Turns a push wake-up into the same visible outcome the socket produces.
///
/// Push adds no rules of its own. An arrival is decided by
/// [MobileForegroundPolicy] and then handed to the existing
/// [NotificationService], so preferences, permission, collapse, quiet window,
/// and dedupe stay in one place; an interaction is handed to the existing
/// [NotificationActionRouter], so an approval still travels the single
/// `tool_permission_response` path. What this class adds is the mobile-specific
/// sequencing: a push can arrive with no socket, and an interaction can start
/// the process.
class MobilePushService {
  MobilePushService({
    required MobilePushTransport transport,
    required NotificationService notifications,
    required NotificationActionRouter actionRouter,
    required NotificationPresence Function() readPresence,
    required bool Function() isAppInForeground,
    Future<void> Function()? awaitReady,
    Duration readinessTimeout = const Duration(seconds: 8),
    DateTime Function()? clock,
  })  : _transport = transport,
        _notifications = notifications,
        _actionRouter = actionRouter,
        _readPresence = readPresence,
        _isAppInForeground = isAppInForeground,
        _awaitReady = awaitReady,
        _readinessTimeout = readinessTimeout,
        _clock = clock ?? DateTime.now;

  final MobilePushTransport _transport;
  final NotificationService _notifications;
  final NotificationActionRouter _actionRouter;
  final NotificationPresence Function() _readPresence;
  final bool Function() _isAppInForeground;

  /// Waits for the authoritative state an interaction needs.
  ///
  /// A notification can start a terminated Client, and an approval must be
  /// answered against the ask the Client actually holds. This future is the
  /// bridge's "the replay has landed" signal; when it does not arrive in time
  /// the interaction is dropped, because answering an ask this Client cannot
  /// correlate is worse than making the user open the session.
  final Future<void> Function()? _awaitReady;

  final Duration _readinessTimeout;
  final DateTime Function() _clock;

  static final Logger _logger = Logger('notifications.push.service');

  final List<StreamSubscription<MobilePushMessage>> _subscriptions = [];
  bool _started = false;
  bool _disposed = false;

  /// Applies the foreground rule to the last arrival, for tests and diagnostics.
  MobileForegroundDecision? lastDecision;

  Future<void> start() async {
    if (_started || _disposed || !_transport.isSupported) return;
    _started = true;
    _subscriptions.add(_transport.displays.listen(
      (message) => unawaited(handleDisplay(message)),
      onError: (Object error) => _logger.warning('push display stream error', error),
    ));
    _subscriptions.add(_transport.interactions.listen(
      (message) => unawaited(handleInteraction(message)),
      onError: (Object error) => _logger.warning('push interaction stream error', error),
    ));
    final launch = await _transport.takeInitialMessage();
    if (launch != null) {
      // A terminated Client was started by the interaction itself, so this is
      // the only copy of that notification it will ever see.
      await handleInteraction(launch);
    }
  }

  /// Handles one arrival while the process is alive.
  ///
  /// Returns the decision, or `null` when the message is not a notification this
  /// build understands or it outlived its own expiry.
  Future<MobileForegroundDecision?> handleDisplay(MobilePushMessage message) async {
    if (_disposed) return null;
    final payload = message.payload;
    if (payload == null) {
      _logger.fine('dropped an unreadable push message');
      return null;
    }
    if (payload.isExpiredAt(_clock())) {
      // A late escalation must never wake a device for an ask that is over.
      _logger.info('dropped an expired push notification');
      return null;
    }

    final decision = MobileForegroundPolicy.decide(
      payload: payload,
      presence: _readPresence(),
      appInForeground: _isAppInForeground(),
    );
    lastDecision = decision;
    if (decision.isInAppOnly) {
      // The in-app prompt is the surface; push never mutates it.
      _logger.fine('push suppressed: the session is on screen');
      return decision;
    }

    // Reuses the one display path: preferences, permission, collapse, quiet
    // window, and `event_id` dedupe against the socket copy all apply here.
    await _notifications.handleEvent(message.canonicalEvent ?? const <String, dynamic>{});
    return decision;
  }

  /// Handles a tap or a button press on a presented notification.
  ///
  /// Approval, denial, and open all resolve through the existing router. A
  /// request that is already resolved, no longer known, or never replayed to
  /// this Client is dropped instead of being answered from the payload alone.
  Future<NotificationActionOutcome?> handleInteraction(MobilePushMessage message) async {
    if (_disposed) return null;
    final payload = message.payload;
    if (payload == null) {
      _logger.fine('dropped an unreadable push interaction');
      return null;
    }
    if (payload.isExpiredAt(_clock())) {
      _logger.info('dropped an interaction with an expired ask');
      return NotificationActionOutcome.stale;
    }

    await _awaitAuthoritativeState();
    final outcome = await _actionRouter.handle(payload, message.actionId);
    _logger.info('push interaction handled: ${outcome.name}');
    return outcome;
  }

  Future<void> _awaitAuthoritativeState() async {
    final ready = _awaitReady;
    if (ready == null) return;
    try {
      await ready().timeout(_readinessTimeout);
    } on TimeoutException {
      // The router still fails closed without the ask, so a timeout is a
      // diagnostic rather than a decision.
      _logger.info('push interaction proceeded without a replayed ask');
    } catch (error) {
      _logger.fine('push interaction readiness failed: $error');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
