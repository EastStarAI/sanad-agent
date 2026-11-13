import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_collapse_key.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_ask_registry.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';
import 'package:sanad_client/infrastructure/socket/event_deduplicator.dart';

/// What the Client did with a platform interaction that arrived before it had
/// any in-memory state — that is, the interaction whose launch started this
/// process.
///
/// A cold start has no replayed ask and no mounted conversation surface, so the
/// payload alone is the only input an answer could be built from. That is exactly
/// a decision the Agent did not make, so the Client records the interaction and
/// acts on nothing.
enum NotificationColdStartOutcome {
  /// No notification interaction started this process.
  none,

  /// An interaction arrived, was understood, and was deliberately not acted on.
  dropped,

  /// An interaction arrived with a payload this build cannot read.
  unreadable,
}

/// The one local path from an Agent notification event to an OS notification.
///
/// Both transports feed the same instance: the local socket and the cloud
/// socket are two copies of one event stream, and nothing here selects between
/// them. The service decides, and every input of that decision is injected, so
/// the matrix is testable without a socket, a window, or an operating system.
class NotificationService {
  NotificationService({
    required NotificationPlatformAdapter adapter,
    required List<Stream<Map<String, dynamic>>> eventStreams,
    required NotificationCopyResolver copyResolver,
    required NotificationPreferences Function() readPreferences,
    required NotificationPermissionStatus Function() readPermission,
    required NotificationPresence Function() readPresence,
    required NotificationActionRouter actionRouter,
    Map<NotificationActionIntent, String> Function()? readApprovalActionLabels,
    NotificationAskRegistry? askRegistry,
    NotificationQuietWindow? quietWindow,
    EventDeduplicator? deduplicator,
    DateTime Function()? clock,
  })  : _adapter = adapter,
        _eventStreams = eventStreams,
        _copyResolver = copyResolver,
        _readPreferences = readPreferences,
        _readPermission = readPermission,
        _readPresence = readPresence,
        _actionRouter = actionRouter,
        _readApprovalActionLabels = readApprovalActionLabels ?? _noApprovalLabels,
        _askRegistry = askRegistry ?? NotificationAskRegistry(),
        _quietWindow = quietWindow ?? NotificationQuietWindow(),
        _deduplicator = deduplicator ?? EventDeduplicator(maxEntries: 512),
        _clock = clock ?? DateTime.now;

  static Map<NotificationActionIntent, String> _noApprovalLabels() =>
      const <NotificationActionIntent, String>{};


  final NotificationPlatformAdapter _adapter;
  final List<Stream<Map<String, dynamic>>> _eventStreams;
  final NotificationCopyResolver _copyResolver;
  final NotificationPreferences Function() _readPreferences;
  final NotificationPermissionStatus Function() _readPermission;
  final NotificationPresence Function() _readPresence;
  final NotificationActionRouter _actionRouter;
  final Map<NotificationActionIntent, String> Function() _readApprovalActionLabels;
  final NotificationAskRegistry _askRegistry;
  final NotificationQuietWindow _quietWindow;

  /// Dedupe is by canonical `event_id` alone.
  ///
  /// The transport-shared [EventDeduplicator] keys on `event_id` plus a payload
  /// fingerprint, so it cannot prove that two route copies are one
  /// notification; this instance is called without a payload, which reduces the
  /// key to the event id and makes both routes collapse to one sighting.
  final EventDeduplicator _deduplicator;

  final DateTime Function() _clock;
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  final Set<String> _presented = <String>{};

  bool _started = false;
  bool _disposed = false;
  NotificationColdStartOutcome _coldStartOutcome = NotificationColdStartOutcome.none;

  static final Logger _logger = Logger('notifications');

  /// Whether the current platform can raise an OS notification at all.
  bool get isSupported => _adapter.isSupported;

  int get presentedCount => _presented.length;

  /// The outcome of the interaction that started this process, for diagnostics
  /// and tests. It is never a decision: [NotificationColdStartOutcome.dropped]
  /// and [NotificationColdStartOutcome.unreadable] both mean nothing was sent
  /// and no Client state changed.
  NotificationColdStartOutcome get coldStartOutcome => _coldStartOutcome;

