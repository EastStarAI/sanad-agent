import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'runtime_context.dart' show isProcessRunning;

import 'local_gateway_credential.dart';
import 'startup_probe.dart';

/// What the post-restart probe observed on the Agent port.
enum AgentRestartProbeOutcome {
  /// A *new* Home owner proves the lease identity, and `/health` agrees.
  matched,

  /// A healthy Agent answers with another identity, so waiting cannot help.
  foreignIdentity,

  /// Another live process owns the Sanad Home instead of this lease.
  foreignHolder,

  /// Nothing proved a replacement owner before the deadline.
  unanswered,
}

/// The owner record the daemon writes beside the Home lock.
///
/// It is the only local surface that names *which generation* of the daemon
/// owns the mutable state root: `/health` carries the launcher identity, but that
/// identity survives a supervised respawn because the supervisor and its
/// environment do. A restart is therefore proved by a new recorded owner, not by
/// the identity alone.
class AgentOwnershipSnapshot {
  const AgentOwnershipSnapshot({
    required this.pid,
    required this.launcherId,
    required this.runtimeNonce,
  });

  /// Recorded owner process id.
  final int? pid;

  /// Recorded `launcher_id`; empty for an unmanaged runtime.
  final String launcherId;

  /// Recorded `runtime_nonce`; empty for an unmanaged runtime.
  final String runtimeNonce;

  bool get isManaged => launcherId.isNotEmpty;

  /// Bounded, secret-free description of the recorded holder.
  String describe() {
    final owner = pid == null ? 'no pid' : 'pid $pid';
    if (!isManaged) return '$owner (unmanaged)';
    return '$owner (launcher $launcherId, nonce $runtimeNonce)';
  }
}

/// The identity evidence behind one post-restart probe result.
class AgentRestartProbeResult {
  const AgentRestartProbeResult._(
    this.outcome, {
    this.observedLauncherId,
    this.observedRuntimeNonce,
    this.observedWorkspaceHash,
    this.expectedWorkspaceHash,
    this.previousDaemonPid,
    this.recordedHolder,
  });

  final AgentRestartProbeOutcome outcome;

  /// `dev_launcher_id` the answering Agent reported, when it reported one.
  final String? observedLauncherId;

  /// `dev_runtime_nonce` the answering Agent reported, when it reported one.
  final String? observedRuntimeNonce;

  /// `workspace_hash` the answering Agent reported, when it reported one.
  final String? observedWorkspaceHash;

  /// `workspace_hash` the caller expected, kept so a disagreement is named.
  ///
  /// It is evidence, not a gate: the launcher id and runtime nonce identify the
  /// runtime, and a source handoff legitimately changes the hash.
  final String? expectedWorkspaceHash;

  /// Daemon pid recorded before the restart request; null when unrecorded.
  final int? previousDaemonPid;

  /// Last Home owner record observed, when one was readable.
  final AgentOwnershipSnapshot? recordedHolder;

  bool get matched => outcome == AgentRestartProbeOutcome.matched;

  bool get sawForeignIdentity =>
      outcome == AgentRestartProbeOutcome.foreignIdentity;

  bool get sawForeignHolder =>
      outcome == AgentRestartProbeOutcome.foreignHolder;

  /// Bounded, secret-free evidence for one failure line.
  String describeObserved({int? pid}) {
    final parts = <String>[
      if (pid != null) 'pid $pid',
      'launcher ${observedLauncherId ?? 'none'}',
      'nonce ${observedRuntimeNonce ?? 'none'}',
      if (observedWorkspaceHash != null) 'workspace $observedWorkspaceHash',
      if (expectedWorkspaceHash != null &&
          expectedWorkspaceHash != observedWorkspaceHash)
        'expected workspace $expectedWorkspaceHash',
    ];
    return parts.join(', ');
  }

  /// Bounded evidence that no replacement owner appeared.
  String describeStalledRestart() {
    final previous = previousDaemonPid;
    final holder = recordedHolder;
    return 'the pre-restart owner was '
        '${previous == null ? 'not recorded' : 'pid $previous'}, and the Home '
        'owner is now ${holder == null ? 'not recorded' : holder.describe()}';
  }
}

