part of '../../../sanad_dev_cli.dart';

/// Exact ownership reason that marks a *reclaimable* orphan.
///
/// The ownership assessment reports this reason only when the launcher lease
/// itself is otherwise valid — live launcher, matching process identity, same
/// port and Home, exact lease-owned Client inventory — and the single mismatch
/// is the identity the daemon on the port presents. Reclaim depends on that
/// narrow reading, so the string is part of the command contract.
const orphanReclaimIdentityReason =
    'Agent launcher identity or nonce does not match the lease';

/// Path of the per-Home reclaim lock.
///
/// The lock file lives beside the leases it guards, never inside the Home data,
/// and never names a credential. It exists so two concurrent reclaims cannot
/// interleave evidence reads and process signals.
String runtimeReclaimLockPath(String sanadHome, int agentPort) => [
  sanadHome.replaceAll(RegExp(r'[\\/]+$'), ''),
  'dev',
  'runtime-reclaim-$agentPort.lock',
].join(Platform.pathSeparator);

/// Whether this process was started by an Agent tool call.
///
/// Human-only runtime mutations (takeover, stale-lease recovery) must never be
/// driven from inside a session they could interrupt. The environment is a
/// parameter so the guard is testable.
bool hasAgentToolRequester([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  return env['SANAD_REQUESTER_SESSION_ID']?.isNotEmpty == true ||
      env['SANAD_REQUESTER_TOOL_CALL_ID']?.isNotEmpty == true;
}

/// One daemon this process proved is *not* the runtime's own Agent.
///
/// Every field is evidence, never authority: [record] is the live launcher
/// lease, [agent] is the identity that answered the port, [daemonPid] names the
/// process that published that endpoint when the record still exists, and
/// [holder] is the recorded Home owner when a managed daemon wrote one.
class OrphanReclaimEvidence {
  const OrphanReclaimEvidence({
    required this.record,
    required this.activeHome,
    required this.agent,
    required this.client,
    required this.daemonPid,
    required this.holder,
  });

  final RuntimeLauncherRecord record;
  final String activeHome;
  final AgentInstance agent;
  final ClientInstance client;
  final int? daemonPid;
  final AgentOwnershipSnapshot? holder;

  int get port => record.agentPort;
  String? get foreignLauncherId => agent.launcherId;
  String? get foreignRuntimeNonce => agent.runtimeNonce;

  /// Bounded, secret-free description of the daemon that must be drained.
  String describeDaemon() {
    final identity = agent.launcherId == null
        ? 'an unmanaged Agent (no launcher identity)'
        : 'launcher ${agent.launcherId}, nonce ${agent.runtimeNonce}';
    final pid = daemonPid == null ? 'pid not recorded' : 'pid $daemonPid';
    return '$identity ($pid)';
  }
}

/// The result of the read-only reclaim proofs: either complete evidence or one
/// bounded reason that names the missing proof.
class OrphanReclaimAssessment {
  const OrphanReclaimAssessment.ready(OrphanReclaimEvidence this.evidence)
    : blocker = null;

  const OrphanReclaimAssessment.blocked(String this.blocker) : evidence = null;

  final OrphanReclaimEvidence? evidence;
  final String? blocker;

  bool get ready => evidence != null;
}

/// Reclaimable Home states, including the caller's active Home.
///
/// Reading keys only; the leases themselves are the ownership evidence.
Future<List<InventoryHomeState>> readReclaimHomeStates(
  SanadDevRuntime runtime,
  String activeHome,
) async {
  final homes = <String>{activeHome, runtime.sanadHome};
  try {
    homes.addAll(await discoverLocalGatewayCandidateHomes(runtime));
  } on Object {
    // A Home that cannot be enumerated contributes nothing; the caller's own
    // Home is already covered above.
  }
  final states = <InventoryHomeState>[];
  for (final home in homes) {
    try {
      states.add(await readInventoryHomeState(home));
    } on Object {
      // An unreadable Home is not evidence of anything.
    }
  }
  return states;
}

/// The Agent that answers [port] for [sanadHome], or null.
Future<AgentInstance?> readLiveDaemonInstance(
  int port,
  String sanadHome,
) async {
  try {
    final agents = await discoverAgentInstances(
      sanadHomeOverride: sanadHome,
      candidatePorts: [port],
    );
    for (final agent in agents) {
      if (agent.port == port) return agent;
    }
  } on Object {
    return null;
  }
  return null;
}

bool _sameDaemonIdentity(
  String? firstLauncherId,
  String? firstNonce,
  String? secondLauncherId,
  String? secondNonce,
) => firstLauncherId == secondLauncherId && firstNonce == secondNonce;

/// Proves that the daemon on the runtime's own port is not this lease, and that
/// no other live runtime or Home claims it.
///
/// Every proof is narrow and independent; the assessment stops at the first
/// missing one and mutates nothing. It deliberately re-derives nothing the
/// ownership assessment already proved: [ownership] must carry the lease and
/// the exact identity reason.
Future<OrphanReclaimAssessment> assessOrphanReclaim({
  required SanadDevRuntime runtime,
  required RuntimeProcessState state,
  required RuntimeOwnershipAssessment ownership,
  required String activeHome,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<String?> Function(int pid) processIdentity = readProcessIdentity,
  Future<AgentOwnershipSnapshot?> Function(String sanadHome) readHolder =
      readAgentOwnershipSnapshot,
  Future<int?> Function(String sanadHome, int port) readDaemonPid =
      readRecordedDaemonPid,
  Future<Map<int, int>> Function() readParentMap = readProcessParentMap,
  Future<List<InventoryHomeState>> Function(
        SanadDevRuntime runtime,
        String activeHome,
      )
      scanHomes =
      readReclaimHomeStates,
}) async {
  final record = ownership.record;
  if (ownership.classification != RuntimeOwnershipClass.orphaned ||
      record == null) {
    return const OrphanReclaimAssessment.blocked(
      'this runtime is not an orphaned lease and daemon pair',
    );
  }
  if (ownership.reason != orphanReclaimIdentityReason) {
    return OrphanReclaimAssessment.blocked(
      'the launcher lease is inconsistent (${ownership.reason ?? 'unknown'}); '
      'run "sanad-dev doctor"',
    );
  }
  if (!await processRunning(record.launcherPid)) {
    return OrphanReclaimAssessment.blocked(
      'the recorded launcher pid ${record.launcherPid} is not running, so no '
      'launcher can relaunch this runtime; run "sanad-dev doctor"',
    );
  }
  final launcherIdentity = await processIdentity(record.launcherPid);
  if (launcherIdentity == null ||
      launcherIdentity != record.launcherProcessIdentity) {
    return OrphanReclaimAssessment.blocked(
      'launcher pid ${record.launcherPid} no longer matches the lease identity '
      '(the pid was reused); run "sanad-dev doctor"',
    );
  }
  if (!_samePath(record.sanadHome, activeHome) ||
      !_samePath(activeHome, runtime.sanadHome)) {
    return OrphanReclaimAssessment.blocked(
      'the live daemon does not belong to ${runtime.sanadHome}',
    );
  }
  final agent = state.agent;
  if (agent == null) {
    return const OrphanReclaimAssessment.blocked(
      'no live Agent answers on the expected port',
    );
  }
  if (agent.port != record.agentPort || record.agentPort != runtime.agentPort) {
    return OrphanReclaimAssessment.blocked(
      'Agent port ${agent.port} does not match the lease port '
      '${record.agentPort}',
    );
  }
  if (record.workspaceHash != runtime.worktreeId.split('-').last) {
    return const OrphanReclaimAssessment.blocked(
      'the lease belongs to another workspace',
    );
  }
  if (!const {'running', 'agent-only', 'client-only'}.contains(record.status)) {
    return OrphanReclaimAssessment.blocked(
      'launcher record status is ${record.status}',
    );
  }
  if (_sameDaemonIdentity(
    agent.launcherId,
    agent.runtimeNonce,
    record.launcherId,
    record.runtimeNonce,
  )) {
    return const OrphanReclaimAssessment.blocked(
      'the Agent on this port is this lease',
    );
  }
  if (agent.sanadHome == null ||
      !_samePath(agent.sanadHome!, record.sanadHome)) {
    return OrphanReclaimAssessment.blocked(
      'the Agent answered through another Sanad Home '
      '(${agent.sanadHome ?? 'unknown'})',
    );
  }
  if (!state.mutationAllowed) {
    return const OrphanReclaimAssessment.blocked(
      'a cross-owned or unverifiable Client is attached to this port; stop it '
      'from its owning runtime',
    );
  }
  if (state.ownedClients.length != 1) {
    return OrphanReclaimAssessment.blocked(
      'expected exactly one lease-owned Client, found '
      '${state.ownedClients.length}',
    );
  }
  final client = state.ownedClients.single;
  if (client.pid == null) {
    return const OrphanReclaimAssessment.blocked(
      'the lease-owned Client has no discoverable pid',
    );
  }

  final holder = await readHolder(record.sanadHome);
  final holderPid = holder?.pid;
  final holderLive = holderPid != null && await processRunning(holderPid);
  var daemonPid = await readDaemonPid(record.sanadHome, record.agentPort);
  if (daemonPid != null && !await processRunning(daemonPid)) daemonPid = null;
  if (holderLive) {
    if (daemonPid == null) {
      daemonPid = holderPid;
    } else if (daemonPid != holderPid) {
      return OrphanReclaimAssessment.blocked(
        'the Sanad Home is held by pid $holderPid '
        '(${holder!.describe()}), not by the daemon on port '
        '${record.agentPort}',
      );
    }
  }
  final parentMap = await readParentMap();
  if (daemonPid != null &&
      processDescendants(
        rootPid: record.launcherPid,
        parentByPid: parentMap,
      ).contains(daemonPid)) {
    return OrphanReclaimAssessment.blocked(
      'the daemon on port ${record.agentPort} is a child of launcher pid '
      '${record.launcherPid}, so the lease rather than the daemon is '
      'inconsistent; run "sanad-dev doctor"',
    );
  }

  List<InventoryHomeState> homes;
  try {
    homes = await scanHomes(runtime, activeHome);
  } on Object {
    homes = const [];
  }
  final otherLeases = [for (final homeState in homes) ...homeState.leases];
  for (final lease in otherLeases) {
    final sameLease =
        _samePath(lease.sanadHome, record.sanadHome) &&
        lease.launcherId == record.launcherId &&
        lease.runtimeNonce == record.runtimeNonce;
    if (sameLease) continue;
    if (!await processRunning(lease.launcherPid)) continue;
    if (lease.launcherId == agent.launcherId ||
        (agent.runtimeNonce != null &&
            lease.runtimeNonce == agent.runtimeNonce)) {
      return OrphanReclaimAssessment.blocked(
        'the daemon belongs to live launcher ${lease.launcherId} on port '
        '${lease.agentPort}; use that runtime\'s own commands',
      );
    }
    if (lease.agentPort == record.agentPort &&
        !_samePath(lease.sanadHome, record.sanadHome)) {
      return OrphanReclaimAssessment.blocked(
        'another Sanad Home (${lease.sanadHome}) leases port '
        '${lease.agentPort}',
      );
    }
  }

  return OrphanReclaimAssessment.ready(
    OrphanReclaimEvidence(
      record: record,
      activeHome: activeHome,
      agent: agent,
      client: client,
      daemonPid: daemonPid,
      holder: holder,
    ),
  );
}

/// Which boundary ended the daemon that did not belong to the lease.
enum OrphanReclaimTier {
  /// The daemon accepted its own permanent restart and exited.
  safeRestart,

  /// The daemon accepted a forced permanent shutdown (bounded cancellation).
  forcedShutdown,

  /// Only the proven process chain ended it.
  provenChain,
}

/// The outcome of the reclaim action ladder.
class OrphanReclaimOutcome {
  const OrphanReclaimOutcome.stopped(OrphanReclaimTier this.tier)
    : blocker = null;

  const OrphanReclaimOutcome.refused(String this.blocker) : tier = null;

  final OrphanReclaimTier? tier;
  final String? blocker;

  bool get stopped => blocker == null;
  bool get killed => tier == OrphanReclaimTier.provenChain;
}

/// Ends the daemon named by [evidence], in order of increasing destruction.
///
/// The ladder never starts with a signal: tier one is the daemon's own
/// authenticated permanent restart, tier two is its own forced permanent
/// shutdown, and only the last tier terminates a proven process chain. Every
/// tier re-proves that the same foreign identity still answers before it acts,
/// and the function returns a bounded refusal instead of guessing.
Future<OrphanReclaimOutcome> reclaimOrphanedDaemon({
  required OrphanReclaimEvidence evidence,
  required bool force,
  required Future<AgentInstance?> Function(int port, String sanadHome)
  readLiveDaemon,
  required Future<bool> Function(int port, String sanadHome, {bool force})
  requestPermanentRestart,
  required Future<List<int>> Function(int daemonPid) proveChain,
  required Future<void> Function(int pid) terminateTree,
  required Future<bool> Function(int? pid) processRunning,
  required Future<String?> Function(int pid) processIdentity,
  required void Function(String message) log,
  Duration exitTimeout = const Duration(seconds: 20),
  Duration pollInterval = const Duration(milliseconds: 250),
}) async {
  final port = evidence.port;
  final home = evidence.activeHome;
  final foreignLauncherId = evidence.foreignLauncherId;
  final foreignNonce = evidence.foreignRuntimeNonce;

  Future<bool> gone() async {
    final live = await readLiveDaemon(port, home);
    if (live != null) {
      return !_sameDaemonIdentity(
        live.launcherId,
        live.runtimeNonce,
        foreignLauncherId,
        foreignNonce,
      );
    }
    final pid = evidence.daemonPid;
    if (pid != null) return !await processRunning(pid);
    return true;
  }

  Future<bool> waitGone() async {
    final deadline = DateTime.now().add(exitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await gone()) return true;
      await Future<void>.delayed(pollInterval);
    }
    return gone();
  }

  final before = await readLiveDaemon(port, home);
  if (before == null) {
    return OrphanReclaimOutcome.refused(
      'the daemon on port $port no longer answers, so its identity cannot be '
      're-proved; nothing was signalled',
    );
  }
  if (!_sameDaemonIdentity(
    before.launcherId,
    before.runtimeNonce,
    foreignLauncherId,
    foreignNonce,
  )) {
    return OrphanReclaimOutcome.refused(
      'the daemon on port $port changed identity since the evidence was read; '
      'nothing was signalled',
    );
  }

  log(
    'Draining the daemon on port $port that does not belong to this lease...',
  );
  final accepted = await requestPermanentRestart(port, home, force: false);
  if (accepted && await waitGone()) {
    return const OrphanReclaimOutcome.stopped(OrphanReclaimTier.safeRestart);
  }
  if (!force) {
    return OrphanReclaimOutcome.refused(
      accepted
          ? 'the daemon accepted its own permanent restart but still serves '
                'port $port; rerun takeover in about 30 seconds'
          : 'the daemon rejected its own permanent restart; rerun '
                '"sanad-dev takeover --force" to escalate, or stop it from a '
                'human terminal',
    );
  }

  log(
    'The daemon did not exit through its own safe restart. Requesting a forced '
    'permanent shutdown: its own sessions will be cancelled and completed '
    'conversations are kept.',
  );
  final forced = await requestPermanentRestart(port, home, force: true);
  if (forced && await waitGone()) {
    return const OrphanReclaimOutcome.stopped(OrphanReclaimTier.forcedShutdown);
  }

  final daemonPid = evidence.daemonPid;
  if (daemonPid == null) {
    return const OrphanReclaimOutcome.refused(
      'the daemon refused its own shutdown and no process id is recorded for '
      'it; no process was signalled',
    );
  }
  final again = await readLiveDaemon(port, home);
  if (again == null ||
      !_sameDaemonIdentity(
        again.launcherId,
        again.runtimeNonce,
        foreignLauncherId,
        foreignNonce,
      )) {
    return OrphanReclaimOutcome.refused(
      'the daemon on port $port changed identity before the process chain could '
      'be proven; nothing was signalled',
    );
  }
  final chain = await proveChain(daemonPid);
  if (chain.isEmpty) {
    return OrphanReclaimOutcome.refused(
      'the daemon refused its own shutdown and its process chain is not '
      'provable; no process was signalled',
    );
  }
  for (final pid in chain) {
    if (!await processRunning(pid)) continue;
    final identity = await processIdentity(pid);
    if (!isAgentRuntimeCommand(identity)) {
      return OrphanReclaimOutcome.refused(
        'pid $pid changed identity after its process chain was proven; no '
        'process was signalled',
      );
    }
  }
  log(
    'Signalling the proven Agent process chain '
    '${chain.map((pid) => '$pid').join(' -> ')}...',
  );
  await terminateTree(chain.first);
  if (daemonPid != chain.first && !chain.contains(daemonPid)) {
    await terminateTree(daemonPid);
  }
  if (await waitGone()) {
    return const OrphanReclaimOutcome.stopped(OrphanReclaimTier.provenChain);
  }
  return OrphanReclaimOutcome.refused(
    'the daemon on port $port did not exit after its proven process chain was '
    'signalled; nothing else was stopped',
  );
}
