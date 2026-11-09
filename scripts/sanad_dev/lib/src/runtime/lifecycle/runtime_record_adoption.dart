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
/// A live group is never renamed. The rename runs at the top of `run`, before any
/// liveness classification, so the legacy record, its Home endpoint, and any
/// launcher lease for the same worktree are re-verified first: a process that is
/// still running keeps its record where its own launcher wrote it, and adoption
/// waits for a launch where the legacy group is provably stopped.
///
/// It runs only from `run`, after the dry-run exit, so observation commands stay
/// strictly read-only. A failure is silent by design: the record is diagnostics,
/// the hash alias keeps a legacy record attributed either way, and a launch must
/// never fail because a diagnostics directory could not be renamed.
Future<void> adoptLegacyPrimaryRuntimeRecord(
  SanadDevRuntime runtime, {
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  if (runtime.isLinkedWorktree) return;
  final legacy = await legacyRuntimeRecordDirectory(runtime);
  if (legacy == null) return;
  if (await legacyRuntimeGroupIsLive(
    runtime,
    legacy,
    processRunning: processRunning,
  )) {
    return;
  }
  try {
    await Directory(legacy).rename(runtime.runtimeDirectory);
  } on Object {
    // Diagnostics-only state: never fail a launch on an unadopted record.
  }
}

/// Whether the legacy record at [legacyDirectory] still names a live process.
///
/// The checks are the ones `cleanup-orphans` uses before it deletes a record,
/// because both decisions rest on the same fact: a record is the last cheap
/// pointer to the process that wrote it. A recorded `agent_pid`/`client_pid`, the
/// owning Home's endpoint pid, or a launcher lease for this worktree that is
/// still running all keep the directory in place.
Future<bool> legacyRuntimeGroupIsLive(
  SanadDevRuntime runtime,
  String legacyDirectory, {
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final livePid = await firstLiveRecordedPid(
    await inventoryRecordedPids(legacyDirectory),
    processRunning: processRunning,
  );
  if (livePid != null) return true;
  final home = await readInventoryHomeState(
    runtime.sanadHome,
    processRunning: processRunning,
  );
  if (home.endpoint?.alive ?? false) return true;
  final workspaceHash = worktreeHashSuffix(runtime.workspaceRoot);
  for (final lease in home.leases) {
    final namesThisWorktree =
        lease.workspaceHash == workspaceHash ||
        equivalentPaths(lease.sourceRoot, runtime.workspaceRoot);
    if (namesThisWorktree && await processRunning(lease.launcherPid)) {
      return true;
    }
  }
  return false;
}
