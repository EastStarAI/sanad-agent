import 'package:meta/meta.dart';

/// Structured rolling summary for model projection only.
///
/// This is **not** a [Message] and must never be stored as `MessageRole.system`
/// or any user-visible transcript row.
@immutable
class CompactionInternalSummary {
  /// Anchor from the previous successful boundary, not a conversation message.
  final String? previousSummaryAnchor;

  final String currentGoal;
  final String? successCriteria;
  final String? constraints;
  final String? completedWork;
  final String? activeState;
  final String? decisions;
  final String? blockers;
  final String? filesAndPaths;
  final String? pendingAsks;
  final String? remainingWork;

  const CompactionInternalSummary({
    this.previousSummaryAnchor,
    required this.currentGoal,
    this.successCriteria,
    this.constraints,
    this.completedWork,
    this.activeState,
    this.decisions,
    this.blockers,
    this.filesAndPaths,
    this.pendingAsks,
    this.remainingWork,
  });

  /// Required sections validated before a boundary may activate.
  static const requiredSectionKeys = <String>['currentGoal', 'remainingWork'];

  /// Returns missing required section keys for [continuity validation].
  List<String> missingRequiredSections() {
    final missing = <String>[];
    if (currentGoal.trim().isEmpty) {
      missing.add('currentGoal');
    }
    if ((remainingWork ?? '').trim().isEmpty) {
      missing.add('remainingWork');
    }
    return missing;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionInternalSummary &&
          runtimeType == other.runtimeType &&
          previousSummaryAnchor == other.previousSummaryAnchor &&
          currentGoal == other.currentGoal &&
          successCriteria == other.successCriteria &&
          constraints == other.constraints &&
          completedWork == other.completedWork &&
          activeState == other.activeState &&
          decisions == other.decisions &&
          blockers == other.blockers &&
          filesAndPaths == other.filesAndPaths &&
          pendingAsks == other.pendingAsks &&
          remainingWork == other.remainingWork;

  @override
  int get hashCode => Object.hash(
    previousSummaryAnchor,
    currentGoal,
    successCriteria,
    constraints,
    completedWork,
    activeState,
    decisions,
    blockers,
    filesAndPaths,
    pendingAsks,
    remainingWork,
  );
}

/// Outcome of goal-preserving anchor coverage validation (Task 53c).
@immutable
class CompactionContinuityResult {
  final bool passed;
  final List<String> missingAnchors;
  final int repairAttempts;

  const CompactionContinuityResult({
    required this.passed,
    this.missingAnchors = const [],
    this.repairAttempts = 0,
  }) : assert(repairAttempts >= 0, 'repairAttempts must be non-negative');

  factory CompactionContinuityResult.fromSummary(
    CompactionInternalSummary summary, {
    List<String> extraMissingAnchors = const [],
    int repairAttempts = 0,
  }) {
    final missing = [
      ...summary.missingRequiredSections(),
      ...extraMissingAnchors,
    ];
    return CompactionContinuityResult(
      passed: missing.isEmpty,
      missingAnchors: missing,
      repairAttempts: repairAttempts,
    );
  }

  /// Validates explicit continuity state; use when constructing outside [fromSummary].
  factory CompactionContinuityResult.validated({
    required bool passed,
    List<String> missingAnchors = const [],
    int repairAttempts = 0,
  }) {
    assert(
      passed == missingAnchors.isEmpty,
      'passed requires empty missingAnchors',
    );
    return CompactionContinuityResult(
      passed: passed,
      missingAnchors: missingAnchors,
      repairAttempts: repairAttempts,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CompactionContinuityResult &&
          runtimeType == other.runtimeType &&
          passed == other.passed &&
          _listEquals(missingAnchors, other.missingAnchors) &&
          repairAttempts == other.repairAttempts;

  @override
  int get hashCode =>
      Object.hash(passed, Object.hashAll(missingAnchors), repairAttempts);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