/// One authenticated loopback `GET /health`, or null when nothing usable
/// answered.
///
/// The credential is attached when the Home has a readable one. A Home without
/// it yields an unauthenticated request that the real gateway refuses and that a
/// test server can answer, so the probe never becomes a credential oracle.
Future<Map<String, dynamic>?> readAgentHealthDocument(
  int port,
  String sanadHome, {
  Duration timeout = const Duration(milliseconds: 250),
}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    try {
      await authorizeLocalGatewayRequest(request, sanadHome);
    } on Object {
      // An unreadable Home credential is discovery evidence, not a failure of
      // the probe: the request still proves whether something answers.
    }
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    return Map<String, dynamic>.from(decoded);
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Reads the Home's recorded owner (`.runtime-owner.json`), or null if absent.
///
/// The record carries a pid and the launcher id/nonce correlation evidence and
/// no credential. An unreadable or foreign-schema record is treated as absent
/// rather than guessed at.
Future<AgentOwnershipSnapshot?> readAgentOwnershipSnapshot(
  String sanadHome,
) async {
  try {
    final normalized = sanadHome.replaceAll(RegExp(r'[\\/]+$'), '');
    final file = File(
      '$normalized${Platform.pathSeparator}.runtime-owner.json',
    );
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['schema'] != 1) return null;
    final rawPid = decoded['pid'];
    final recordedPid = rawPid is int ? rawPid : int.tryParse('$rawPid');
    return AgentOwnershipSnapshot(
      pid: recordedPid != null && recordedPid > 0 ? recordedPid : null,
      launcherId: decoded['launcher_id']?.toString().trim() ?? '',
      runtimeNonce: decoded['runtime_nonce']?.toString().trim() ?? '',
    );
  } on Object {
    return null;
  }
}

/// One bounded line naming the Home's recorded owner, or null when unreadable.
///
/// This is the answer to "who holds this Home", which a refusal used to omit
/// entirely: the operator saw an ownership class but not the process or launcher
/// that owned the state root.
Future<String?> describeHomeHolder(String sanadHome) async {
  final holder = await readAgentOwnershipSnapshot(sanadHome);
  if (holder == null) return null;
  return 'Home holder: ${holder.describe()}';
}

/// The daemon pid recorded before a restart request.
///
/// The Home owner record is authoritative because the daemon writes it after it
/// wins the lock; the endpoint record is the fallback for a Home whose daemon
/// predates that record. Both are evidence, never authentication.
Future<int?> readRestartBaselineDaemonPid(String sanadHome, int port) async {
  final holder = await readAgentOwnershipSnapshot(sanadHome);
  if (holder?.pid != null) return holder!.pid;
  return readRecordedDaemonPid(sanadHome, port);
}

