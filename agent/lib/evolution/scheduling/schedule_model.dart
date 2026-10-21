import 'package:meta/meta.dart';

/// Supported schedule recurrence kinds (Decision D2).
enum ScheduleKind {
  once,
  interval,
  daily,
  weekly,
  monthly;

  static ScheduleKind fromString(String value) {
    switch (value.trim().toLowerCase()) {
      case 'once':
        return ScheduleKind.once;
      case 'interval':
        return ScheduleKind.interval;
      case 'daily':
        return ScheduleKind.daily;
      case 'weekly':
        return ScheduleKind.weekly;
      case 'monthly':
        return ScheduleKind.monthly;
      default:
        throw ScheduleValidationException(
          'Unknown schedule kind "$value". Accepted forms are:\n'
          '  - once: at <ISO-8601> or in <n> <minutes|hours|days>\n'
          '  - interval: every <n> <minutes|hours|days>\n'
          '  - daily: time HH:MM\n'
          '  - weekly: weekdays (mon..sun) and time HH:MM\n'
          '  - monthly: day_of_month (1..31) and time HH:MM',
        );
    }
  }
}

/// Validation exception thrown when schedule definitions violate D2/D3 contracts.
class ScheduleValidationException implements Exception {
  final String message;
  const ScheduleValidationException(this.message);

  @override
  String toString() => message;
}

/// Timezone interpretation for schedules (Decision D3).
///
/// Supports 'local' (host OS rules via Dart local DateTime) or fixed UTC offset ('Z', '+HH:MM', '-HH:MM').
/// IANA timezone identifiers are rejected with a clear message.
class ScheduleZone {
  final String raw;
  final bool isLocal;
  final Duration offset;
  final DateTime Function(DateTime utcInstant)? _customToZoned;
  final DateTime Function(int year, int month, int day, int hour, int minute, int second, int millisecond)? _customWallClockToUtc;

  const ScheduleZone._({
    required this.raw,
    required this.isLocal,
    required this.offset,
    DateTime Function(DateTime utcInstant)? customToZoned,
    DateTime Function(int year, int month, int day, int hour, int minute, int second, int millisecond)? customWallClockToUtc,
  })  : _customToZoned = customToZoned,
        _customWallClockToUtc = customWallClockToUtc;

  factory ScheduleZone.local() => const ScheduleZone._(
        raw: 'local',
        isLocal: true,
        offset: Duration.zero,
      );

  factory ScheduleZone.utc() => const ScheduleZone._(
        raw: 'Z',
        isLocal: false,
        offset: Duration.zero,
      );

  factory ScheduleZone.fixed(Duration offset, String raw) => ScheduleZone._(
        raw: raw,
        isLocal: false,
        offset: offset,
      );

  /// Creates a simulated DST zone for pinned deterministic testing of spring-forward,
  /// fall-back, and gap/fold wall-clock transitions across all test environments.
  @visibleForTesting
  factory ScheduleZone.simulatedDst({
    required String raw,
    required Duration standardOffset,
    required Duration daylightOffset,
    required DateTime springForwardUtc,
    required DateTime fallBackUtc,
  }) {
    Duration offsetAtUtc(DateTime utc) {
      if (utc.isBefore(springForwardUtc) || !utc.isBefore(fallBackUtc)) {
        return standardOffset;
      }
      return daylightOffset;
    }

    return ScheduleZone._(
      raw: raw,
      isLocal: false,
      offset: standardOffset,
      customToZoned: (utcInstant) {
        final currentOffset = offsetAtUtc(utcInstant.toUtc());
        return utcInstant.toUtc().add(currentOffset);
      },
      customWallClockToUtc: (year, month, day, hour, minute, second, millisecond) {
        final wallUtc = DateTime.utc(year, month, day, hour, minute, second, millisecond);
        // Estimate instant with standard offset
        final candidateStandard = wallUtc.subtract(standardOffset);
        final candidateDaylight = wallUtc.subtract(daylightOffset);

        // Gap check (spring forward): candidateStandard >= springForwardUtc, but candidateDaylight < springForwardUtc
        if (candidateStandard.isAfter(springForwardUtc) && candidateDaylight.isBefore(springForwardUtc)) {
          // In the gap: resolve to the daylight instant (fold/gap deterministic pin)
          return candidateDaylight;
        }

        // Fold check (fall back): both candidates are valid local times
        if (candidateDaylight.isAfter(fallBackUtc) && candidateStandard.isBefore(fallBackUtc)) {
          // Fold instant: deterministically pick the first occurrence (daylight)
          return candidateDaylight;
        }

        if (candidateDaylight.isAfter(springForwardUtc) && candidateDaylight.isBefore(fallBackUtc)) {
          return candidateDaylight;
        }
        return candidateStandard;
      },
    );
  }

