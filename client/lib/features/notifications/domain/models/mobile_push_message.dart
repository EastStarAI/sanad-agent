import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';

/// One push message as the operating system handed it to this Client.
///
/// A push is only a wake-up: it carries the same canonical notification payload
/// the socket would deliver, and nothing here decides whether it is shown. The
/// message rebuilds a canonical `device_event` from the provider data so that
/// [NotificationPayload.fromEvent] stays the single parser for every transport;
/// a second parser would drift from the socket path.
///
/// The payload is complete on its own, which is what lets a terminated Client
/// act on a notification without a socket: [payload] resolves the kind, the
/// deep link, the copy, the actions, and the expiry from the message alone.
class MobilePushMessage extends Equatable {
  const MobilePushMessage({required this.data});

  /// Reads a message from the flattened provider data map.
  ///
  /// The relay sends the canonical envelope as one JSON string under
  /// [envelopeKey]. The flat keys are accepted as a fallback so a provider that
  /// flattens a payload still produces a usable message instead of nothing.
  factory MobilePushMessage.fromData(Map<String, Object?> data) {
    return MobilePushMessage(
      data: <String, String>{
        for (final entry in data.entries)
          if (entry.key.trim().isNotEmpty && entry.value != null)
            entry.key.trim(): entry.value.toString(),
      },
    );
  }

  /// Decodes the JSON string a platform channel delivered.
  ///
  /// Anything unreadable yields `null`, because a message this build cannot
  /// parse must not become a notification with a guessed identity.
  static MobilePushMessage? decode(Object? raw) {
    if (raw is Map) return MobilePushMessage.fromData(Map<String, Object?>.from(raw));
    if (raw is! String || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return MobilePushMessage.fromData(Map<String, Object?>.from(decoded));
    } on FormatException {
      return null;
    }
  }

  /// The key that carries the canonical envelope as JSON.
  static const String envelopeKey = 'sanad_envelope';

  /// The action the user pressed, when this message reports an interaction.
  static const String actionKey = 'action_id';

  final Map<String, String> data;

  /// The action the user pressed, or `null` for a display message.
  String? get actionId {
    final value = data[actionKey]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// Whether this message reports an interaction rather than an arrival.
  bool get isInteraction => actionId != null;

  /// The canonical `event_id` of the notification identity, or `null`.
  String? get eventId {
    final envelope = _envelope;
    final value = envelope?['event_id'] ?? data['event_id'] ?? data['eventId'];
    final trimmed = value?.toString().trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// The canonical envelope this message represents, rebuilt from the provider
  /// data. Returns `null` when the message names no kind or no session, which
  /// the parser would reject anyway.
  Map<String, dynamic>? get canonicalEvent {
    final envelope = _envelope;
    if (envelope != null) {
      final normalized = <String, dynamic>{...envelope};
      normalized['event'] ??= data['event'] ?? 'notification';
      return normalized;
    }

    final kind = data['kind'] ?? data['notification_kind'];
    final sessionId = data['session_id'] ?? data['sessionId'];
    final eventName = data['event'];
    if (kind == null || kind.trim().isEmpty) return null;
    if (sessionId == null || sessionId.trim().isEmpty) return null;

    final requestId = data['request_id'] ?? data['requestId'];
    final eventKind = kind.trim();
    return <String, dynamic>{
      'event': eventName == null || eventName.trim().isEmpty ? 'notification' : eventName.trim(),
      if (data['event_id'] != null) 'event_id': data['event_id'],
      'session_id': sessionId,
      if (requestId != null) 'request_id': requestId,
      if (data['device_id'] != null) 'device_id': data['device_id'],
      if (data['hardware_id'] != null) 'hardware_id': data['hardware_id'],
      'payload': <String, dynamic>{
        'notification': <String, dynamic>{
          'kind': eventKind,
          if (data['urgency'] != null) 'urgency': data['urgency'],
          if (data['title'] != null) 'title': data['title'],
          if (data['body'] != null) 'body': data['body'],
          if (data['collapse_key'] != null) 'collapse_key': data['collapse_key'],
          if (data['expires_at'] != null) 'expires_at': data['expires_at'],
          if (data['actions'] != null) 'actions': _decodeActions(data['actions']!),
          'deep_link': <String, dynamic>{
            'session_id': sessionId.trim(),
            if (requestId != null) 'request_id': requestId,
          },
        },
      },
    };
  }

  /// The parsed notification, or `null` when this message is not one this
  /// build understands.
  NotificationPayload? get payload {
    final event = canonicalEvent;
    if (event == null) return null;
    return NotificationPayload.fromEvent(event);
  }

  /// Whether this message is past its own expiry.
  bool isExpiredAt(DateTime now) => payload?.isExpiredAt(now) ?? true;

  Map<String, dynamic>? get _envelope {
    final raw = data[envelopeKey];
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Map<String, dynamic>.from(decoded);
    } on FormatException {
      return null;
    }
  }

  /// Accepts the action set as a JSON array of ids or of `{id, label}` objects,
  /// matching the payload contract the socket path already parses.
  static Object? _decodeActions(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('[')) return raw.split(',').map((value) => value.trim()).toList(growable: false);
    try {
      final decoded = jsonDecode(trimmed);
      return decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'MobilePushMessage(${data.keys.join(',')})';

  @override
  List<Object?> get props => [data];
}
