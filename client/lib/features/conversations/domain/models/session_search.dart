import 'package:equatable/equatable.dart';

import 'session.dart';

enum SessionSearchMatchKind { title, content, titleAndContent }

class SessionSearchHit extends Equatable {
  final Session session;
  final SessionSearchMatchKind matchKind;
  final String? snippet;
  final String? anchorEventId;

  const SessionSearchHit({
    required this.session,
    required this.matchKind,
    this.snippet,
    this.anchorEventId,
  });

  factory SessionSearchHit.fromJson(Map<String, dynamic> json) {
    return SessionSearchHit(
      session: Session.fromJson(Map<String, dynamic>.from(json['session'] as Map)),
      matchKind: switch (json['match_kind']) {
        'title_and_content' => SessionSearchMatchKind.titleAndContent,
        'content' => SessionSearchMatchKind.content,
        _ => SessionSearchMatchKind.title,
      },
      snippet: json['snippet']?.toString(),
      anchorEventId: json['anchor_event_id']?.toString(),
    );
  }

  @override
  List<Object?> get props => [session, matchKind, snippet, anchorEventId];
}

class SessionSearchPage extends Equatable {
  final List<SessionSearchHit> hits;
  final String? nextCursor;
  final bool hasMore;

  const SessionSearchPage({required this.hits, this.nextCursor, required this.hasMore});

  @override
  List<Object?> get props => [hits, nextCursor, hasMore];
}

class SessionSearchException implements Exception {
  final String code;
  final String message;

  const SessionSearchException(this.code, this.message);

  @override
  String toString() => 'SessionSearchException($code): $message';
}