  static ScheduleZone parse(String? zoneStr) {
    if (zoneStr == null || zoneStr.trim().isEmpty || zoneStr.trim().toLowerCase() == 'local') {
      return ScheduleZone.local();
    }
    final trimmed = zoneStr.trim();
    if (trimmed == 'Z' || trimmed == 'z') {
      return ScheduleZone.utc();
    }

    final offsetMatch = RegExp(r'^([+-])(\d{2}):(\d{2})$').firstMatch(trimmed);
    if (offsetMatch != null) {
      final sign = offsetMatch.group(1) == '+' ? 1 : -1;
      final hours = int.parse(offsetMatch.group(2)!);
      final minutes = int.parse(offsetMatch.group(3)!);
      if (hours > 23 || minutes > 59) {
        throw ScheduleValidationException(
          'Invalid timezone offset "$trimmed". Hours must be 00-23 and minutes 00-59.',
        );
      }
      final duration = Duration(minutes: sign * (hours * 60 + minutes));
      return ScheduleZone.fixed(duration, trimmed);
    }

    // Reject IANA or unrecognized timezone names.
    throw ScheduleValidationException(
      'Invalid timezone "$trimmed". Supported timezones are "local" or a fixed UTC offset ("Z", "+HH:MM", "-HH:MM"). '
      'IANA timezone identifiers are not supported in this release.',
    );
  }

  /// Converts a UTC instant into wall-clock DateTime components in this zone.
  DateTime toZoned(DateTime utcInstant) {
    final customToZoned = _customToZoned;
    if (customToZoned != null) {
      return customToZoned(utcInstant);
    }
    final utc = utcInstant.toUtc();
    if (isLocal) {
      return utc.toLocal();
    }
    return utc.add(offset);
  }

  /// Computes a UTC DateTime instant from the given wall-clock date and time in this zone.
  DateTime wallClockToUtc(
    int year,
    int month,
    int day,
    int hour,
    int minute, [
    int second = 0,
    int millisecond = 0,
  ]) {
    final customWallClockToUtc = _customWallClockToUtc;
    if (customWallClockToUtc != null) {
      return customWallClockToUtc(year, month, day, hour, minute, second, millisecond);
    }
    if (isLocal) {
      // Dart's local DateTime follows host OS rules including DST gap/fold.
      final localDt = DateTime(year, month, day, hour, minute, second, millisecond);
      return localDt.toUtc();
    }
    // Fixed offset resolves arithmetically: wall clock - offset = UTC.
    final wallUtc = DateTime.utc(year, month, day, hour, minute, second, millisecond);
    return wallUtc.subtract(offset);
  }

  /// Renders a UTC instant into an ISO-8601 string in this zone.
  ///
  /// Every zone renders `YYYY-MM-DDTHH:MM:SS` plus an explicit designator
  /// (`Z` or `±HH:MM`); `local` uses the host offset at that instant.
  String formatInstant(DateTime utcInstant) {
    final utc = utcInstant.toUtc();
    final zoned = toZoned(utc);
    final String designator;
    if (isLocal) {
      designator = _formatOffset(zoned.timeZoneOffset);
    } else {
      designator = raw;
    }
    final y = zoned.year.toString().padLeft(4, '0');
    final m = zoned.month.toString().padLeft(2, '0');
    final d = zoned.day.toString().padLeft(2, '0');
    final h = zoned.hour.toString().padLeft(2, '0');
    final min = zoned.minute.toString().padLeft(2, '0');
    final s = zoned.second.toString().padLeft(2, '0');
    return '$y-$m-${d}T$h:$min:$s$designator';
  }

  static String _formatOffset(Duration offset) {
    if (offset == Duration.zero) return 'Z';
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    final hh = abs.inHours.toString().padLeft(2, '0');
    final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return '$sign$hh:$mm';
  }

  @override
  String toString() => raw;
}

/// Canonical weekdays: Monday=1 to Sunday=7.
const Map<String, int> _weekdayMap = {
  'mon': 1,
  'tue': 2,
  'wed': 3,
  'thu': 4,
  'fri': 5,
  'sat': 6,
  'sun': 7,
};

const Map<int, String> _weekdayNames = {
  1: 'mon',
  2: 'tue',
  3: 'wed',
  4: 'thu',
  5: 'fri',
  6: 'sat',
  7: 'sun',
};

/// Pure schedule definition value object (Decisions D2, D3, D4).
class ScheduleDefinition {
  final ScheduleKind kind;
  final int? intervalMinutes;
  final String? atTime; // "HH:MM"
  final List<String>? weekdays; // sorted mon..sun
  final int? monthDay; // 1..31
  final String zone; // "local" or fixed offset
  final DateTime? onceAt; // absolute UTC instant for once
  final Duration? onceIn; // relative duration for once

  const ScheduleDefinition({
    required this.kind,
    this.intervalMinutes,
    this.atTime,
    this.weekdays,
    this.monthDay,
    required this.zone,
    this.onceAt,
    this.onceIn,
  });

  /// Longest accepted `interval` period and `in` delay. Bounding them keeps
  /// occurrence arithmetic inside the `DateTime` range (no overflow, no
  /// negative step) for every value the parser accepts.
  static const Duration maxPeriod = Duration(days: 366);

