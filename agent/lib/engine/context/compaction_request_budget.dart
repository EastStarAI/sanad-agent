import 'package:meta/meta.dart';
import 'package:sanad_agent/core/models/message.dart';

import '../adapters/llm_adapter.dart';
import '../compaction/compaction_enums.dart';

/// Measures one provider projection with the active route's own wire codec,
/// tools and request options (Task 118 Stage3A). Returns `null` when the
/// route exposes no wire measurement.
typedef CompactionWireMeter =
    Future<WireInputMeasurement?> Function(List<Message> projection);

/// Complete-request inputs measured before the retained tail is selected
/// (Task 118 Stage3A).
///
/// The post-compaction request is `fixed overhead + summary + retained tail`.
/// The fixed overhead is everything the request keeps intact: leading system
/// and runtime instructions plus the tool schemas.
@immutable
class CompactionRequestMeasurement {
  /// Leading system/runtime instructions plus tool schemas, as transmitted.
  final int fixedOverheadTokens;

  /// True when [fixedOverheadTokens] and [requestTokens] come from the route's
  /// wire codec rather than the provider-neutral fallback estimate.
  final bool wireMeasured;

  /// The complete current request, when measured on the wire: the wire
  /// estimate, or the newest proven provider receipt plus the estimated wire
  /// suffix after it (`mixed`).
  final int? requestTokens;
  final CompactionMeasurementKind requestKind;

  /// Transmitted cost of every candidate retained tail, when the active
  /// projection could be aligned with the timeline and measured.
  final CompactionTailCosts? tailCosts;

  const CompactionRequestMeasurement({
    required this.fixedOverheadTokens,
    required this.wireMeasured,
    this.requestTokens,
    this.requestKind = CompactionMeasurementKind.estimated,
    this.tailCosts,
  });
}

/// Transmitted cost of the retained tail that starts at one timeline index
/// (Task 118 Stage3A replay-aware selection).
///
/// [tokens] is the route's wire estimate of the tail plus the provider
/// attribution of its proven span: between the nearest proven receipt at or
/// after the tail start and the newest proven receipt, the provider-confirmed
/// input difference replaces the wire estimate, so replayed reasoning and
/// tool framing the estimator cannot see are counted at their actual cost.
@immutable
class CompactionTailCost {
  final int tokens;

  /// `mixed` when a provider-confirmed span is included, else `estimated`.
  final CompactionMeasurementKind kind;

  /// Provider-confirmed tokens of the proven span inside the tail.
  final int confirmedTokens;

  /// Opaque replay items (for example encrypted reasoning) outside a proven
  /// span. Their cost is unknown: neither zero nor priced from ciphertext.
  final int unprovenReplayItems;

  const CompactionTailCost({
    required this.tokens,
    required this.kind,
    this.confirmedTokens = 0,
    this.unprovenReplayItems = 0,
  });
}

/// Tail costs keyed by the timeline index where the tail starts. Indices are
/// measured from the newest row backward until a tail exceeds the target, so
/// a missing index is a tail that is already over budget.
@immutable
class CompactionTailCosts {
  final Map<int, CompactionTailCost> _byStart;

  /// Provider receipts proven against the current request.
  final int provenReceipts;

  CompactionTailCosts(
    Map<int, CompactionTailCost> byStart, {
    required this.provenReceipts,
  }) : _byStart = Map.unmodifiable(byStart);

  CompactionTailCost? operator [](int tailStartIndex) =>
      _byStart[tailStartIndex];
}

/// Budget decisions taken when the retained tail was selected.
@immutable
class CompactionSelectionBudget {
  final CompactionRequestMeasurement measurement;
  final int summaryReservationTokens;
  final int tailBudgetTokens;

  const CompactionSelectionBudget({
    required this.measurement,
    required this.summaryReservationTokens,
    required this.tailBudgetTokens,
  });
}

/// Leading system messages of a provider projection: the instructions the
/// post-compaction request keeps intact.
List<Message> leadingSystemMessages(List<Message> projection) {
  var count = 0;
  while (count < projection.length &&
      projection[count].role == MessageRole.system) {
    count++;
  }
  return projection.sublist(0, count);
}
