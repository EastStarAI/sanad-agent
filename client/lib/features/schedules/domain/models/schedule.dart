import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_instant.dart';

/// The recurrence shape of a schedule (Task 139 protocol §4.4).
///
/// [unknown] is an additive-wire safety valve: a kind this Client does not know
/// yet is presented as unknown instead of crashing the list or being silently
/// re-interpreted as another shape.
enum ScheduleKind {
  once,
  interval,
  daily,
  weekly,
  monthly,
  unknown;

  /// Whether this value can be sent in a request. An unknown kind never can.
  bool get isSendable => this != ScheduleKind.unknown;

  /// Parses a wire token; an unrecognized one reads as [unknown].
  static ScheduleKind fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final kind in values) {
      if (kind != ScheduleKind.unknown && kind.name == normalized) return kind;
    }
    return ScheduleKind.unknown;
  }
}

/// Who may mutate a schedule (Task 139 D5, S15).
///
/// Read-only on the Client: the receiving command family decides the kind, so a
/// payload can never claim one.
enum ScheduleOwnerKind {
  user,
  model,
  unknown;

  static ScheduleOwnerKind fromWire(Object? value) => value?.toString().trim().toLowerCase() == 'user'
      ? ScheduleOwnerKind.user
      : value?.toString().trim().toLowerCase() == 'model'
      ? ScheduleOwnerKind.model
      : ScheduleOwnerKind.unknown;
}

/// Where a schedule's runs go (Task 139 S3, S4).
enum ScheduleConversationMode {
  /// One dedicated conversation per schedule, created on its first run.
  continuous,

  /// A fresh conversation per run, linked from run history.
  newEachRun,

  /// A mode this Client does not know yet; it is presented, never selected.
  unknown;

  /// The wire token, or `null` for [unknown] so it is never sent.
  String? get wireName => switch (this) {
    ScheduleConversationMode.continuous => 'continuous',
    ScheduleConversationMode.newEachRun => 'new_each_run',
    ScheduleConversationMode.unknown => null,
  };

  static ScheduleConversationMode fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'continuous' => ScheduleConversationMode.continuous,
      'new_each_run' => ScheduleConversationMode.newEachRun,
      _ => ScheduleConversationMode.unknown,
    };
  }
}

/// A weekday a weekly schedule fires on.
enum ScheduleWeekday {
  mon,
  tue,
  wed,
  thu,
  fri,
  sat,
  sun;

  String get wireName => name;

  /// Parses a wire token, or `null` when it is not a weekday this Client knows.
  static ScheduleWeekday? fromWire(Object? value) {
    final normalized = value?.toString().trim().toLowerCase();
    for (final day in values) {
      if (day.wireName == normalized) return day;
    }
    return null;
  }
}

/// The outcome of a schedule's most recent dispatch (Task 139 C2 "last
/// outcome").
///
/// [unknown] keeps an Agent token this Client does not know from becoming UI
/// copy.
enum ScheduleLastOutcome {
  fired,
  error,
  skippedMissed,
  unknown;

  static ScheduleLastOutcome fromWire(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'fired' => ScheduleLastOutcome.fired,
      'error' => ScheduleLastOutcome.error,
      'skipped_missed' => ScheduleLastOutcome.skippedMissed,
      _ => ScheduleLastOutcome.unknown,
    };
  }
}

/// One scheduling column of a `schedule.update` (Task 139 protocol §4.3).
///
/// `update` distinguishes three intentions for an editable settings column:
/// omit the key to keep the stored value, send a string to set it, and send an
/// explicit `null` to clear it. [ScheduleSetting.keep] is the omitted one, so a
/// caller cannot "clear" a column by forgetting to set it.
class ScheduleSetting {
  const ScheduleSetting.keep() : _value = _absent, isPresent = false;
  const ScheduleSetting.set(String? value) : _value = value, isPresent = true;

  static const Object _absent = Object();

  final Object? _value;

  /// Whether the key travels at all.
  final bool isPresent;

  /// The value to send: a string to set, `null` to clear.
  String? get value => isPresent && _value != _absent ? _value as String? : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScheduleSetting && other.isPresent == isPresent && other.value == value;