  /// Returns [args] without keys whose value is absent: `null`, a blank
  /// string, or an empty list. Models often send unused optional parameters
  /// that way, and such a key must not change the inferred schedule shape.
  static Map<String, dynamic> withoutAbsentValues(Map<String, dynamic> args) => {
    for (final entry in args.entries)
      if (!_isAbsentValue(entry.value)) entry.key: entry.value,
  };

  static bool _isAbsentValue(Object? value) =>
      value == null ||
      (value is String && value.trim().isEmpty) ||
      (value is List && value.isEmpty);

  /// Parses and validates schedule parameters from a tool or API map.
  static ScheduleDefinition parse(
    Map<String, dynamic> rawArgs, {
    String defaultZone = 'local',
    DateTime? now,
  }) {
    final args = withoutAbsentValues(rawArgs);
    final effectiveNow = now ?? DateTime.now().toUtc();
    final rawZone = (args['zone'] as String?)?.trim();
    final zoneStr = (rawZone != null && rawZone.isNotEmpty) ? rawZone : defaultZone;
    final parsedZone = ScheduleZone.parse(zoneStr);

    final rawKind = (args['kind'] as String?)?.trim();
    final hasInterval = args.containsKey('every') ||
        args.containsKey('interval_minutes') ||
        args.containsKey('interval');
    final hasWeekdays = args.containsKey('weekdays');
    final hasMonthDay = args.containsKey('day_of_month') || args.containsKey('month_day');
    final hasTime = args.containsKey('time');
    final hasAt = args.containsKey('at');
    final hasIn = args.containsKey('in');

    ScheduleKind kind;
    if (rawKind != null && rawKind.isNotEmpty) {
      kind = ScheduleKind.fromString(rawKind);
    } else {
      // Infer kind from parameters.
      if (hasInterval) {
        kind = ScheduleKind.interval;
      } else if (hasWeekdays) {
        kind = ScheduleKind.weekly;
      } else if (hasMonthDay) {
        kind = ScheduleKind.monthly;
      } else if (hasTime) {
        final timeStr = args['time'].toString().trim();
        if (RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(timeStr)) {
          kind = ScheduleKind.daily;
        } else {
          kind = ScheduleKind.once;
        }
      } else {
        kind = ScheduleKind.once;
      }
    }

    // Cross-kind validation: any shape outside D2 is rejected, never dropped.
    if (kind == ScheduleKind.interval) {
      if (hasTime || hasWeekdays || hasMonthDay || hasAt || hasIn) {
        throw const ScheduleValidationException(
          'Interval schedule cannot be combined with calendar fields (time, weekdays, day_of_month) or once fields (at, in).',
        );
      }
    } else if (kind == ScheduleKind.once) {
      if (hasInterval || hasWeekdays || hasMonthDay) {
        throw const ScheduleValidationException(
          'Once schedule cannot be combined with interval or calendar fields (every, interval_minutes, weekdays, day_of_month).',
        );
      }
    } else if (kind == ScheduleKind.daily ||
        kind == ScheduleKind.weekly ||
        kind == ScheduleKind.monthly) {
      if (hasInterval || hasAt || hasIn) {
        throw const ScheduleValidationException(
          'Calendar schedule cannot be combined with interval or once fields.',
        );
      }
    }

    switch (kind) {
      case ScheduleKind.once:
        return _parseOnce(args, parsedZone, effectiveNow);
      case ScheduleKind.interval:
        return _parseInterval(args, parsedZone);
      case ScheduleKind.daily:
        return _parseDaily(args, parsedZone);
      case ScheduleKind.weekly:
        return _parseWeekly(args, parsedZone);
      case ScheduleKind.monthly:
        return _parseMonthly(args, parsedZone);
    }
  }

  static ScheduleDefinition _parseOnce(
    Map<String, dynamic> args,
    ScheduleZone zone,
    DateTime now,
  ) {
    final atVal = args['at']?.toString().trim();
    final inVal = args['in']?.toString().trim();
    final timeVal = args['time']?.toString().trim();

    if (atVal != null && atVal.isNotEmpty) {
      final parsed = DateTime.tryParse(atVal);
      if (parsed == null) {
        throw ScheduleValidationException(
          'Could not parse absolute time "$atVal". Expected ISO-8601 format.',
        );
      }
      return ScheduleDefinition(
        kind: ScheduleKind.once,
        zone: zone.raw,
        onceAt: _absoluteInstantInZone(parsed, zone),
      );
    }

    if (inVal != null && inVal.isNotEmpty) {
      final duration = _parseRelativeDuration(inVal);
      return ScheduleDefinition(
        kind: ScheduleKind.once,
        zone: zone.raw,
        onceIn: duration,
        onceAt: now.add(duration),
      );
    }

    if (timeVal != null && timeVal.isNotEmpty) {
      // Could be "in X minutes" or ISO-8601
      if (_isRelativeString(timeVal)) {
        final duration = _parseRelativeDuration(timeVal);
        return ScheduleDefinition(
          kind: ScheduleKind.once,
          zone: zone.raw,
          onceIn: duration,
          onceAt: now.add(duration),
        );
      }
      final parsed = DateTime.tryParse(timeVal);
      if (parsed != null) {
        return ScheduleDefinition(
          kind: ScheduleKind.once,
          zone: zone.raw,
          onceAt: _absoluteInstantInZone(parsed, zone),
        );
      }
      throw ScheduleValidationException(
        'Could not parse time "$timeVal". Please use ISO-8601 format or "in <n> <minutes|hours|days>".',
      );
    }

    throw const ScheduleValidationException(
      'Once schedule requires "at" (ISO-8601) or "in" (<n> <minutes|hours|days>).',
    );
  }

