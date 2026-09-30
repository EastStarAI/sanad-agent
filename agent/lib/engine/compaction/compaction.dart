/// Provider-neutral compaction domain types (Plan 53a Gate A2).
///
/// These types carry no credentials, adapter response bodies, Flutter fields,
/// or [Message] instances. Persistence (53b) and engine logic (53c) share this
/// vocabulary without importing each other's implementation layers.
library;

export 'compaction_candidate.dart';
export 'compaction_enums.dart';
export 'compaction_identities.dart';
export 'compaction_metrics.dart';
export 'compaction_outcome.dart';
export 'compaction_pressure.dart';
export 'compaction_summary.dart';