  @override
  int get hashCode => Object.hash(isPresent, value);
}

/// One schedule as `schedule.list`, `schedule.created`, and `schedule.updated`
/// project it (Task 139 protocol §4.4).
///
/// The projection is structured and never a sentence: [kind], [intervalMinutes],
/// [atTime], [weekdays], [monthDay], and [zone] are the fields the Client
/// composes its own localized summary from, so no Agent English sentence can
/// become a UI string.
///
/// Parsing is additive-tolerant: keys this Client does not know are ignored and
/// a malformed value degrades to an absent one, so one unexpected row can never
/// take down the list.
class Schedule extends Equatable {
  const Schedule({
    required this.id,
    required this.task,
    required this.kind,
    required this.zone,
    required this.enabled,
    required this.ownerKind,
    required this.conversationMode,
    this.name,
    this.intervalMinutes,
    this.atTime,
    this.weekdays = const <ScheduleWeekday>[],
    this.monthDay,
    this.nextRunAt,
    this.nextRunAtOffset,
    this.ownerSessionId,
    this.ownerSessionTitle,
    this.workspaceId,
    this.providerInstanceId,
    this.model,
    this.lastRunAt,
    this.lastOutcome,
    this.consecutiveFailures = 0,
    this.createdAt,
    this.updatedAt,
  });

  /// Consecutive failures at which the UI suggests pausing (Task 139 S16).
  static const int pauseSuggestionThreshold = 3;

  /// Server-minted identity; the only address of a schedule.
  final String id;

  /// Display name, or `null` when the user gave none.
  final String? name;

  /// The self-contained task text a run sends verbatim (S19).
  final String task;

  final ScheduleKind kind;

  /// Interval shape, in minutes.
  final int? intervalMinutes;

  /// Daily/weekly/monthly wall-clock time as `HH:MM` in [zone].
  final String? atTime;

  /// Weekly shape days; empty for every other shape.
  final List<ScheduleWeekday> weekdays;

  /// Monthly shape day of month.
  final int? monthDay;

  /// The schedule's own zone token (`local` or a fixed offset such as
  /// `+03:00`); [nextRunAt] is rendered in it.
  final String zone;

  /// The next instant the schedule fires, as an absolute instant, or `null`
  /// before an instant could be computed.
  final DateTime? nextRunAt;

  /// The offset token the Agent wrote with [nextRunAt] (`+03:00`, or `Z`).
  ///
  /// A `local` schedule means the *Agent's* local zone, and the device may be
  /// remote, so this token — never the Client's own timezone — is what the
  /// surfaces render the wall clock in (Task 139 F4).
  final String? nextRunAtOffset;

  /// Whether the timer may fire. A paused row keeps its [nextRunAt].
  final bool enabled;

  /// Who may mutate the row. Read-only on the Client (D5).
  final ScheduleOwnerKind ownerKind;

  /// The conversation a run appends to, or `null` when the schedule has none
  /// yet and always `null` for [ScheduleConversationMode.newEachRun].
  final String? ownerSessionId;

  /// The stored conversation title, and only that.
  final String? ownerSessionTitle;

  final ScheduleConversationMode conversationMode;

  /// The stored conversation route, used when a conversation is created.
  final String? workspaceId;
  final String? providerInstanceId;
  final String? model;

  final DateTime? lastRunAt;

  /// The outcome of the most recent dispatch, or `null` when it never ran.
  final ScheduleLastOutcome? lastOutcome;

  /// Newest consecutive failed runs; a non-failed terminal run ends the streak.
  final int consecutiveFailures;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Whether the row is paused.
  bool get isPaused => !enabled;

  /// Whether the schedule is bound to a conversation it dispatches into.
  bool get hasOwnerConversation => ownerSessionId != null;

  /// Whether a model-owned schedule lost the conversation it dispatched into
  /// (Task 139 S23, D10): the Client then offers Edit and Delete only, and
  /// `resume`/`run_now` would answer `schedule_orphaned`.
  bool get isOrphaned => ownerKind == ScheduleOwnerKind.model && ownerSessionId == null;

