import 'schedule_model.dart';

/// Who may mutate a `scheduled_tasks` row (Task 139 D1, D5, S15).
///
/// The kind is decided by the receiving command family and never read from a
/// payload: a model turn can only produce [model], and only a device-owner
/// command produces [user]. A row can therefore never widen its own authority.
enum ScheduleOwnerKind {
  /// Created by a model turn inside a conversation. Mutable by its owning
  /// conversation and by device-owner authority.
  model,

  /// Created by a device-owner command that needs no conversation. Mutable by
  /// device-owner authority only.
  user;

  /// The value stored in `scheduled_tasks.owner_kind` and sent on the wire.
  String get wireName => name;

  /// Parses a stored value.
  ///
  /// An unknown value — a kind a newer agent wrote — falls back to [model],
  /// which is the most restrictive kind: only the owning conversation and
  /// device-owner authority can mutate it.
  static ScheduleOwnerKind fromWire(Object? value) =>
      value?.toString().trim().toLowerCase() == user.wireName ? user : model;
}

/// How a schedule's conversation is created and reused (Task 139 S3, S4).
enum ScheduleConversationMode {
  /// One dedicated conversation per schedule: created on the first dispatch
  /// (timer, recovery, or Run now) and reused by every later run.
  continuous,

  /// A fresh conversation per run, linked from that run's row.
  newEachRun;

  /// The value stored in `scheduled_tasks.conversation_mode` and sent on the
  /// wire.
  String get wireName => this == newEachRun ? 'new_each_run' : 'continuous';

  /// Parses a stored value.
  ///
  /// An unknown value keeps [continuous], which is how every pre-Task-139 row
  /// behaves.
  static ScheduleConversationMode fromWire(Object? value) =>
      value?.toString().trim().toLowerCase() == 'new_each_run'
          ? newEachRun
          : continuous;
}

/// Durable scheduled task entity (Decision D8, Task 139 D1).
///
/// One row of `scheduled_tasks`. The recurrence fields are the definition
/// (`ScheduleDefinition`); [name], the owner kind, the conversation mode, and
/// the four route columns are storage and dispatch concerns that never take
/// part in occurrence arithmetic.
class ScheduledTaskRecord {
  final String id;
  final String task;
  final String sessionId;
  final ScheduleKind kind;
  final int? intervalMinutes;
  final String? atTime;
  final String? weekdays; // comma-separated e.g. "mon,wed"
  final int? monthDay;
  final String zone;
  final DateTime nextRunAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastRunAt;
  final String? lastStatus;
  final bool enabled;

  /// Optional display name. `null` means the list derives a label from [task].
  final String? name;

  /// Who may mutate this row (D1, D5).
  ///
  /// A pre-Task-139 row has no stored value and is [ScheduleOwnerKind.model],
  /// which is exactly what it was.
  final ScheduleOwnerKind ownerKind;

  /// Whether runs share one conversation or get a fresh one each (S3, S4).
  final ScheduleConversationMode conversationMode;

  /// The conversation runs append to (S3).
  ///
  /// For a model-owned row this is the owning conversation, mirrored from
  /// [sessionId]. A user-owned `continuous` schedule keeps it empty until its
  /// first dispatch creates the conversation; [ownerKind] carries that meaning,
  /// so an empty value is never presented as an identity.
  final String? runSessionId;

  /// Workspace the schedule's conversation is created in (S5).
  final String? workspaceId;

  /// Provider instance the schedule's conversation runs on (S5).
  final String? providerInstanceId;

  /// Model the schedule's conversation runs on (S5).
  final String? model;

  const ScheduledTaskRecord({
    required this.id,
    required this.task,
    required this.sessionId,
    required this.kind,
    this.intervalMinutes,
    this.atTime,
    this.weekdays,
    this.monthDay,
    required this.zone,
    required this.nextRunAt,
    required this.createdAt,
    required this.updatedAt,
    this.lastRunAt,
    this.lastStatus,
    required this.enabled,
    this.name,
    this.ownerKind = ScheduleOwnerKind.model,
    this.conversationMode = ScheduleConversationMode.continuous,
    this.runSessionId,
    this.workspaceId,
    this.providerInstanceId,
    this.model,
  });

