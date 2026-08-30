import 'package:meta/meta.dart';

/// Durable identity of one persisted conversation row (`messages.id`).
///
/// Compaction ranges must use this type, never transient in-memory list indices.
@immutable
class CompactionMessageIdentity implements Comparable<CompactionMessageIdentity> {
  final int rowId;

  const CompactionMessageIdentity(this.rowId) : assert(rowId > 0, 'rowId must be positive');

  @override
  int compareTo(CompactionMessageIdentity other) => rowId.compareTo(other.rowId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionMessageIdentity &&
          runtimeType == other.runtimeType &&
          rowId == other.rowId;

  @override
  int get hashCode => rowId.hashCode;

  @override
  String toString() => 'CompactionMessageIdentity(rowId: $rowId)';
}

/// Inclusive durable message range for summarized head or retained tail.
@immutable
class CompactionMessageRange {
  final CompactionMessageIdentity start;
  final CompactionMessageIdentity end;

  CompactionMessageRange({
    required this.start,
    required this.end,
  }) : assert(
         start.rowId <= end.rowId,
         'start identity must not follow end identity',
       );

  bool contains(CompactionMessageIdentity identity) =>
      identity.rowId >= start.rowId && identity.rowId <= end.rowId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionMessageRange &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'CompactionMessageRange($start..$end)';
}

/// Monotonic canonical history revision used for snapshot CAS (Task 53b).
@immutable
class CompactionHistoryRevision implements Comparable<CompactionHistoryRevision> {
  final int value;

  const CompactionHistoryRevision(this.value)
    : assert(value >= 0, 'revision must be non-negative');

  @override
  int compareTo(CompactionHistoryRevision other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionHistoryRevision &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'CompactionHistoryRevision($value)';
}
