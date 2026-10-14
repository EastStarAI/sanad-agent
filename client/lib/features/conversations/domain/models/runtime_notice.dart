import 'package:equatable/equatable.dart';

class RuntimeNotice extends Equatable {
  final String sessionId;
  final String? requestId;
  final String status;
  final String reason;
  final String title;
  final String? message;
  final String? providerInstanceId;
  final String? providerDisplayName;
  final DateTime? resumeAt;
  final int? retryAfterMs;
  final int? requestsPerMinuteLimit;
  final List<String> actions;
  final int? executionRevision;

  const RuntimeNotice({
    required this.sessionId,
    this.requestId,
    required this.status,
    required this.reason,
    required this.title,
    this.message,
    this.providerInstanceId,
    this.providerDisplayName,
    this.resumeAt,
    this.retryAfterMs,
    this.requestsPerMinuteLimit,
    this.actions = const <String>[],
    this.executionRevision,
  });

  bool get isWaiting => status == 'waiting';
  bool get isBlocked => status == 'blocked';
  bool get isFatal => status == 'fatal';
  bool get isResuming => status == 'resuming';

  factory RuntimeNotice.fromJson(Map<String, dynamic> json) {
    final limit = json['limit'];
    final limitMap = limit is Map ? Map<String, dynamic>.from(limit) : const <String, dynamic>{};
    return RuntimeNotice(
      sessionId: (json['session_id'] ?? '').toString(),
      requestId: json['request_id']?.toString(),
      status: (json['status'] ?? '').toString(),
      reason: (json['reason'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      message: json['message']?.toString(),
      providerInstanceId: json['provider_instance_id']?.toString(),
      providerDisplayName: json['provider_display_name']?.toString(),
      resumeAt: _parseDateTime(json['resume_at']),
      retryAfterMs: (json['retry_after_ms'] as num?)?.toInt(),
      requestsPerMinuteLimit: (limitMap['requests_per_minute'] as num?)?.toInt(),
      actions: (json['actions'] as List?)?.map((value) => value.toString()).toList() ?? const <String>[],
      executionRevision: (json['execution_revision'] as num?)?.toInt(),
    );
  }

  static DateTime? _parseDateTime(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw)?.toLocal();
  }

  @override
  List<Object?> get props => [
    sessionId,
    requestId,
    status,
    reason,
    title,
    message,
    providerInstanceId,
    providerDisplayName,
    resumeAt,
    retryAfterMs,
    requestsPerMinuteLimit,
    actions,
    executionRevision,
  ];
}
