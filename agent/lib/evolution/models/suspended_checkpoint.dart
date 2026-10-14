import 'dart:convert';

class SuspendedCheckpoint {
  final String checkpointId;
  final String sessionId;
  final String requestId;
  final String toolCallId;
  final String toolName;
  final String status;
  final Map<String, dynamic> toolArguments;
  final Map<String, dynamic> permissionPayload;
  final Map<String, dynamic>? resolvedDecision;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SuspendedCheckpoint({
    required this.checkpointId,
    required this.sessionId,
    required this.requestId,
    required this.toolCallId,
    required this.toolName,
    required this.status,
    required this.toolArguments,
    required this.permissionPayload,
    this.resolvedDecision,
    required this.createdAt,
    required this.updatedAt,
  });

  SuspendedCheckpoint copyWith({
    String? checkpointId,
    String? sessionId,
    String? requestId,
    String? toolCallId,
    String? toolName,
    String? status,
    Map<String, dynamic>? toolArguments,
    Map<String, dynamic>? permissionPayload,
    Map<String, dynamic>? resolvedDecision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SuspendedCheckpoint(
      checkpointId: checkpointId ?? this.checkpointId,
      sessionId: sessionId ?? this.sessionId,
      requestId: requestId ?? this.requestId,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      status: status ?? this.status,
      toolArguments: toolArguments ?? this.toolArguments,
      permissionPayload: permissionPayload ?? this.permissionPayload,
      resolvedDecision: resolvedDecision ?? this.resolvedDecision,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toRow() {
    return {
      'checkpoint_id': checkpointId,
      'session_id': sessionId,
      'request_id': requestId,
      'tool_call_id': toolCallId,
      'tool_name': toolName,
      'status': status,
      'tool_arguments': jsonEncode(toolArguments),
      'permission_payload': jsonEncode(permissionPayload),
      'resolved_decision': resolvedDecision == null
          ? null
          : jsonEncode(resolvedDecision),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory SuspendedCheckpoint.fromRow(Map<String, Object?> row) {
    Map<String, dynamic> decodeJson(String key) {
      final raw = row[key];
      if (raw is! String || raw.isEmpty) {
        return <String, dynamic>{};
      }
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}
      return <String, dynamic>{};
    }

    return SuspendedCheckpoint(
      checkpointId: row['checkpoint_id'] as String,
      sessionId: row['session_id'] as String,
      requestId: row['request_id'] as String,
      toolCallId: row['tool_call_id'] as String,
      toolName: row['tool_name'] as String,
      status: row['status'] as String,
      toolArguments: decodeJson('tool_arguments'),
      permissionPayload: decodeJson('permission_payload'),
      resolvedDecision: row['resolved_decision'] == null
          ? null
          : decodeJson('resolved_decision'),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