  /// An ISO-8601 value with an explicit offset (or `Z`) is an exact instant.
  /// Without one, `DateTime.tryParse` yields host-local components; they are
  /// reinterpreted as wall-clock time in the schedule's [zone] (Decision D3).
  static DateTime _absoluteInstantInZone(DateTime parsed, ScheduleZone zone) {
    if (parsed.isUtc) return parsed;
    return zone.wallClockToUtc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
    );
  }

  static void _ensureWithinMaxPeriod(Duration period, String value) {
    if (period > maxPeriod) _rejectBeyondMaxPeriod(value);
  }

  static Never _rejectBeyondMaxPeriod(String value) =>
      throw ScheduleValidationException(
        'Duration "$value" exceeds the maximum of ${maxPeriod.inDays} days.',
      );

  static ScheduleDefinition _parseInterval(
    Map<String, dynamic> args,
    ScheduleZone zone,
  ) {
    int? intervalMinutes;

    if (args['interval_minutes'] != null) {
      final raw = args['interval_minutes'];
      intervalMinutes = raw is int ? raw : int.tryParse(raw.toString().trim());
    } else if (args['every'] != null || args['interval'] != null) {
      final raw = (args['every'] ?? args['interval']).toString().trim();
      intervalMinutes = _parseEveryToMinutes(raw);
    }

    if (intervalMinutes == null || intervalMinutes <= 0) {
      throw const ScheduleValidationException(
        'Interval schedule requires positive "interval_minutes" or "every <n> <minutes|hours|days>".',
      );
    }
    // Compare in minutes: a Duration this large would overflow first.
    if (intervalMinutes > maxPeriod.inMinutes) {
      _rejectBeyondMaxPeriod('$intervalMinutes minutes');
    }

    return ScheduleDefinition(
      kind: ScheduleKind.interval,
      intervalMinutes: intervalMinutes,
      zone: zone.raw,
    );
  }

  static ScheduleDefinition _parseDaily(
    Map<String, dynamic> args,
    ScheduleZone zone,
  ) {
    final timeStr = _validateAndExtractTime(args['time']);
    return ScheduleDefinition(
      kind: ScheduleKind.daily,
      atTime: timeStr,
      zone: zone.raw,
    );
  }

  static ScheduleDefinition _parseWeekly(
    Map<String, dynamic> args,
    ScheduleZone zone,
  ) {
    final timeStr = _validateAndExtractTime(args['time']);
    final rawWeekdays = args['weekdays'];
    if (rawWeekdays == null) {
      throw const ScheduleValidationException(
        'Weekly schedule requires "weekdays" (one or more of: mon, tue, wed, thu, fri, sat, sun).',
      );
    }

    final List<String> list = [];
    if (rawWeekdays is List) {
      for (final item in rawWeekdays) {
        list.add(item.toString().trim().toLowerCase());
      }
    } else if (rawWeekdays is String) {
      for (final item in rawWeekdays.split(',')) {
        final t = item.trim().toLowerCase();
        if (t.isNotEmpty) list.add(t);
      }
    }

    final parsedWeekdays = <int>{};
    for (final dayStr in list) {
      final dayNum = _weekdayMap[dayStr];
      if (dayNum == null) {
        throw ScheduleValidationException(
          'Invalid weekday "$dayStr". Accepted weekdays are: mon, tue, wed, thu, fri, sat, sun.',
        );
      }
      parsedWeekdays.add(dayNum);
    }

    if (parsedWeekdays.isEmpty) {
      throw const ScheduleValidationException(
        'Weekly schedule requires at least one valid weekday in "weekdays".',
      );
    }

    final sortedWeekdays = (parsedWeekdays.toList()..sort())
        .map((n) => _weekdayNames[n]!)
        .toList();

    return ScheduleDefinition(
      kind: ScheduleKind.weekly,
      atTime: timeStr,
      weekdays: sortedWeekdays,
      zone: zone.raw,
    );
  }

  static ScheduleDefinition _parseMonthly(
    Map<String, dynamic> args,
    ScheduleZone zone,
  ) {
    final timeStr = _validateAndExtractTime(args['time']);
    final rawDay = args['day_of_month'] ?? args['month_day'];
    if (rawDay == null) {
      throw const ScheduleValidationException(
        'Monthly schedule requires "day_of_month" (1..31).',
      );
    }

    final day = rawDay is int ? rawDay : int.tryParse(rawDay.toString().trim());
    if (day == null || day < 1 || day > 31) {
      throw ScheduleValidationException(
        'Invalid day_of_month "$rawDay". Must be an integer between 1 and 31.',
      );
    }

    return ScheduleDefinition(
      kind: ScheduleKind.monthly,
      atTime: timeStr,
      monthDay: day,
      zone: zone.raw,
    );
  }

  static String _validateAndExtractTime(dynamic rawTime) {
    if (rawTime == null) {
      throw const ScheduleValidationException(
        'Calendar schedule requires "time" in 24-hour wall-clock format "HH:MM" (00:00 to 23:59).',
      );
    }
    final timeStr = rawTime.toString().trim();
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(timeStr)) {
      throw ScheduleValidationException(
        'Invalid time "$timeStr". Expected 24-hour wall-clock format "HH:MM" (00:00 to 23:59).',
      );
    }
    return timeStr;
  }

  static bool _isRelativeString(String value) {
    final trimmed = value.trim().toLowerCase();
    return trimmed.startsWith('in ') ||
        RegExp(r'^\d+\s*(minute|minutes|hour|hours|day|days|second|seconds)$')
            .hasMatch(trimmed);
  }

  static Duration _parseRelativeDuration(String value) {
    var trimmed = value.trim().toLowerCase();
    if (trimmed.startsWith('in ')) {
      trimmed = trimmed.substring(3).trim();
    }
    final match = RegExp(r'^(\d+)\s*([a-zA-Z]+)$').firstMatch(trimmed);
    if (match == null) {
      throw ScheduleValidationException(
        'Could not parse relative duration "$value". Expected format: "in <n> <minutes|hours|days>".',
      );
    }
    final amount = int.tryParse(match.group(1)!);
    final unit = match.group(2)!.toLowerCase();
    if (amount == null || amount <= 0) {
      throw ScheduleValidationException(
        'Duration amount must be a positive integer in "$value".',
      );
    }

    // Guard before multiplying so a huge amount cannot overflow.
    if (amount > maxPeriod.inMinutes) {
      _rejectBeyondMaxPeriod(value);
    }
    final Duration? duration = switch (unit) {
      'minute' || 'minutes' => Duration(minutes: amount),
      'hour' || 'hours' => Duration(hours: amount),
      'day' || 'days' => Duration(days: amount),
      // Legacy one-shot unit kept for unchanged once behavior (B-D4) and
      // replayed pre-merge calls; intervals stay minutes/hours/days.
      'second' || 'seconds' => Duration(seconds: amount),
      _ => null,
    };
    if (duration != null) {
      _ensureWithinMaxPeriod(duration, value);
      return duration;
    }

    throw ScheduleValidationException(
      'Unknown duration unit "$unit" in "$value". Accepted units are: minutes, hours, days.',
    );
  }

  static int _parseEveryToMinutes(String value) {
    var trimmed = value.trim().toLowerCase();
    if (trimmed.startsWith('every ')) {
      trimmed = trimmed.substring(6).trim();
    }
    final match = RegExp(r'^(\d+)\s*([a-zA-Z]+)$').firstMatch(trimmed);
    if (match == null) {
      throw ScheduleValidationException(
        'Could not parse interval "$value". Expected format: "every <n> <minutes|hours|days>".',
      );
    }
    final amount = int.tryParse(match.group(1)!);
    final unit = match.group(2)!.toLowerCase();
    if (amount == null || amount <= 0) {
      throw ScheduleValidationException(
        'Interval amount must be a positive integer in "$value".',
      );
    }

    if (amount > maxPeriod.inMinutes) {
      _rejectBeyondMaxPeriod(value);
    }
    final int? minutes = switch (unit) {
      'minute' || 'minutes' => amount,
      'hour' || 'hours' => amount * 60,
      'day' || 'days' => amount * 24 * 60,
      _ => null,
    };
    if (minutes != null) {
      _ensureWithinMaxPeriod(Duration(minutes: minutes), value);
      return minutes;
    }

    throw ScheduleValidationException(
      'Unknown interval unit "$unit" in "$value". Accepted units are: minutes, hours, days.',
    );
  }

  /// Argument keys that each select one schedule field; a key of a group
  /// replaces every alias of that group when merging (see [mergeUpdateArgs]).
  static const List<Set<String>> _fieldGroups = [
    {'at', 'in', 'time'},
    {'every', 'interval_minutes', 'interval'},
    {'weekdays'},
    {'day_of_month', 'month_day'},
    {'zone'},
  ];

  /// Every argument key that describes a schedule definition.
  static final Set<String> definitionKeys = {
    'kind',
    for (final group in _fieldGroups) ...group,
  };

  /// This definition as [parse]-compatible arguments.
  Map<String, dynamic> toArgs() => {
    'kind': kind.name,
    'zone': zone,
    if (kind == ScheduleKind.once && onceAt != null)
      'at': onceAt!.toUtc().toIso8601String(),
    if (intervalMinutes != null) 'interval_minutes': intervalMinutes,
    if (atTime != null) 'time': atTime,
    if (weekdays != null && weekdays!.isNotEmpty) 'weekdays': weekdays,
    if (monthDay != null) 'day_of_month': monthDay,
  };

  /// Merges a partial `update` (Decision D10) over [existing].
  ///
  /// When [update] names a `kind`, it is a complete replacement definition.
  /// Otherwise the existing kind and fields are kept and only the supplied
  /// fields change, so moving a weekly schedule to a new `time` stays weekly
  /// instead of being re-inferred as a different shape.
  static Map<String, dynamic> mergeUpdateArgs(
    ScheduleDefinition existing,
    Map<String, dynamic> update,
  ) {
    final supplied = {
      for (final entry in withoutAbsentValues(update).entries)
        if (definitionKeys.contains(entry.key)) entry.key: entry.value,
    };
    if (supplied.containsKey('kind')) return supplied;
    final merged = existing.toArgs();
    for (final group in _fieldGroups) {
      if (group.any(supplied.containsKey)) {
        merged.removeWhere((key, _) => group.contains(key));
      }
    }
    return merged..addAll(supplied);
  }

  /// Generates a human recurrence summary (Decision D9).
  String get humanRecurrenceSummary {
    switch (kind) {
      case ScheduleKind.once:
        if (onceIn != null) {
          return 'once in ${_formatDuration(onceIn!)}';
        }
        if (onceAt != null) {
          final sz = ScheduleZone.parse(zone);
          return 'once at ${sz.formatInstant(onceAt!)}';
        }
        return 'once';
      case ScheduleKind.interval:
        return 'every ${_formatIntervalMinutes(intervalMinutes!)}';
      case ScheduleKind.daily:
        return 'daily at $atTime';
      case ScheduleKind.weekly:
        return 'weekly on ${(weekdays ?? []).join(', ')} at $atTime';
      case ScheduleKind.monthly:
        return 'monthly on day $monthDay at $atTime';
    }
  }

  static String _formatDuration(Duration d) {
    if (d.inDays > 0 && d.inMinutes % (24 * 60) == 0) {
      return '${d.inDays} ${d.inDays == 1 ? 'day' : 'days'}';
    }
    if (d.inHours > 0 && d.inMinutes % 60 == 0) {
      return '${d.inHours} ${d.inHours == 1 ? 'hour' : 'hours'}';
    }
    if (d.inMinutes > 0 && d.inSeconds % 60 == 0) {
      return '${d.inMinutes} ${d.inMinutes == 1 ? 'minute' : 'minutes'}';
    }
    return '${d.inSeconds} ${d.inSeconds == 1 ? 'second' : 'seconds'}';
  }

  static String _formatIntervalMinutes(int minutes) {
    if (minutes % (24 * 60) == 0) {
      final days = minutes ~/ (24 * 60);
      return '$days ${days == 1 ? 'day' : 'days'}';
    }
    if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return '$hours ${hours == 1 ? 'hour' : 'hours'}';
    }
    return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
  }
}