  /// Prepares the platform channel and starts consuming both transports.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      await _adapter.initialize(
        onResponse: (response) => unawaited(_onPlatformResponse(response)),
        approvalActionLabels: _readApprovalActionLabels(),
      );
    } catch (error, stack) {
      _logger.warning('notification platform initialization failed', error, stack);
    }
    for (final stream in _eventStreams) {
      _subscriptions.add(stream.listen(
        (event) => unawaited(handleEvent(event)),
        onError: (Object error) => _logger.warning('notification event stream error', error),
      ));
    }
    _coldStartOutcome = await _adoptColdStartInteraction();
    _logger.info(
      'notification service started '
      '(supported=${_adapter.isSupported} permission=${_readPermission().name} '
      'coldStart=${_coldStartOutcome.name})',
    );
  }

  /// Records the interaction that launched this process and acts on nothing.
  ///
  /// A launch interaction reaches a Client with no replayed ask state and no
  /// routed conversation surface, so answering it would build a
  /// `tool_permission_response` from the notification payload alone, and opening
  /// it would navigate with no resolved destination. The Client therefore fails
  /// closed: nothing is sent, no state is mutated, and the pending ask (when the
  /// Agent still holds one) arrives through the ordinary reconnect replay, where
  /// the user answers it in the app with full context.
  Future<NotificationColdStartOutcome> _adoptColdStartInteraction() async {
    final NotificationPlatformResponse? launch;
    try {
      launch = await _adapter.readLaunchResponse();
    } catch (error, stack) {
      _logger.warning('could not read a cold-start notification interaction', error, stack);
      return NotificationColdStartOutcome.none;
    }
    if (launch == null) return NotificationColdStartOutcome.none;
    final payload = _decode(launch.payload);
    if (payload == null) {
      _logger.warning('dropped a cold-start notification interaction with an unreadable payload');
      return NotificationColdStartOutcome.unreadable;
    }
    _logger.info(
      'dropped a cold-start notification interaction '
      '(kind=${payload.kind.wire} intent=${_actionIdOf(launch, payload) ?? 'open'})',
    );
    return NotificationColdStartOutcome.dropped;
  }

  /// Arms the quiet window. Called on every local or cloud connect, because a
  /// reconnect replays parked state that must reach the app without becoming a
  /// new interruption.
  void onTransportConnected() {
    if (_disposed || !_adapter.isSupported) return;
    _quietWindow.arm();
    _logger.fine('notification quiet window armed for ${_quietWindow.duration.inSeconds}s');
  }

  /// Applies one canonical envelope.
  ///
  /// Returns the display decision, or `null` when the event is not a
  /// notification this Client understands.
  Future<NotificationDisplayDecision?> handleEvent(Map<String, dynamic> event) async {
    if (_disposed) return null;

    final resolvedSessionId = _askRegistry.observe(event);
    if (resolvedSessionId != null) {
      await _withdrawAsk(resolvedSessionId);
    }

    final payload = NotificationPayload.fromEvent(event);
    if (payload == null) return null;

    final duplicate = !_deduplicator.shouldProcess(payload.eventId, transport: 'notification');
    final decision = NotificationDisplayPolicy.decide(
      payload: payload,
      alreadyProcessed: duplicate,
      preferences: _readPreferences(),
      permission: _readPermission(),
      quietWindowOpen: _quietWindow.isOpen,
      presence: _readPresence(),
      now: _clock(),
      platformSupported: _adapter.isSupported,
    );

    if (decision.shouldDisplay) {
      await _display(payload);
    } else {
      _logger.fine('notification not raised: ${decision.reason}');
    }
    return decision;
  }

  Future<void> _display(NotificationPayload payload) async {
    final copy = _copyResolver(payload.kind);
    final actions = <NotificationPresentationAction>[];
    if (_adapter.supportsApprovalActions) {
      for (final action in payload.actions) {
        final label = copy.labelFor(action);
        if (label == null) continue;
        actions.add(NotificationPresentationAction(id: action.id, label: label));
      }
    }
    final request = NotificationPresentationRequest(
      id: payload.notificationId,
      title: payload.title.isNotEmpty ? payload.title : copy.title,
      body: payload.body.isNotEmpty ? payload.body : copy.body,
      urgency: payload.urgency,
      payload: jsonEncode(payload.toPresentationPayload()),
      actions: actions,
      offersApprovalActions: payload.kind.supportsApprovalActions,
      threadId: payload.sessionId,
    );
    try {
      await _adapter.show(request);
      _presented.add(payload.collapseKey);
      _logger.info('raised ${payload.kind.wire} notification');
    } catch (error, stack) {
      _logger.warning('could not raise ${payload.kind.wire} notification', error, stack);
    }
  }

  /// Withdraws the ask notification of [sessionId] once the ask is resolved.
  ///
  /// A platform without package identity (unpackaged Windows) cannot cancel a
  /// presented toast; the call is still made so a packaged build withdraws it,
  /// and the stale interaction is rejected separately.
  Future<void> _withdrawAsk(String sessionId) async {
    final key = NotificationCollapseKey.forAsk(
      sessionId: sessionId,
      kind: NotificationKind.permissionRequest,
    );
    if (!_presented.remove(key)) return;
    try {
      await _adapter.cancel(NotificationCollapseKey.notificationId(key));
      _logger.fine('withdrew resolved ask notification');
    } catch (error) {
      _logger.fine('could not withdraw resolved ask notification: $error');
    }
  }

  Future<void> _onPlatformResponse(NotificationPlatformResponse response) async {
    final decoded = _decode(response.payload);
    if (decoded == null) {
      _logger.warning('dropped a notification interaction with an unreadable payload');
      return;
    }
    final outcome = await _actionRouter.handle(decoded, _actionIdOf(response, decoded));
    _logger.info('notification interaction handled: ${outcome.name}');
  }

  /// Recovers the action identity from the platform response.
  ///
  /// Some platforms report the payload itself in the action field, and some
  /// report the pressed button in a data entry instead. Anything unrecognized
  /// resolves to `null`, which the router treats as a plain open, so an
  /// unreadable action can never become a decision.
  String? _actionIdOf(NotificationPlatformResponse response, NotificationPayload payload) {
    final actionId = response.actionId;
    if (actionId != null && NotificationAction.intentForWireId(actionId) != null) {
      return actionId;
    }
    final offered = <String>{for (final action in payload.actions) action.id};
    for (final value in response.data.values) {
      if (offered.contains(value)) return value;
    }
    return null;
  }

  NotificationPayload? _decode(String raw) {
    if (raw.isEmpty) return null;
    try {
      return NotificationPayload.fromPresentationPayload(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  /// Forgets every rendered notification and stops consuming events.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _presented.clear();
    _askRegistry.clear();
    _quietWindow.clear();
  }
}
