import 'package:equatable/equatable.dart';

import '../../domain/models/session_search.dart';

enum SessionSearchStatus { idle, loading, ready, empty, failure, loadingMore }

class SessionSearchState extends Equatable {
  final String query;
  final String? deviceId;
  final SessionSearchStatus status;
  final List<SessionSearchHit> hits;
  final String? nextCursor;
  final bool hasMore;
  final String? errorMessage;

  const SessionSearchState({
    this.query = '',
    this.deviceId,
    this.status = SessionSearchStatus.idle,
    this.hits = const [],
    this.nextCursor,
    this.hasMore = false,
    this.errorMessage,
  });

  SessionSearchState copyWith({
    String? query,
    String? deviceId,
    SessionSearchStatus? status,
    List<SessionSearchHit>? hits,
    String? nextCursor,
    bool clearCursor = false,
    bool? hasMore,
    String? errorMessage,
    bool clearError = false,
  }) {
    return SessionSearchState(
      query: query ?? this.query,
      deviceId: deviceId ?? this.deviceId,
      status: status ?? this.status,
      hits: hits ?? this.hits,
      nextCursor: clearCursor ? null : nextCursor ?? this.nextCursor,
      hasMore: hasMore ?? this.hasMore,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
    query,
    deviceId,
    status,
    hits,
    nextCursor,
    hasMore,
    errorMessage,
  ];
}