/// Waits for the restarted Agent to prove it is the *replacement*, not the
/// daemon that was asked to exit.
///
/// Identity alone cannot answer that: a supervised respawn keeps the same
/// launcher id and runtime nonce, so the daemon that received `/restart` still
/// looks like the right owner while it is shutting down. One live test reported
/// `restarted and healthy` 17–20 ms after the request — 5.9 s before the
/// replacement existed — and in the original incident that false success hid a
/// complete loss of the Home to a foreign daemon.
///
/// A restart therefore needs all three:
///
/// 1. the Home owner record names a pid different from [previousDaemonPid];
/// 2. that record carries this lease's launcher id and runtime nonce;
/// 3. `/health` reports the same identity.
///
/// A live owner that is *not* this lease ends the wait immediately and is
/// reported as [AgentRestartProbeOutcome.foreignHolder] with its pid and
/// launcher.
Future<AgentRestartProbeResult> waitForRestartedAgentIdentity({
  required int port,
  required String workspaceHash,
  required String launcherId,
  required String runtimeNonce,
  required String sanadHome,
  required int? previousDaemonPid,
  Duration timeout = const Duration(seconds: 30),
  Duration pollInterval = const Duration(milliseconds: 250),
  DateTime Function()? clock,
  Future<void> Function(Duration)? delay,
  Future<bool> Function(int pid) processRunning = isProcessRunning,
}) async {
  final now = clock ?? DateTime.now;
  final pause = delay ?? Future<void>.delayed;
  final deadline = now().add(timeout);
  AgentOwnershipSnapshot? lastHolder;
  Map<String, dynamic>? lastHealth;

  while (true) {
    final holder = await readAgentOwnershipSnapshot(sanadHome);
    if (holder != null) lastHolder = holder;
    final holderPid = holder?.pid;
    final holderIsOurs =
        holder != null &&
        holder.launcherId == launcherId &&
        holder.runtimeNonce == runtimeNonce;

    // A live owner with another identity holds the Home; no wait changes that.
    if (holderPid != null && !holderIsOurs && await processRunning(holderPid)) {
      return _failure(
        AgentRestartProbeOutcome.foreignHolder,
        previousDaemonPid: previousDaemonPid,
        holder: holder,
        health: null,
        workspaceHash: workspaceHash,
      );
    }

    final health = await readAgentHealthDocument(port, sanadHome);
    if (health != null) lastHealth = health;
    final healthIsHealthy = health != null && health['status'] == 'ok';
    final healthIsOurs =
        health != null &&
        matchesSanadDevAgentHealth(
          health,
          launcherId: launcherId,
          runtimeNonce: runtimeNonce,
        );

    // The replacement proves the restart only when a *new* Home owner carries
    // this lease's identity and the port answers with it.
    final replaced =
        holderPid != null &&
        (previousDaemonPid == null || holderPid != previousDaemonPid);
    if (replaced && holderIsOurs && healthIsHealthy && healthIsOurs) {
      return AgentRestartProbeResult._(
        AgentRestartProbeOutcome.matched,
        observedLauncherId: health['dev_launcher_id']?.toString(),
        observedRuntimeNonce: health['dev_runtime_nonce']?.toString(),
        observedWorkspaceHash: health['workspace_hash']?.toString(),
        expectedWorkspaceHash: workspaceHash,
        previousDaemonPid: previousDaemonPid,
        recordedHolder: holder,
      );
    }

    // A healthy answer that does not carry this lease's identity is a foreign
    // owner of the port, and waiting longer cannot change who answers.
    if (healthIsHealthy && !healthIsOurs) {
      return _failure(
        AgentRestartProbeOutcome.foreignIdentity,
        previousDaemonPid: previousDaemonPid,
        holder: lastHolder,
        health: health,
        workspaceHash: workspaceHash,
      );
    }

    if (!now().isBefore(deadline)) {
      return _failure(
        AgentRestartProbeOutcome.unanswered,
        previousDaemonPid: previousDaemonPid,
        holder: lastHolder,
        health: lastHealth,
        workspaceHash: workspaceHash,
      );
    }
    await pause(pollInterval);
  }
}

AgentRestartProbeResult _failure(
  AgentRestartProbeOutcome outcome, {
  required int? previousDaemonPid,
  required AgentOwnershipSnapshot? holder,
  required Map<String, dynamic>? health,
  required String workspaceHash,
}) => AgentRestartProbeResult._(
  outcome,
  observedLauncherId: health?['dev_launcher_id']?.toString(),
  observedRuntimeNonce: health?['dev_runtime_nonce']?.toString(),
  observedWorkspaceHash: health?['workspace_hash']?.toString(),
  expectedWorkspaceHash: workspaceHash,
  previousDaemonPid: previousDaemonPid,
  recordedHolder: holder,
);

/// The daemon PID a Home's endpoint record names for [port], when readable.
///
/// `/health` carries no process id, so this is the only local surface that can
/// name the process answering a port. It is diagnostic evidence only and never
/// carries a credential.
Future<int?> readRecordedDaemonPid(String sanadHome, int port) async {
  try {
    final normalized = sanadHome.replaceAll(RegExp(r'[\\/]+$'), '');
    final file = File(
      '$normalized${Platform.pathSeparator}.local_gateway_endpoint.json',
    );
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['schema'] != 1) return null;
    final rawPort = decoded['port'];
    final recordedPort = rawPort is int ? rawPort : int.tryParse('$rawPort');
    if (recordedPort != port) return null;
    final rawPid = decoded['pid'];
    final recordedPid = rawPid is int ? rawPid : int.tryParse('$rawPid');
    return recordedPid != null && recordedPid > 0 ? recordedPid : null;
  } on Object {
    return null;
  }
}
