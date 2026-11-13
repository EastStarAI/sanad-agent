import 'package:equatable/equatable.dart';

import 'notification_action.dart';
import 'notification_collapse_key.dart';
import 'notification_deep_link.dart';
import 'notification_kind.dart';
import 'notification_urgency.dart';

/// One Agent-owned notification, parsed from a canonical `device_event`.
///
/// The Agent renders the copy; the Client never invents a title from
/// conversation content it happens to hold. [title] or [body] may be empty when
/// a producer has not filled them, and the display pipeline then supplies the
/// localized copy for the kind instead of showing a blank banner.
///
/// Parsing is total and additive: an unknown field is ignored, but a payload
/// without a recognizable kind or session is rejected so that nothing is
/// displayed without an identity to deduplicate, collapse, and open.
class NotificationPayload extends Equatable {
  const NotificationPayload({
    required this.eventId,
    required this.kind,
    required this.urgency,
    required this.deepLink,
    required this.collapseKey,
    required this.notificationId,
    this.title = '',
    this.body = '',
    this.actions = const <NotificationAction>[],
    this.deviceId,
    this.hardwareId,
    this.expiresAt,
  });

  /// Canonical `event_id` minted once by the Agent and preserved across the
  /// local and cloud copies. Dedupe is by this value alone.
  final String eventId;

  final NotificationKind kind;
  final NotificationUrgency urgency;
  final NotificationDeepLink deepLink;

  /// Derived from `session_id + kind`; see [NotificationCollapseKey].
  final String collapseKey;

  /// The stable OS notification id for [collapseKey].
  final int notificationId;

  /// Agent-rendered, redacted copy. Empty means "use the Client fallback".
  final String title;
  final String body;

  /// Actions the Agent offered, already localized by the Agent.
  final List<NotificationAction> actions;

  /// Envelope identity of the Agent that raised the event, when present.
  final String? deviceId;
  final String? hardwareId;

  /// A notification that outlived this instant must not be raised.
  final DateTime? expiresAt;

  /// The event names this Client treats as a notification dispatch.
  static const Set<String> eventNames = <String>{
    'notification',
    'notification_dispatch',
  };

  String get sessionId => deepLink.sessionId;
  String? get requestId => deepLink.requestId;

  bool isExpiredAt(DateTime now) {
    final expiry = expiresAt;
    return expiry != null && !expiry.isAfter(now);
  }

  /// Parses a canonical envelope, or `null` when the event is not a
  /// notification this Client can act on.
  static NotificationPayload? fromEvent(Map<String, dynamic> event) {
    final eventName = _readString(event['event']);
    if (!eventNames.contains(eventName)) return null;

    final payload = event['payload'];
    final payloadMap = payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final block = _notificationBlock(payloadMap);

    final kind = NotificationKind.fromWire(
      block['kind'] ?? block['notification_kind'] ?? payloadMap['kind'],
    );
    if (kind == null) return null;

    final deepLinkMap = block['deep_link'];
    final deepLink = deepLinkMap is Map
        ? Map<String, dynamic>.from(deepLinkMap)
        : const <String, dynamic>{};
    final sessionId = _firstNonEmpty(<Object?>[
      deepLink['session_id'],
      block['session_id'],
      event['session_id'],
      payloadMap['session_id'],
    ]);
    if (sessionId == null) return null;

    final requestId = _firstNonEmpty(<Object?>[
      deepLink['request_id'],
      block['request_id'],
      event['request_id'],
      payloadMap['request_id'],
    ]);

    final agentCollapseKey = _readString(block['collapse_key']);
    final collapseKey = NotificationCollapseKey.agreesWith(
      candidate: agentCollapseKey,
      sessionId: sessionId,
      kind: kind,
    )
        ? agentCollapseKey!
        : NotificationCollapseKey.forAsk(sessionId: sessionId, kind: kind);

    return NotificationPayload(
      eventId: _readString(event['event_id']) ?? '',
      kind: kind,
      urgency: NotificationUrgency.fromWire(block['urgency']),
      deepLink: NotificationDeepLink(sessionId: sessionId, requestId: requestId),
      collapseKey: collapseKey,
      notificationId: NotificationCollapseKey.notificationId(collapseKey),
      title: _readString(block['title']) ?? '',
      body: _readString(block['body']) ?? '',
      actions: _parseActions(block['actions'], kind: kind),
      deviceId: _firstNonEmpty(<Object?>[event['device_id'], block['device_id']]),
      hardwareId: _firstNonEmpty(<Object?>[event['hardware_id'], block['hardware_id']]),
      expiresAt: _parseTimestamp(block['expires_at']),
    );
  }