/// Computes the next occurrence instant (in UTC) for a schedule definition.
class OccurrenceCalculator {
  /// Computes the next occurrence strictly after [from] (or at parsed instant for `once`).
  ///
  /// For [ScheduleKind.interval], [previousRunAt] is used as the anchor if provided.
  static DateTime computeNextOccurrence(
    ScheduleDefinition schedule, {
    required DateTime from,
    DateTime? previousRunAt,
    @visibleForTesting ScheduleZone? zoneOverride,
  }) {
    final fromUtc = from.toUtc();
    final zone = zoneOverride ?? ScheduleZone.parse(schedule.zone);

    switch (schedule.kind) {
      case ScheduleKind.once:
        if (schedule.onceAt != null) {
          return schedule.onceAt!;
        }
        if (schedule.onceIn != null) {
          return fromUtc.add(schedule.onceIn!);
        }
        return fromUtc;

      case ScheduleKind.interval:
        final duration = Duration(minutes: schedule.intervalMinutes!);
        if (previousRunAt != null) {
          final prevUtc = previousRunAt.toUtc();
          if (fromUtc.isBefore(prevUtc)) {
            return prevUtc.add(duration);
          }
          final diffUs = fromUtc.difference(prevUtc).inMicroseconds;
          final stepUs = duration.inMicroseconds;
          final steps = diffUs ~/ stepUs;
          var candidate = prevUtc.add(Duration(microseconds: steps * stepUs));
          while (!candidate.isAfter(fromUtc)) {
            candidate = candidate.add(duration);
          }
          return candidate;
        }
        return fromUtc.add(duration);

      case ScheduleKind.daily:
        return _computeNextDaily(schedule, fromUtc, zone);

      case ScheduleKind.weekly:
        return _computeNextWeekly(schedule, fromUtc, zone);

      case ScheduleKind.monthly:
        return _computeNextMonthly(schedule, fromUtc, zone);
    }
  }

