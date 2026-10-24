/// One instant as the schedule protocol serializes it (Task 139 F4).
///
/// The Agent writes an absolute instant together with the offset it was computed
/// in — `2026-10-24T00:50:07+03:00` — and that offset is the only way a Client can
/// render a `local` schedule's wall clock: `local` means the **Agent's** local
/// zone, and the device may be remote, so the Client's own timezone is not an
/// answer.
///
/// [instant] is normalized to UTC so comparisons and ordering are unaffected;
/// [offset] keeps the wire token (`+03:00`, `-05:30`, `Z`) for presentation only.
/// Parsing is additive-tolerant: an instant without a readable offset keeps a
/// `null` offset and the surface falls back to the zone it was given.
class ScheduleInstant {
  const ScheduleInstant({required this.instant, this.offset});

  /// The absolute instant, in UTC.
  final DateTime instant;

  /// The offset token the Agent wrote with [instant], or `null` when the wire
  /// value carried none this Client can read.
  final String? offset;

  /// Parses a wire instant, or `null` when the value is absent or unreadable.
  static ScheduleInstant? tryParse(Object? value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final instant = DateTime.tryParse(raw);
    if (instant == null) return null;
    return ScheduleInstant(instant: instant.toUtc(), offset: _offsetOf(raw));
  }

  /// The UTC instant alone, for a model that keeps only the value.
  static DateTime? utcTryParse(Object? value) => tryParse(value)?.instant;

  static String? _offsetOf(String raw) {
    final match = RegExp(r'([+-]\d{2}:?\d{2}|[zZ])$').firstMatch(raw);
    return match?.group(1);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ScheduleInstant && other.instant == instant && other.offset == offset;

  @override
  int get hashCode => Object.hash(instant, offset);

  @override
  String toString() => 'ScheduleInstant(${instant.toIso8601String()}, offset: ${offset ?? 'none'})';
}
