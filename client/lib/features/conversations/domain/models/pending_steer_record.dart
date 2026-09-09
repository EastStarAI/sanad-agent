import 'package:equatable/equatable.dart';

enum PendingSteerState {
  pending,
  delivering,
  delivered,
  cancelled,
  recovered;

  static PendingSteerState fromWire(Object? value) => PendingSteerState.values.firstWhere(
    (state) => state.name == value?.toString(),
    orElse: () => throw FormatException('Unknown pending steer state: $value'),
  );
}

class PendingSteerRecord extends Equatable {
  final String sessionId;
  final String requestId;
  final String runId;
  final int generation;
  final String text;
  final DateTime receivedAt;
  final PendingSteerState state;
  final int revision;
  final DateTime? updatedAt;
  final String? messageId;
  final String? turnId;
  final String? anchorMessageId;
  final String? anchorToolCallId;
  final int? historyRevision;

  const PendingSteerRecord({
    required this.sessionId,
    required this.requestId,
    required this.runId,
    required this.generation,
    required this.text,
    required this.receivedAt,
    required this.state,
    required this.revision,
    required this.updatedAt,
    this.messageId,
    this.turnId,
    this.anchorMessageId,
    this.anchorToolCallId,
    this.historyRevision,
  });

  factory PendingSteerRecord.fromJson(Map<String, dynamic> json) {
    final sessionId = json['session_id']?.toString().trim() ?? '';
    final requestId = json['request_id']?.toString().trim() ?? '';
    if (sessionId.isEmpty || requestId.isEmpty) {
      throw const FormatException('Pending steer requires session_id and request_id.');
    }
    final revision = _integer(json['revision'], 'revision');
    final generation = _integer(json['generation'] ?? 0, 'generation');
    final receivedAt = DateTime.tryParse(json['received_at']?.toString() ?? '');
    if (receivedAt == null) throw const FormatException('Pending steer requires received_at.');
    final updatedRaw = json['updated_at'];
    final updatedAt = updatedRaw == null ? null : DateTime.tryParse(updatedRaw.toString());
    return PendingSteerRecord(
      sessionId: sessionId,
      requestId: requestId,
      runId: json['run_id']?.toString() ?? '',
      generation: generation,
      text: json['text']?.toString() ?? json['message']?.toString() ?? '',
      receivedAt: receivedAt,
      state: PendingSteerState.fromWire(json['state']),
      revision: revision,
      updatedAt: updatedAt,
      messageId: _optionalId(json['message_id']),
      turnId: _optionalId(json['turn_id']),
      anchorMessageId: _optionalId(json['anchor_message_id']),
      anchorToolCallId: _optionalId(json['anchor_tool_call_id']),
      historyRevision: json['history_revision'] == null ? null : _integer(json['history_revision'], 'history_revision'),
    );
  }

  static String? _optionalId(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static int _integer(Object? value, String name) {
    if (value is num && value.toInt() == value && !value.isNegative) return value.toInt();
    throw FormatException('$name must be a non-negative integer: $value');
  }

  @override
  List<Object?> get props => [
    sessionId,
    requestId,
    runId,
    generation,
    text,
    receivedAt,
    state,
    revision,
    updatedAt,
    messageId,
    turnId,
    anchorMessageId,
    anchorToolCallId,
    historyRevision,
  ];
}