  static DateTime _computeNextDaily(
    ScheduleDefinition schedule,
    DateTime fromUtc,
    ScheduleZone zone,
  ) {
    final parts = schedule.atTime!.split(':');
    final targetHour = int.parse(parts[0]);
    final targetMinute = int.parse(parts[1]);

    final zonedFrom = zone.toZoned(fromUtc);
    final todayCandidate = zone.wallClockToUtc(
      zonedFrom.year,
      zonedFrom.month,
      zonedFrom.day,
      targetHour,
      targetMinute,
    );

    if (todayCandidate.isAfter(fromUtc)) {
      return todayCandidate;
    }

    // Tomorrow wall clock in schedule zone.
    final tomorrowDate = DateTime.utc(zonedFrom.year, zonedFrom.month, zonedFrom.day)
        .add(const Duration(days: 1));
    return zone.wallClockToUtc(
      tomorrowDate.year,
      tomorrowDate.month,
      tomorrowDate.day,
      targetHour,
      targetMinute,
    );
  }

  static DateTime _computeNextWeekly(
    ScheduleDefinition schedule,
    DateTime fromUtc,
    ScheduleZone zone,
  ) {
    final parts = schedule.atTime!.split(':');
    final targetHour = int.parse(parts[0]);
    final targetMinute = int.parse(parts[1]);

    final targetWeekdays = schedule.weekdays!
        .map((w) => _weekdayMap[w.toLowerCase()]!)
        .toSet();

    final zonedFrom = zone.toZoned(fromUtc);
    for (int offset = 0; offset <= 7; offset++) {
      final checkDate = DateTime.utc(zonedFrom.year, zonedFrom.month, zonedFrom.day)
          .add(Duration(days: offset));
      if (targetWeekdays.contains(checkDate.weekday)) {
        final candidateUtc = zone.wallClockToUtc(
          checkDate.year,
          checkDate.month,
          checkDate.day,
          targetHour,
          targetMinute,
        );
        if (candidateUtc.isAfter(fromUtc)) {
          return candidateUtc;
        }
      }
    }

    throw StateError('Could not compute next weekly occurrence');
  }

