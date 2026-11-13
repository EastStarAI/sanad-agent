/// Plan 174 — the Agent's notification dispatcher.
///
/// One owner decides, per ask: which step dispatches now, whether an escalation
/// timer is armed, when it fires, and when the notification is withdrawn.
///
/// Guarantees this class exists to keep:
/// - one timer per ask, keyed by `session_id + request_id`;
/// - no dispatch after resolution, even if a late creation arrives;
/// - no escalation after a withdrawal;
/// - a withdrawn notification is withdrawn everywhere it went;
/// - a sink failure never reaches the permission flow that raised the ask.
library;

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../models/delivery/models.dart';
import '../platforms/sanad_gateway/protocol/canonical_events.dart';
import 'client_instance_profiles.dart';
import 'notification_ask.dart';
import 'notification_copy.dart';
import 'notification_payload.dart';
import 'notification_policy.dart';
import 'notification_presence.dart';

/// One canonical instruction the transport must publish.
final class NotificationInstructionMessage {
  const NotificationInstructionMessage({
    required this.eventType,
    required this.sessionId,
    required this.payload,
  });

  /// Canonical event type: dispatch or withdrawal.
  final String eventType;
  final String sessionId;
  final Map<String, dynamic> payload;
}

/// Publishes one instruction through the Agent's canonical delivery path.
typedef NotificationInstructionSink =
    void Function(NotificationInstructionMessage instruction);

/// A cancellable delay, so a test can own time instead of waiting for it.
abstract interface class NotificationTimer {
  void cancel();
}

/// Creates the escalation timer.
typedef NotificationTimerFactory =
    NotificationTimer Function(Duration delay, void Function() onFire);

/// The production timer.
class SystemNotificationTimer implements NotificationTimer {
  SystemNotificationTimer(Duration delay, void Function() onFire)
    : _timer = Timer(delay, onFire);

  final Timer _timer;

  @override
  void cancel() {
    if (_timer.isActive) _timer.cancel();
  }
}

class NotificationDispatcher {
  NotificationDispatcher({
    required NotificationInstructionSink sink,
    required NotificationTargetPresence presence,
    required ClientInstanceProfiles profiles,
    NotificationPayloadComposer composer = const NotificationPayloadComposer(),
    NotificationTimerFactory timerFactory = SystemNotificationTimer.new,
    DateTime Function() now = DateTime.now,
    String? Function(String sessionId)? sessionTitle,
    this.escalationDelay = defaultEscalationDelay,
    this.retiredAskCapacity = 256,
  }) : _sink = sink,
       _policy = NotificationDispatchPolicy(presence),
       _profiles = profiles,
       _composer = composer,
       _timerFactory = timerFactory,
       _now = now,
       _sessionTitle = sessionTitle;

  /// The escalation window. An unresolved ask nobody acted on reaches every
  /// push-capable device of the account after this delay.
  static const defaultEscalationDelay = Duration(seconds: 90);

  static final Logger _logger = Logger('NotificationDispatcher');

  final NotificationInstructionSink _sink;
  final NotificationDispatchPolicy _policy;
  final ClientInstanceProfiles _profiles;
  final NotificationPayloadComposer _composer;
  final NotificationTimerFactory _timerFactory;
  final DateTime Function() _now;
  final String? Function(String sessionId)? _sessionTitle;

  final Duration escalationDelay;

  /// How many resolved asks are remembered so a late creation cannot re-notify.
  final int retiredAskCapacity;

  final Map<String, _PendingAsk> _pending = {};
  final Map<String, String> _retired = {};

  /// How many asks are currently tracked.
  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Whether the escalation timer of [sessionId]/[requestId] is armed.
  @visibleForTesting
  bool isEscalationArmed({
    required String sessionId,
    required String requestId,
  }) {
    final pending = _pending[_key(sessionId, requestId)];
    return pending?.timer != null;
  }

  /// Registers one ask and dispatches its first step.
  ///
  /// Duplicate creation for the same ask is a no-op, and an ask whose key is
  /// already resolved is ignored: no notification follows a resolution.
  void onAskCreated({required NotificationAsk ask, OriginContext? origin}) {
    if (!ask.kind.isAgentOwned) {
      _logger.warning(
        'Ignoring a notification ask for a Client-owned kind: ${ask.kind}',
      );
      return;
    }
    final key = _key(ask.sessionId, ask.requestId);
    if (_retired.containsKey(key) || _pending.containsKey(key)) return;

    try {
      final titledAsk = ask.sessionTitle == null
          ? ask.withSessionTitle(_sessionTitle?.call(ask.sessionId))
          : ask;
      final resolvedOrigin = _originFor(origin);
      final plan = _policy.plan(resolvedOrigin);
      final locale = _profiles.localeFor(resolvedOrigin?.clientInstanceId);
      final pending = _PendingAsk(
        ask: titledAsk,
        locale: locale,
        accountWide: !plan.armEscalation,
      );
      _pending[key] = pending;
      _publishDispatch(pending, plan.step, plan.target);
      if (!plan.armEscalation) return;
      pending.timer = _timerFactory(escalationDelay, () => _escalate(key));
    } on Object catch (error) {
      // A notification never fails the ask it describes.
      _pending.remove(key);
      _logger.warning('Notification dispatch failed: ${error.runtimeType}');
    }
  }

