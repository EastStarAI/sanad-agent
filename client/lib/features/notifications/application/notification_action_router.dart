import 'package:logging/logging.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';

/// What happened to a notification interaction.
enum NotificationActionOutcome {
  /// The session surface was opened (plain click, or an action this build
  /// cannot name).
  opened,

  /// The approval was sent to the Agent through the existing command path.
  responded,

  /// The request was already resolved (or is no longer known), so nothing was
  /// sent.
  stale,

  /// The interaction named something this Client must not act on.
  dropped,
}

/// Routes a notification interaction to the existing conversation surfaces.
///
/// Two laws hold here:
/// - An approval is sent only through the existing `tool_permission_response`
///   command, with the request the Client already holds; the notification never
///   constructs a decision from its own payload alone.
/// - Nothing is mutated optimistically. A response changes no Client state; the
///   in-app prompt clears from the Agent's resolved event, exactly as it does
///   when the user answers in the app.
class NotificationActionRouter {
  NotificationActionRouter({
    required DeviceSuspendedRequest? Function(String sessionId) readPendingAsk,
    required Future<void> Function(NotificationPayload payload) openSession,
    required Future<void> Function(
      DeviceSuspendedRequest request,
      NotificationActionIntent intent,
      NotificationPayload payload,
    ) respondToAsk,
    DateTime Function()? clock,
  })  : _readPendingAsk = readPendingAsk,
        _openSession = openSession,
        _respondToAsk = respondToAsk,
        _clock = clock ?? DateTime.now;

  final DeviceSuspendedRequest? Function(String sessionId) _readPendingAsk;
  final Future<void> Function(NotificationPayload payload) _openSession;
  final Future<void> Function(
    DeviceSuspendedRequest request,
    NotificationActionIntent intent,
    NotificationPayload payload,
  ) _respondToAsk;
  final DateTime Function() _clock;

  static final Logger _logger = Logger('notifications.actions');

  Future<NotificationActionOutcome> handle(
    NotificationPayload payload,
    String? actionId,
  ) async {
    if (payload.isExpiredAt(_clock())) {
      _logger.info('dropped a notification action for an expired ask');
      return NotificationActionOutcome.stale;
    }

    // A platform may report the payload itself instead of an action id. An
    // action this build cannot name is never forwarded as a decision; it opens
    // the session, where the user answers with full context.
    final intent = NotificationAction.intentForWireId(actionId) ??
        NotificationActionIntent.open;

    if (intent == NotificationActionIntent.open) {
      await _openSession(payload);
      return NotificationActionOutcome.opened;
    }

    if (!payload.kind.supportsApprovalActions) {
      _logger.info('dropped an approval action for a non-approval kind');
      return NotificationActionOutcome.dropped;
    }

    final pending = _readPendingAsk(payload.sessionId);
    if (pending == null) {
      _logger.info('dropped a notification approval: the ask is no longer pending');
      return NotificationActionOutcome.stale;
    }
    final requestId = payload.requestId;
    if (requestId != null && requestId.isNotEmpty && pending.requestId != requestId) {
      _logger.info('dropped a notification approval: the pending ask is a different request');
      return NotificationActionOutcome.stale;
    }

    // The payload carries the identity of the agent that raised the ask, so the
    // responder addresses that agent rather than guessing from the active one.
    await _respondToAsk(pending, intent, payload);
    return NotificationActionOutcome.responded;
  }
}
