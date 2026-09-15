import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'session_state.dart';

class SessionSearchRequest {
  static const int defaultLimit = 20;
  static const int maxLimit = 50;
  static const int maxQueryLength = 500;
  static const int maxSnippetLength = 200;

  final String query;
  final int limit;
  final String? cursor;

  SessionSearchRequest({
    required String query,
    this.limit = defaultLimit,
    this.cursor,
  }) : query = normalize(query) {
    if (this.query.isEmpty) throw ArgumentError('query must not be empty.');
    if (this.query.length > maxQueryLength) {
      throw ArgumentError('query must be at most $maxQueryLength characters.');
    }
    if (limit <= 0 || limit > maxLimit) {
      throw ArgumentError('limit must be between 1 and $maxLimit.');
    }
  }

  factory SessionSearchRequest.fromMap(Map<String, dynamic> map) {
    final rawQuery = map['query'];
    if (rawQuery is! String) throw ArgumentError('query must be a string.');
    final rawLimit = map['limit'];
    final limit = rawLimit == null
        ? defaultLimit
        : rawLimit is int
        ? rawLimit
        : int.tryParse(rawLimit.toString()) ??
              (throw ArgumentError('limit must be an integer.'));
    final rawCursor = map['cursor'];
    if (rawCursor != null &&
        (rawCursor is! String || rawCursor.trim().isEmpty)) {
      throw ArgumentError('cursor must be a non-empty string.');
    }
    return SessionSearchRequest(
      query: rawQuery,
      limit: limit,
      cursor: rawCursor as String?,
    );
  }

  static String normalize(String value) {
    final collapsed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    final units = collapsed.codeUnits;
    return String.fromCharCodes(
      units.map((unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit),
    );
  }

  String get fingerprint => sha256.convert(utf8.encode(query)).toString();
}

enum SessionSearchMatchKind {
  title('title'),
  content('content'),
  titleAndContent('title_and_content');

  final String wireValue;
  const SessionSearchMatchKind(this.wireValue);
}

class SessionSearchHit {
  final SessionState session;
  final SessionSearchMatchKind matchKind;
  final String? snippet;
  final String? anchorEventId;

  const SessionSearchHit({
    required this.session,
    required this.matchKind,
    this.snippet,
    this.anchorEventId,
  });
}

class SessionSearchResult {
  final List<SessionSearchHit> hits;
  final String? nextCursor;
  final bool hasMore;

  const SessionSearchResult({
    required this.hits,
    this.nextCursor,
    required this.hasMore,
  });
}