  static DateTime _computeNextMonthly(
    ScheduleDefinition schedule,
    DateTime fromUtc,
    ScheduleZone zone,
  ) {
    final parts = schedule.atTime!.split(':');
    final targetHour = int.parse(parts[0]);
    final targetMinute = int.parse(parts[1]);
    final targetDay = schedule.monthDay!;

    final zonedFrom = zone.toZoned(fromUtc);
    final curYear = zonedFrom.year;
    final curMonth = zonedFrom.month;

    // Search future months (skipping months that lack targetDay).
    for (int m = 0; m < 48; m++) {
      final checkMonth = ((curMonth - 1 + m) % 12) + 1;
      final checkYear = curYear + ((curMonth - 1 + m) ~/ 12);
      final daysInMonth = DateTime.utc(checkYear, checkMonth + 1, 0).day;
      if (daysInMonth >= targetDay) {
        final candidateUtc = zone.wallClockToUtc(
          checkYear,
          checkMonth,
          targetDay,
          targetHour,
          targetMinute,
        );
        if (candidateUtc.isAfter(fromUtc)) {
          return candidateUtc;
        }
      }
    }

    throw StateError('Could not compute next monthly occurrence');
  }

  /// Computes the most recent due instant on or before [now] that should have run (Decision B-D2).
  ///
  /// For [ScheduleKind.interval], steps forward from [nextRunAt] or [previousRunAt]
  /// up to the latest slot on or before [now].
  /// For calendar kinds (daily, weekly, monthly), searches backwards from [now] for the
  /// most recent scheduled wall-clock slot.
  /// If [nextRunAt] is provided and is strictly after the computed past candidate,
  /// [nextRunAt] is returned (it had not been scheduled before that point).
  static DateTime computeMostRecentDueInstant(
    ScheduleDefinition schedule, {
    required DateTime now,
    DateTime? previousRunAt,
    DateTime? nextRunAt,
    @visibleForTesting ScheduleZone? zoneOverride,
  }) {
    final nowUtc = now.toUtc();
    final zone = zoneOverride ?? ScheduleZone.parse(schedule.zone);

    DateTime candidate;
    switch (schedule.kind) {
      case ScheduleKind.once:
        return nextRunAt ?? (schedule.onceAt ?? nowUtc);

      case ScheduleKind.interval:
        final duration = Duration(minutes: schedule.intervalMinutes!);
        final start = nextRunAt ??
            (previousRunAt != null
                ? previousRunAt.toUtc().add(duration)
                : nowUtc);
        if (start.isAfter(nowUtc)) {
          return start;
        }
        final diffUs = nowUtc.difference(start).inMicroseconds;
        final stepUs = duration.inMicroseconds;
        final steps = diffUs ~/ stepUs;
        var cur = start.add(Duration(microseconds: steps * stepUs));
        while (!cur.add(duration).isAfter(nowUtc)) {
          cur = cur.add(duration);
        }
        candidate = cur;

      case ScheduleKind.daily:
        candidate = _computePreviousDaily(schedule, nowUtc, zone);

      case ScheduleKind.weekly:
        candidate = _computePreviousWeekly(schedule, nowUtc, zone);

      case ScheduleKind.monthly:
        candidate = _computePreviousMonthly(schedule, nowUtc, zone);
    }

    if (nextRunAt != null && candidate.isBefore(nextRunAt.toUtc())) {
      return nextRunAt.toUtc();
    }
    return candidate;
  }