  /// Supports both a flat payload and an explicit `notification` block, so a
  /// producer can attach the notification to an existing event without
  /// changing every sibling field.
  static Map<String, dynamic> _notificationBlock(Map<String, dynamic> payload) {
    final nested = payload['notification'];
    if (nested is Map) return Map<String, dynamic>.from(nested);
    return payload;
  }

  static List<NotificationAction> _parseActions(Object? raw, {required NotificationKind kind}) {
    final parsed = <NotificationAction>[];
    if (raw is Iterable) {
      for (final entry in raw) {
        if (entry is String) {
          final intent = NotificationAction.intentForWireId(entry);
          if (intent == null) continue;
          parsed.add(NotificationAction(id: entry.trim(), intent: intent));
          continue;
        }
        if (entry is Map) {
          final id = _readString(entry['id']);
          final intent = NotificationAction.intentForWireId(id);
          if (id == null || intent == null) continue;
          parsed.add(
            NotificationAction(id: id, intent: intent, label: _readString(entry['label'])),
          );
        }
      }
    }
    if (parsed.isNotEmpty) return List<NotificationAction>.unmodifiable(parsed);
    if (kind.supportsApprovalActions) {
      return NotificationAction.approvalActions;
    }
    return const <NotificationAction>[];
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _firstNonEmpty(Iterable<Object?> values) {
    for (final value in values) {
      final read = _readString(value);
      if (read != null) return read;
    }
    return null;
  }

  /// Accepts an ISO-8601 string or an epoch timestamp in seconds or
  /// milliseconds. A value this build cannot read yields `null` rather than an
  /// expiry in the past, because dropping a live ask is worse than showing it.
  static DateTime? _parseTimestamp(Object? value) {
    if (value is int) {
      final millis = value > 100000000000 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
    if (value is String) {
      return DateTime.tryParse(value.trim())?.toUtc();
    }
    return null;
  }

  /// The opaque string stored in a presented notification and echoed back when
  /// the user interacts with it.
  ///
  /// It carries only what opening the surface needs: identity, the copy the
  /// platform already shows, and the expiry that makes a late interaction fail
  /// closed. No transcript, command text, or credential is ever included.
  Map<String, dynamic> toPresentationPayload() => <String, dynamic>{
        'v': 1,
        'event_id': eventId,
        'kind': kind.wire,
        'urgency': urgency.wire,
        'session_id': sessionId,
        if (requestId != null) 'request_id': requestId,
        'collapse_key': collapseKey,
        'title': title,
        'body': body,
        if (deviceId != null) 'device_id': deviceId,
        if (hardwareId != null) 'hardware_id': hardwareId,
        if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
        'actions': <Map<String, dynamic>>[
          for (final action in actions)
            <String, dynamic>{
              'id': action.id,
              if (action.label != null) 'label': action.label,
            },
        ],
      };

  /// Rebuilds the payload a presented notification returns.
  ///
  /// Anything unreadable yields `null` so an interaction with a stale or
  /// corrupted payload is dropped instead of guessing a session or a decision.
  static NotificationPayload? fromPresentationPayload(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final kind = NotificationKind.fromWire(map['kind']);
    final sessionId = _readString(map['session_id']);
    if (kind == null || sessionId == null) return null;
    final requestId = _readString(map['request_id']);
    final collapseKey = _readString(map['collapse_key']) ??
        NotificationCollapseKey.forAsk(sessionId: sessionId, kind: kind);
    return NotificationPayload(
      eventId: _readString(map['event_id']) ?? '',
      kind: kind,
      urgency: NotificationUrgency.fromWire(map['urgency']),
      deepLink: NotificationDeepLink(sessionId: sessionId, requestId: requestId),
      collapseKey: collapseKey,
      notificationId: NotificationCollapseKey.notificationId(collapseKey),
      title: _readString(map['title']) ?? '',
      body: _readString(map['body']) ?? '',
      actions: _parseActions(map['actions'], kind: kind),
      deviceId: _readString(map['device_id']),
      hardwareId: _readString(map['hardware_id']),
      expiresAt: _parseTimestamp(map['expires_at']),
    );
  }

  @override
  List<Object?> get props => [
        eventId,
        kind,
        urgency,
        deepLink,
        collapseKey,
        notificationId,
        title,
        body,
        actions,
        deviceId,
        hardwareId,
        expiresAt,
      ];
}