  /// Whether `run_now` can be offered. A paused row still can (S21).
  bool get canRunNow => !isOrphaned;

  /// Whether `resume` can be offered.
  bool get canResume => isPaused && !isOrphaned;

  /// Whether the consecutive-failure streak reached the pause suggestion (S16).
  bool get suggestsPause => consecutiveFailures >= pauseSuggestionThreshold;

  factory Schedule.fromJson(Map<String, dynamic> json) {
    final weekdays = <ScheduleWeekday>[];
    final rawWeekdays = json['weekdays'];
    if (rawWeekdays is List) {
      for (final day in rawWeekdays) {
        final parsed = ScheduleWeekday.fromWire(day);
        if (parsed != null) weekdays.add(parsed);
      }
    }
    final rawOutcome = json['last_status'];
    final nextRun = ScheduleInstant.tryParse(json['next_run_at']);
    return Schedule(
      id: json['id']?.toString() ?? '',
      name: _blankToNull(json['name']),
      task: json['task']?.toString() ?? '',
      kind: ScheduleKind.fromWire(json['kind']),
      intervalMinutes: _asInt(json['interval_minutes']),
      atTime: _blankToNull(json['at_time']),
      weekdays: List<ScheduleWeekday>.unmodifiable(weekdays),
      monthDay: _asInt(json['month_day']),
      zone: _blankToNull(json['zone']) ?? 'local',
      nextRunAt: nextRun?.instant,
      nextRunAtOffset: nextRun?.offset,
      enabled: json['enabled'] == true,
      ownerKind: ScheduleOwnerKind.fromWire(json['owner_kind']),
      ownerSessionId: _blankToNull(json['owner_session_id']),
      ownerSessionTitle: _blankToNull(json['owner_session_title']),
      conversationMode: ScheduleConversationMode.fromWire(json['conversation_mode']),
      workspaceId: _blankToNull(json['workspace_id']),
      providerInstanceId: _blankToNull(json['provider_instance_id']),
      model: _blankToNull(json['model']),
      lastRunAt: ScheduleInstant.utcTryParse(json['last_run_at']),
      lastOutcome: rawOutcome == null ? null : ScheduleLastOutcome.fromWire(rawOutcome),
      consecutiveFailures: _asInt(json['consecutive_failures']) ?? 0,
      createdAt: _asUtc(json['created_at']),
      updatedAt: _asUtc(json['updated_at']),
    );
  }

  static String? _blankToNull(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _asInt(Object? value) => value is int ? value : int.tryParse(value?.toString() ?? '');

  static DateTime? _asUtc(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// The serialized identity-only summary; it never carries the task text into
  /// a log line or a formatted string.
  @override
  String toString() =>
      'Schedule(id: $id, kind: ${kind.name}, enabled: $enabled, '
      'owner: ${ownerKind.name}, mode: ${conversationMode.name})';

  @override
  List<Object?> get props => [
    id,
    name,
    task,
    kind,
    intervalMinutes,
    atTime,
    weekdays,
    monthDay,
    zone,
    nextRunAt,
    nextRunAtOffset,
    enabled,
    ownerKind,
    ownerSessionId,
    ownerSessionTitle,
    conversationMode,
    workspaceId,
    providerInstanceId,
    model,
    lastRunAt,
    lastOutcome,
    consecutiveFailures,
    createdAt,
    updatedAt,
  ];
}

/// The `schedule.list_result` projection: one bounded page of rows.
class SchedulesSnapshot extends Equatable {
  const SchedulesSnapshot({required this.schedules, this.truncated = false});

  final List<Schedule> schedules;

  /// Whether the Agent stopped at its list bound; no page depends on the tail.
  final bool truncated;

  factory SchedulesSnapshot.fromJson(Map<String, dynamic> json) {
    final entries = json['schedules'];
    return SchedulesSnapshot(
      schedules: List<Schedule>.unmodifiable([
        if (entries is List)
          for (final entry in entries)
            if (entry is Map) Schedule.fromJson(Map<String, dynamic>.from(entry)),
      ]),
      truncated: json['truncated'] == true,
    );
  }

  @override
  List<Object?> get props => [schedules, truncated];
}
