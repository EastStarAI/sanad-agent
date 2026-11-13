import 'dart:collection';

import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';

/// The asks this Client has seen and has not yet seen resolved.
///
/// An action arriving from a notification must fail closed when the request it
/// answers is already gone. The authoritative in-app projection is the
/// conversation store, but that projection only exists while the conversation
/// surface is mounted, and a notification action is exactly the case where it
/// may not be. This registry is the Client's own bounded record of the asks its
/// event stream delivered, refreshed by the same replayed events a reconnect
/// re-delivers, so a late action can be rejected without asking a screen that
/// is not there.
class NotificationAskRegistry {
  NotificationAskRegistry({this.maxEntries = 128});

  /// Upper bound on remembered asks; the oldest is evicted first.
  final int maxEntries;

  final LinkedHashMap<String, DeviceSuspendedRequest> _asks = LinkedHashMap();

  /// Events that name a pending ask.
  static const String requestEvent = 'tool_permission_request';

  /// Events that end one ask.
  static const String resolvedEvent = 'tool_permission_resolved';

  /// Events that end every ask in a session.
  static const Set<String> terminalSessionEvents = <String>{'stopped'};

  /// Applies one canonical envelope.
  ///
  /// Returns the session whose ask ended, when this event ended one, so the
  /// caller can withdraw the OS notification it raised.
  String? observe(Map<String, dynamic> event) {
    final payload = event['payload'];
    final payloadMap = payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final eventType = _readString(event['event']) ?? _readString(payloadMap['type']);
    if (eventType == null) return null;

    final sessionId = _readString(event['session_id']) ?? _readString(payloadMap['session_id']);
    if (sessionId == null) return null;

    if (eventType == requestEvent) {
      final request = DeviceSuspendedRequest.fromJson(<String, dynamic>{
        ...payloadMap,
        'session_id': sessionId,
      });
      if (request.requestId.isEmpty) return null;
      _asks.remove(sessionId);
      _asks[sessionId] = request;
      while (_asks.length > maxEntries) {
        _asks.remove(_asks.keys.first);
      }
      return null;
    }

    if (eventType == resolvedEvent) {
      final requestId = _readString(event['request_id']) ??
          _readString(payloadMap['request_id']) ??
          _readString(payloadMap['id']);
      final current = _asks[sessionId];
      if (current == null) return null;
      if (requestId != null && requestId != current.requestId) return null;
      _asks.remove(sessionId);
      return sessionId;
    }

    if (terminalSessionEvents.contains(eventType)) {
      return _asks.remove(sessionId) == null ? null : sessionId;
    }

    return null;
  }

  /// The ask still pending for [sessionId], or `null`.
  DeviceSuspendedRequest? pendingFor(String sessionId) => _asks[sessionId];

  /// Whether [requestId] (or any ask when it is null) is still pending.
  bool isPending({required String sessionId, String? requestId}) {
    final ask = _asks[sessionId];
    if (ask == null) return false;
    if (requestId == null || requestId.isEmpty) return true;
    return ask.requestId == requestId;
  }

  void clear() => _asks.clear();

  int get size => _asks.length;

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
