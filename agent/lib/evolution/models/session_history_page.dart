import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../core/models/message.dart';
import '../compaction/model_context_projection.dart';

const int defaultSessionHistoryPageSize = 100;
const int maxSessionHistoryPageSize = 200;
const int defaultSessionHistoryPageBytes = 1024 * 1024;

class SessionHistoryCursorFormatException implements Exception {
  final String message;

  const SessionHistoryCursorFormatException(this.message);

  @override
  String toString() => 'SessionHistoryCursorFormatException: $message';
}

class SessionHistoryCursorStaleException implements Exception {
  final String reason;

  const SessionHistoryCursorStaleException(this.reason);

  @override
  String toString() => 'SessionHistoryCursorStaleException: $reason';
}

class SessionHistoryAnchorNotFoundException implements Exception {
  const SessionHistoryAnchorNotFoundException();
}

class SessionHistoryRequest {
  final int limit;
  final String? cursor;
  final String? anchorEventId;

  const SessionHistoryRequest({
    this.limit = defaultSessionHistoryPageSize,
    this.cursor,
    this.anchorEventId,
  });

  factory SessionHistoryRequest.fromPayload(Map<String, dynamic> payload) {
    final rawLimit = payload['limit'];
    final limit = rawLimit == null
        ? defaultSessionHistoryPageSize
        : rawLimit is int
        ? rawLimit
        : throw const FormatException('history limit must be an integer');
    if (limit <= 0 || limit > maxSessionHistoryPageSize) {
      throw RangeError.range(limit, 1, maxSessionHistoryPageSize, 'limit');
    }
    final cursor = _optionalNonEmptyString(payload, 'cursor');
    final anchorEventId = _optionalNonEmptyString(payload, 'anchor_event_id');
    if (cursor != null && anchorEventId != null) {
      throw const FormatException(
        'history cursor and anchor_event_id are mutually exclusive',
      );
    }
    return SessionHistoryRequest(
      limit: limit,
      cursor: cursor,
      anchorEventId: anchorEventId,
    );
  }

  int? anchorRowIdForSession(String sessionId) {
    final eventId = anchorEventId;
    if (eventId == null) return null;
    final prefix = 'history:$sessionId:';
    if (!eventId.startsWith(prefix)) {
      throw const SessionHistoryAnchorNotFoundException();
    }
    final suffix = eventId.substring(prefix.length);
    final separator = suffix.indexOf(':');
    final rowId = int.tryParse(
      separator == -1 ? suffix : suffix.substring(0, separator),
    );
    if (rowId == null || rowId <= 0) {
      throw const SessionHistoryAnchorNotFoundException();
    }
    return rowId;
  }

  static String? _optionalNonEmptyString(
    Map<String, dynamic> payload,
    String key,
  ) {
    final raw = payload[key];
    if (raw == null) return null;
    if (raw is! String || raw.trim().isEmpty) {
      throw FormatException('history $key must be a non-empty string');
    }
    return raw.trim();
  }
}

class SessionHistoryCursor {
  static const int currentVersion = 1;

  final String sessionId;
  final int beforeRowId;
  final int historyRevision;
  final String boundaryFingerprint;

  const SessionHistoryCursor({
    required this.sessionId,
    required this.beforeRowId,
    required this.historyRevision,
    required this.boundaryFingerprint,
  });

  String encode() {
    final bytes = utf8.encode(
      jsonEncode({
        'v': currentVersion,
        's': sessionId,
        'b': beforeRowId,
        'r': historyRevision,
        'f': boundaryFingerprint,
      }),
    );
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static SessionHistoryCursor decode(String raw) {
    try {
      final normalized = raw.trim();
      if (normalized.isEmpty) {
        throw const SessionHistoryCursorFormatException('cursor is empty');
      }
      final padding = '=' * ((4 - normalized.length % 4) % 4);
      final value = jsonDecode(
        utf8.decode(base64Url.decode('$normalized$padding')),
      );
      if (value is! Map) {
        throw const SessionHistoryCursorFormatException(
          'cursor payload is not an object',
        );
      }
      final json = Map<String, dynamic>.from(value);
      if (json['v'] != currentVersion) {
        throw const SessionHistoryCursorFormatException(
          'cursor version is unsupported',
        );
      }
      final sessionId = json['s'];
      final beforeRowId = json['b'];
      final historyRevision = json['r'];
      final fingerprint = json['f'];
      if (sessionId is! String || sessionId.trim().isEmpty) {
        throw const SessionHistoryCursorFormatException(
          'cursor session is invalid',
        );
      }
      if (beforeRowId is! int || beforeRowId <= 0) {
        throw const SessionHistoryCursorFormatException(
          'cursor boundary is invalid',
        );
      }
      if (historyRevision is! int || historyRevision < 0) {
        throw const SessionHistoryCursorFormatException(
          'cursor revision is invalid',
        );
      }
      if (fingerprint is! String || fingerprint.length != 32) {
        throw const SessionHistoryCursorFormatException(
          'cursor fingerprint is invalid',
        );
      }
      return SessionHistoryCursor(
        sessionId: sessionId,
        beforeRowId: beforeRowId,
        historyRevision: historyRevision,
        boundaryFingerprint: fingerprint,
      );
    } on SessionHistoryCursorFormatException {
      rethrow;
    } on Object {
      throw const SessionHistoryCursorFormatException(
        'cursor encoding is invalid',
      );
    }
  }

  static String fingerprint(Message message) {
    final digest = sha256.convert(utf8.encode(jsonEncode(message.toJson())));
    return digest.toString().substring(0, 32);
  }
}

class SessionHistoryPage {
  final List<PersistedMessage> messages;
  final bool hasMore;
  final String? nextCursor;
  final int historyRevision;
  final int persistedBytes;

  const SessionHistoryPage({
    required this.messages,
    required this.hasMore,
    required this.nextCursor,
    required this.historyRevision,
    this.persistedBytes = 0,
  });
}
