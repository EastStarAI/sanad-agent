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

  /// The complete current request, when measured on the wire.
  final int? requestTokens;
  final CompactionMeasurementKind requestKind;

  const CompactionRequestMeasurement({
    required this.fixedOverheadTokens,
    required this.wireMeasured,
    this.requestTokens,
    this.requestKind = CompactionMeasurementKind.estimated,
  });
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