  ScheduleDefinition toDefinition() {
    List<String>? parsedWeekdays;
    if (weekdays != null && weekdays!.trim().isNotEmpty) {
      parsedWeekdays = weekdays!
          .split(',')
          .map((w) => w.trim().toLowerCase())
          .where((w) => w.isNotEmpty)
          .toList();
    }
    return ScheduleDefinition(
      kind: kind,
      intervalMinutes: intervalMinutes,
      atTime: atTime,
      weekdays: parsedWeekdays,
      monthDay: monthDay,
      zone: zone,
      onceAt: kind == ScheduleKind.once ? nextRunAt : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'task': task,
        'session_id': sessionId,
        'kind': kind.name,
        'interval_minutes': intervalMinutes,
        'at_time': atTime,
        'weekdays': weekdays,
        'month_day': monthDay,
        'zone': zone,
        'next_run_at': nextRunAt.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'last_run_at': lastRunAt?.toUtc().toIso8601String(),
        'last_status': lastStatus,
        'enabled': enabled ? 1 : 0,
        'name': name,
        'owner_kind': ownerKind.wireName,
        'conversation_mode': conversationMode.wireName,
        'run_session_id': runSessionId,
        'workspace_id': workspaceId,
        'provider_instance_id': providerInstanceId,
        'model': model,
      };

  factory ScheduledTaskRecord.fromRow(Map<String, dynamic> row) {
    final rawKind = row['kind']?.toString() ?? 'once';
    final kind = ScheduleKind.values.firstWhere(
      (k) => k.name == rawKind,
      orElse: () => ScheduleKind.once,
    );

    final rawNextRunAt = row['next_run_at']?.toString();
    final nextRunAt = rawNextRunAt != null
        ? DateTime.parse(rawNextRunAt).toUtc()
        : DateTime.now().toUtc();

    final rawCreatedAt = row['created_at']?.toString();
    final createdAt = rawCreatedAt != null
        ? DateTime.parse(rawCreatedAt).toUtc()
        : DateTime.now().toUtc();

    final rawUpdatedAt = row['updated_at']?.toString();
    final updatedAt = rawUpdatedAt != null
        ? DateTime.parse(rawUpdatedAt).toUtc()
        : createdAt;

    final rawLastRunAt = row['last_run_at']?.toString();
    final lastRunAt = rawLastRunAt != null
        ? DateTime.parse(rawLastRunAt).toUtc()
        : null;

    final enabledVal = row['enabled'];
    final enabled = enabledVal == null || enabledVal == 1 || enabledVal == true;

    return ScheduledTaskRecord(
      id: row['id'] as String,
      task: row['task'] as String,
      sessionId: row['session_id'] as String,
      kind: kind,
      intervalMinutes: row['interval_minutes'] as int?,
      atTime: row['at_time'] as String?,
      weekdays: row['weekdays'] as String?,
      monthDay: row['month_day'] as int?,
      zone: (row['zone'] as String?) ?? 'local',
      nextRunAt: nextRunAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      lastRunAt: lastRunAt,
      lastStatus: row['last_status'] as String?,
      enabled: enabled,
      name: blankToNull(row['name']),
      ownerKind: ScheduleOwnerKind.fromWire(row['owner_kind']),
      conversationMode: ScheduleConversationMode.fromWire(
        row['conversation_mode'],
      ),
      runSessionId: blankToNull(row['run_session_id']),
      workspaceId: blankToNull(row['workspace_id']),
      providerInstanceId: blankToNull(row['provider_instance_id']),
      model: blankToNull(row['model']),
    );
  }
}

/// A blank stored value is an absent one: no payload may present the empty
/// string as an identity.
///
/// Shared by the schedule row and run row decoders so both treat a blank
/// column identically.
String? blankToNull(Object? value) {
  final text = value?.toString().trim();
  return (text == null || text.isEmpty) ? null : text;
}
