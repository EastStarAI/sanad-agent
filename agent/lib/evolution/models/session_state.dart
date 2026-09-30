import '../../core/models/message.dart';

enum SessionTitleStatus {
  pending('pending'),
  finalized('final');

  final String wireValue;

  const SessionTitleStatus(this.wireValue);

  static SessionTitleStatus fromWire(Object? value) {
    return value == pending.wireValue ? pending : finalized;
  }
}

class SessionState {
  final String sessionId;
  final String model;
  final String? providerId;
  final String? thinkingMode;
  final String? title;
  final SessionTitleStatus titleStatus;
  final String? workspaceId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastUserMessageAt;
  final int routeRevision;
  final DateTime routeUpdatedAt;
  final int historyRevision;
  final String lineageId;
  final String? parentSessionId;
  final String? forkedFromMessageId;
  final String? forkedFromTurnId;
  final int forkSequence;
  final String? lineageBaseTitle;
  final String? forkRequestId;
  final List<Message> messages;

  SessionState({
    required this.sessionId,
    required this.model,
    this.providerId,
    this.thinkingMode,
    this.title,
    this.titleStatus = SessionTitleStatus.finalized,
    this.workspaceId,
    required this.createdAt,
    required this.updatedAt,
    this.lastUserMessageAt,
    this.routeRevision = 1,
    DateTime? routeUpdatedAt,
    this.historyRevision = 0,
    String? lineageId,
    this.parentSessionId,
    this.forkedFromMessageId,
    this.forkedFromTurnId,
    this.forkSequence = 0,
    this.lineageBaseTitle,
    this.forkRequestId,
    this.messages = const [],
  }) : lineageId = (lineageId == null || lineageId.isEmpty)
           ? sessionId
           : lineageId,
       routeUpdatedAt = routeUpdatedAt ?? updatedAt;

  Map<String, dynamic> toMap() {
    return {
      'session_id': sessionId,
      'model': model,
      'provider_id': providerId,
      'thinking_mode': thinkingMode,
      'title': title,
      'title_status': titleStatus.wireValue,
      'workspace_id': workspaceId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'last_user_message_at': lastUserMessageAt?.toIso8601String(),
      'route_revision': routeRevision,
      'route_updated_at': routeUpdatedAt.toIso8601String(),
      'history_revision': historyRevision,
      'lineage_id': lineageId,
      'parent_session_id': parentSessionId,
      'forked_from_message_id': forkedFromMessageId,
      'forked_from_turn_id': forkedFromTurnId,
      'fork_sequence': forkSequence,
      'lineage_base_title': lineageBaseTitle,
      'fork_request_id': forkRequestId,
    };
  }

  factory SessionState.fromMap(
    Map<String, dynamic> map, [
    List<Message> messages = const [],
  ]) {
    final lastUserMsgAtRaw = map['last_user_message_at'];
    return SessionState(
      sessionId: map['session_id'],
      model: map['model'],
      providerId: map['provider_id']?.toString(),
      thinkingMode: map['thinking_mode']?.toString(),
      title: map['title'],
      titleStatus: SessionTitleStatus.fromWire(map['title_status']),
      workspaceId: map['workspace_id']?.toString(),
      createdAt: DateTime.parse(map['created_at']),
      updatedAt: DateTime.parse(map['updated_at']),
      lastUserMessageAt: lastUserMsgAtRaw != null
          ? DateTime.parse(lastUserMsgAtRaw)
          : null,
      routeRevision: (map['route_revision'] as num?)?.toInt() ?? 1,
      routeUpdatedAt: DateTime.parse(
        map['route_updated_at']?.toString() ?? map['updated_at'].toString(),
      ),
      historyRevision: (map['history_revision'] as num?)?.toInt() ?? 0,
      lineageId: _nonEmpty(map['lineage_id']),
      parentSessionId: _nonEmpty(map['parent_session_id']),
      forkedFromMessageId: _nonEmpty(map['forked_from_message_id']),
      forkedFromTurnId: _nonEmpty(map['forked_from_turn_id']),
      forkSequence: (map['fork_sequence'] as num?)?.toInt() ?? 0,
      lineageBaseTitle: _nonEmpty(map['lineage_base_title']),
      forkRequestId: _nonEmpty(map['fork_request_id']),
      messages: messages,
    );
  }

  static String? _nonEmpty(Object? value) {
    final text = value?.toString().trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }
}
