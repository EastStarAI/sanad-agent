import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'local_gateway_credential.dart';
import 'startup_probe.dart';

/// What the post-restart identity probe observed on the Agent port.
enum AgentRestartProbeOutcome {
  /// The Agent answering carries the live launcher id and runtime nonce.
  matched,

  /// A healthy Agent answers with another identity, so waiting cannot help.
  foreignIdentity,

  /// Nothing answered with a complete health document before the deadline.
  unanswered,
}

/// The identity evidence behind one post-restart probe result.
class AgentRestartProbeResult {
  const AgentRestartProbeResult._(
    this.outcome, {
    this.observedLauncherId,
    this.observedRuntimeNonce,
    this.observedWorkspaceHash,
    this.expectedWorkspaceHash,
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

  bool get matched => outcome == AgentRestartProbeOutcome.matched;

  bool get sawForeignIdentity =>
      outcome == AgentRestartProbeOutcome.foreignIdentity;

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

/// Waits for the restarted Agent to prove it carries the live launcher identity.
///
/// A workspace hash answers "does an Agent for this source answer here"; it does
/// not answer "is it *our* Agent". One incident reported `restarted and healthy`
/// while the daemon on the port belonged to a foreign supervisor, because the
/// health probe and the lease identity were never compared. A healthy answer
/// with another identity therefore ends the wait immediately: no amount of
/// waiting changes who owns the port.
Future<AgentRestartProbeResult> waitForRestartedAgentIdentity({
  required int port,
  required String workspaceHash,
  required String launcherId,
  required String runtimeNonce,
  required String sanadHome,
  Duration timeout = const Duration(seconds: 30),
  Duration pollInterval = const Duration(milliseconds: 250),
  DateTime Function()? clock,
  Future<void> Function(Duration)? delay,
}) async {
  final now = clock ?? DateTime.now;
  final pause = delay ?? Future<void>.delayed;
  final deadline = now().add(timeout);
  while (true) {
    final health = await readAgentHealthDocument(port, sanadHome);
    if (health != null && health['status'] == 'ok') {
      final observedLauncherId = health['dev_launcher_id']?.toString();
      final observedRuntimeNonce = health['dev_runtime_nonce']?.toString();
      final observedWorkspaceHash = health['workspace_hash']?.toString();
      final matched = matchesSanadDevAgentHealth(
        health,
        launcherId: launcherId,
        runtimeNonce: runtimeNonce,
      );
      return AgentRestartProbeResult._(
        matched
            ? AgentRestartProbeOutcome.matched
            : AgentRestartProbeOutcome.foreignIdentity,
        observedLauncherId: observedLauncherId,
        observedRuntimeNonce: observedRuntimeNonce,
        observedWorkspaceHash: observedWorkspaceHash,
        expectedWorkspaceHash: workspaceHash,
      );
    }
    if (!now().isBefore(deadline)) {
      return const AgentRestartProbeResult._(
        AgentRestartProbeOutcome.unanswered,
      );
    }
    await pause(pollInterval);
  }
}

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