  /// Cancels the timer and withdraws the notification after a resolution.
  void onAskResolved({
    required String sessionId,
    required String requestId,
    required String reason,
  }) {
    final key = _key(sessionId, requestId);
    final pending = _pending.remove(key);
    _retire(key);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.timer = null;
    _publishWithdraw(pending, reason);
  }

  /// Cancels every tracked ask of a session that reached a terminal state.
  void onSessionTerminal(String sessionId) {
    final keys = [
      for (final entry in _pending.entries)
        if (entry.value.ask.sessionId == sessionId) entry.key,
    ];
    for (final key in keys) {
      final pending = _pending.remove(key)!;
      _retire(key);
      pending.timer?.cancel();
      pending.timer = null;
      _publishWithdraw(pending, NotificationWithdrawReason.sessionTerminal);
    }
  }

  /// Cancels every timer and withdraws everything still tracked.
  Future<void> dispose() async {
    final pending = _pending.values.toList(growable: false);
    _pending.clear();
    for (final entry in pending) {
      entry.timer?.cancel();
      entry.timer = null;
      _publishWithdraw(entry, NotificationWithdrawReason.disposed);
    }
  }

  /// Rebuilds the policy origin from the delivery envelope the run captured.
  ///
  /// The captured origin of a turn is the only place that knows which Client
  /// instance raised it; a missing, external, or non-notifiable origin is a
  /// supported state, not an error.
  NotificationOrigin? _originFor(OriginContext? origin) {
    if (origin == null) return null;
    return NotificationOrigin(
      platformFamily: origin.platformFamily,
      clientInstanceId: origin.clientInstanceId,
      canNotify: _profiles.canNotify(origin.clientInstanceId),
    );
  }

  void _escalate(String key) {
    final pending = _pending[key];
    if (pending == null) return;
    pending.timer = null;
    if (pending.accountWide) return;
    pending.accountWide = true;
    _publishDispatch(
      pending,
      NotificationDispatchStep.escalation,
      NotificationTarget.account,
    );
  }

  void _publishDispatch(
    _PendingAsk pending,
    NotificationDispatchStep step,
    NotificationTarget target,
  ) {
    final dispatchedAt = _now();
    final payload = _composer.composeDispatch(
      ask: pending.ask,
      locale: pending.locale,
      target: target,
      step: step,
      dispatchedAt: dispatchedAt,
    );
    _publish(
      NotificationInstructionMessage(
        eventType: CanonicalEventTypes.notificationDispatch,
        sessionId: pending.ask.sessionId,
        payload: payload,
      ),
    );
  }

  void _publishWithdraw(_PendingAsk pending, String reason) {
    final payload = _composer.composeWithdraw(
      ask: pending.ask,
      reason: reason,
      withdrawnAt: _now(),
    );
    _publish(
      NotificationInstructionMessage(
        eventType: CanonicalEventTypes.notificationWithdraw,
        sessionId: pending.ask.sessionId,
        payload: payload,
      ),
    );
  }

  void _publish(NotificationInstructionMessage instruction) {
    try {
      _sink(instruction);
    } on Object catch (error) {
      _logger.warning(
        'Notification sink rejected ${instruction.eventType}: '
        '${error.runtimeType}',
      );
    }
  }

  void _retire(String key) {
    _retired.remove(key);
    _retired[key] = key;
    while (_retired.length > retiredAskCapacity) {
      _retired.remove(_retired.keys.first);
    }
  }

  static String _key(String sessionId, String requestId) =>
      '$sessionId\u0000$requestId';
}

final class _PendingAsk {
  _PendingAsk({
    required this.ask,
    required this.locale,
    required this.accountWide,
  });

  final NotificationAsk ask;
  final NotificationLocale locale;

  /// Whether the ask has already reached the whole account, so the timer must
  /// never dispatch a second time.
  bool accountWide;

  NotificationTimer? timer;
}