  static DateTime _computePreviousDaily(
    ScheduleDefinition schedule,
    DateTime nowUtc,
    ScheduleZone zone,
  ) {
    final parts = schedule.atTime!.split(':');
    final targetHour = int.parse(parts[0]);
    final targetMinute = int.parse(parts[1]);

    final zonedNow = zone.toZoned(nowUtc);
    final todayCandidate = zone.wallClockToUtc(
      zonedNow.year,
      zonedNow.month,
      zonedNow.day,
      targetHour,
      targetMinute,
    );

    if (!todayCandidate.isAfter(nowUtc)) {
      return todayCandidate;
    }

    final yesterdayDate =
        DateTime.utc(zonedNow.year, zonedNow.month, zonedNow.day)
            .subtract(const Duration(days: 1));
    return zone.wallClockToUtc(
      yesterdayDate.year,
      yesterdayDate.month,
      yesterdayDate.day,
      targetHour,
      targetMinute,
    );
  }

  static DateTime _computePreviousWeekly(
    ScheduleDefinition schedule,
    DateTime nowUtc,
    ScheduleZone zone,
  ) {
    final parts = schedule.atTime!.split(':');
    final targetHour = int.parse(parts[0]);
    final targetMinute = int.parse(parts[1]);

    final targetWeekdays = schedule.weekdays!
        .map((w) => _weekdayMap[w.toLowerCase()]!)
        .toSet();

    final zonedNow = zone.toZoned(nowUtc);
    for (int offset = 0; offset <= 7; offset++) {
      final checkDate =
          DateTime.utc(zonedNow.year, zonedNow.month, zonedNow.day)
              .subtract(Duration(days: offset));
      if (targetWeekdays.contains(checkDate.weekday)) {
        final candidateUtc = zone.wallClockToUtc(
          checkDate.year,
          checkDate.month,
          checkDate.day,
          targetHour,
          targetMinute,
        );
        if (!candidateUtc.isAfter(nowUtc)) {
          return candidateUtc;
        }
      }
    }

    throw StateError('Could not compute previous weekly occurrence');
  }

  static DateTime _computePreviousMonthly(
    ScheduleDefinition schedule,
    DateTime nowUtc,
    ScheduleZone zone,
  ) {
    final parts = schedule.atTime!.split(':');
    final targetHour = int.parse(parts[0]);
    final targetMinute = int.parse(parts[1]);
    final targetDay = schedule.monthDay!;

    final zonedNow = zone.toZoned(nowUtc);
    final totalMonths = zonedNow.year * 12 + (zonedNow.month - 1);

    for (int m = 0; m < 48; m++) {
      final monthIndex = totalMonths - m;
      final checkYear = monthIndex ~/ 12;
      final checkMonth = (monthIndex % 12) + 1;
      final daysInMonth = DateTime.utc(checkYear, checkMonth + 1, 0).day;
      if (daysInMonth >= targetDay) {
        final candidateUtc = zone.wallClockToUtc(
          checkYear,
          checkMonth,
          targetDay,
          targetHour,
          targetMinute,
        );
        if (!candidateUtc.isAfter(nowUtc)) {
          return candidateUtc;
        }
      }
    }

    throw StateError('Could not compute previous monthly occurrence');
  }
}

/// Policy for computing recurrence grace window and startup missed-occurrence policy (Decision B-D2).
class RecurrenceGracePolicy {
  static const Duration minGrace = Duration(seconds: 120);
  static const Duration maxGrace = Duration(hours: 2);

  /// Computes the grace window for a schedule definition.
  ///
  /// Grace is half the period clamped to [120s, 2h].
  static Duration computeGraceWindow(ScheduleDefinition definition) {
    Duration period;
    switch (definition.kind) {
      case ScheduleKind.once:
        return const Duration(minutes: 5);
      case ScheduleKind.interval:
        period = Duration(minutes: definition.intervalMinutes ?? 1);
      case ScheduleKind.daily:
        period = const Duration(days: 1);
      case ScheduleKind.weekly:
        period = const Duration(days: 7);
      case ScheduleKind.monthly:
        period = const Duration(days: 30);
    }
    final halfPeriodSeconds = period.inSeconds ~/ 2;
    final clampedSeconds = halfPeriodSeconds.clamp(
      minGrace.inSeconds,
      maxGrace.inSeconds,
    );
    return Duration(seconds: clampedSeconds);
  }
}

/// Durable scheduled task entity (Decision D8).
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
    );
  }
}
