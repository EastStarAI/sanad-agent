part of '../../../sanad_dev_cli.dart';

/// Adopts a runtime record written before the primary checkout id became
/// path-only into its canonical `primary-<hash>` name.
///
/// A non-linked checkout used to name its record directory after the checked-out
/// branch, so detaching HEAD renamed the namespace mid-session and left the
/// previous record looking unclaimed. The rename is a same-filesystem directory
/// move: `apply-baseline.json`, `ui-driver-target.json`, and any retained refresh
/// log travel with it, nothing is copied or deleted, and an existing canonical
/// directory always wins.
///
/// It runs only from `run`, after the dry-run exit, so observation commands stay
/// strictly read-only. A failure is silent by design: the record is diagnostics,
/// the hash alias keeps a legacy record attributed either way, and a launch must
/// never fail because a diagnostics directory could not be renamed.
Future<void> adoptLegacyPrimaryRuntimeRecord(SanadDevRuntime runtime) async {
  if (runtime.isLinkedWorktree) return;
  final legacy = await legacyRuntimeRecordDirectory(runtime);
  if (legacy == null) return;
  try {
    await Directory(legacy).rename(runtime.runtimeDirectory);
  } on Object {
    // Diagnostics-only state: never fail a launch on an unadopted record.
  }
}
