part of '../../sanad_dev_cli.dart';

class _ManagedUiDriverClient {
  const _ManagedUiDriverClient(this.client, this.error);

  final ClientInstance? client;
  final String? error;
}

/// Resolves the single launcher-owned driver Client for this worktree.
///
/// A missing Client is retried once because discovery can race a Client that is
/// still finishing startup; the same condition reported by a live Client was
/// the most common transient `ui` failure.
///
/// The first attempt revalidates the target this worktree resolved last time.
/// That costs one credential read, one health probe, one argument read per
/// recorded pid, and the launcher lease, instead of a full process-table scan
/// plus a 101-port sweep. Everything the cheap path observes is live evidence;
/// the cached entry only says where to look. Any mismatch, including a lease
/// whose client set no longer matches, drops the entry and falls back to the
/// full scan, so a stale or foreign entry can never select a Client.
Future<_ManagedUiDriverClient> _resolveManagedUiDriverClient(
  SanadDevRuntime runtime,
  String? sanadHomePath,
) async {
  final reusable = await _revalidatedCachedUiDriverClient(runtime);
  if (reusable != null) return _ManagedUiDriverClient(reusable, null);
  for (var attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    final activeClients = await discoverClientInstances(runtime: runtime);
    final processState = selectRuntimeProcessState(
      activeAgents: await discoverAgentInstances(
        sanadHomeOverride: sanadHomePath,
        runtime: runtime,
      ),
      activeClients: activeClients,
      runtime: runtime,
    );
    final activeHome = resolveActiveSanadHome(runtime, processState);
    final ownership = await assessRuntimeOwnership(
      runtime: runtime,
      state: processState,
      sanadHome: activeHome,
    );
    final managedClients = selectManagedUiDriverClients(ownership);
    if (managedClients.length == 1) {
      final client = managedClients.single;
      final agentPort =
          ownership.record?.agentPort ?? ownership.state.agent?.port;
      if (agentPort != null) {
        final cache = uiDriverTargetCacheFor(
          runtime: runtime,
          client: client,
          sanadHome: activeHome,
          agentPort: agentPort,
        );
        if (cache != null) await writeUiDriverTargetCache(runtime, cache);
      }
      return _ManagedUiDriverClient(client, null);
    }
    if (managedClients.length > 1) {
      return const _ManagedUiDriverClient(
        null,
        'Multiple managed clients are active for this worktree. '
        'Pass --vm-url explicitly to select one.',
      );
    }
  }
  return const _ManagedUiDriverClient(
    null,
    'No active driver-enabled client is managed for this worktree. '
    'Run `sanad-dev run --driver` first or pass --vm-url explicitly.',
  );
}

/// Revalidates the remembered target with live evidence.
///
/// Returns null when no entry can be reused, and drops an entry that the live
/// state no longer supports so the full scan starts from a clean slate.
Future<ClientInstance?> _revalidatedCachedUiDriverClient(
  SanadDevRuntime runtime,
) async {
  final cached = await readUiDriverTargetCache(runtime);
  if (cached == null) return null;
  final usable =
      validateUiDriverTargetCache(
        cached,
        runtime: runtime,
        resolvedSanadHome: runtime.sanadHome,
      ) ==
      null;
  if (usable && await uiDriverVmServiceReachable(cached.vmServicePort)) {
    final clients = await discoverClientInstances(
      runtime: runtime,
      candidatePids: cached.candidatePids,
    );
    if (clients.length == 1 &&
        clients.single.pid == cached.clientPid &&
        clients.single.devServicePid == cached.devServicePid &&
        clients.single.port == cached.vmServicePort) {
      final processState = selectRuntimeProcessState(
        activeAgents: await discoverAgentInstances(
          sanadHomeOverride: runtime.sanadHome,
          runtime: runtime,
          candidatePorts: [cached.agentPort],
        ),
        activeClients: clients,
        runtime: runtime,
      );
      final ownership = await assessRuntimeOwnership(
        runtime: runtime,
        state: processState,
        sanadHome: resolveActiveSanadHome(runtime, processState),
      );
      final managedClients = selectManagedUiDriverClients(ownership);
      if (managedClients.length == 1 &&
          managedClients.single.pid == cached.clientPid &&
          managedClients.single.port == cached.vmServicePort &&
          managedClients.single.devServicePid == cached.devServicePid) {
        return managedClients.single;
      }
    }
  }
  await deleteUiDriverTargetCache(runtime);
  return null;
}

List<ClientInstance> selectManagedUiDriverClients(
  RuntimeOwnershipAssessment ownership,
) {
  if (!ownership.isManaged) return const [];
  return ownership.state.ownedClients
      .where(
        (client) =>
            client.launchProfile?.target
                ?.replaceAll('\\\\', '/')
                .endsWith('lib/driver_main.dart') ==
            true,
      )
      .toList(growable: false);
}
