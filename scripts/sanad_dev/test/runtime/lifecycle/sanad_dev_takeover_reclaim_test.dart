import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/agent_restart_probe.dart'
    as restart_probe;
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import '../../support/sanad_dev_caller_env.dart';

const _launcherPid = 45061;
const _clientPid = 45122;
const _daemonPid = 42383;
const _supervisorPid = 2288;
const _launcherId = 'launcher-lease';
const _runtimeNonce = 'nonce-lease';
const _foreignLauncherId = 'launcher-orphan';
const _foreignNonce = 'nonce-orphan';
const _vmServicePort = 51894;
const _daemonIdentity =
    'Mon Nov 9 05:36:08 2026 dartvm bin/sanad_agent.dart daemon '
    '--child-process';
const _supervisorIdentity =
    'Mon Nov 7 03:11:02 2026 dart run bin/sanad_agent.dart daemon';

/// Takeover reclaim coverage.
///
/// Every process, port, and Home is a fake: discovery, process liveness,
/// identities, the daemon's own restart boundary, and the managed relaunch are
/// injected, so the suite never probes a real port or signals a real process.
void main() {
  late Directory home;
  late runtime_context.SanadDevRuntime runtime;

  setUp(() async {
    exitCode = 0;
    home = await Directory.systemTemp.createTemp('sanad-takeover-reclaim-');
    runtime = await resolveHandlerRuntime(sanadHomeOverride: home.path);
  });

  tearDown(() async {
    exitCode = 0;
    await home.delete(recursive: true);
  });

  final workspaceHash = () => runtime.worktreeId.split('-').last;

  runtime_ownership.RuntimeLauncherRecord lease({
    int launcherPid = _launcherPid,
    String launcherId = _launcherId,
    String runtimeNonce = _runtimeNonce,
    String? status,
    List<int> clientPids = const [_clientPid],
    List<int> vmPorts = const [_vmServicePort],
    String? workspaceHashOverride,
    String? homePath,
  }) => runtime_ownership.RuntimeLauncherRecord(
    launcherId: launcherId,
    runtimeNonce: runtimeNonce,
    launcherPid: launcherPid,
    launcherProcessIdentity: 'launcher-identity-$launcherPid',
    workspaceHash: workspaceHashOverride ?? workspaceHash(),
    sourceRoot: runtime.repositoryRoot,
    agentPort: runtime.agentPort,
    sanadHome: homePath ?? home.path,
    preferencesPrefix: runtime_context.deriveSanadDevPreferencesPrefix(
      home.path,
    ),
    clientPids: clientPids,
    vmServicePorts: vmPorts,
    status: status ?? 'running',
    updatedAt: DateTime.now().toUtc(),
  );

  sanad_dev.AgentInstance foreignDaemon({
    String? launcherId = _foreignLauncherId,
    String? runtimeNonce = _foreignNonce,
    String? sanadHome,
    int? port,
  }) => sanad_dev.AgentInstance(
    port ?? runtime.agentPort,
    workspaceHash(),
    'worktree',
    gatewayEnabled: true,
    launcherId: launcherId,
    runtimeNonce: runtimeNonce,
    sanadHome: sanadHome ?? home.path,
  );

  sanad_dev.ClientInstance ownedClient() {
    final arguments = [
      'flutter',
      'run',
      '-d',
      'macos',
      '--dart-define-from-file=config/prod.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:${runtime.agentPort}',
      '--dart-define=ENABLE_CLOUD_GATEWAY=true',
      '--dart-define=SANAD_HOME=${home.path}',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX='
          '${runtime_context.deriveSanadDevPreferencesPrefix(home.path)}',
      '--dart-define=SANAD_DEV_LAUNCHER_ID=$_launcherId',
      '--dart-define=SANAD_DEV_RUNTIME_NONCE=$_runtimeNonce',
      '--dart-define=SANAD_DEV_WORKSPACE_HASH=${workspaceHash()}',
      '--dart-define=SANAD_DEV_WORKTREE_NAME=${runtime.worktreeDisplayName}',
      '--dart-define=SANAD_DEV_WORKTREE_BRANCH=${runtime.branch}',
    ];
    return sanad_dev.ClientInstance(
      _vmServicePort,
      'token',
      '${runtime.repositoryRoot}${Platform.pathSeparator}client',
      'macos',
      pid: _clientPid,
      launchProfile: launch_profile.extractClientLaunchProfile(arguments),
    );
  }

  /// The 2026-11-09 shape: our live lease and client, a daemon that carries a
  /// two-day-old identity, and a supervisor reparented to pid 1.
  Future<void> writeIncidentShapes() async {
    await runtime_ownership.writeRuntimeLauncherRecord(lease());
    await File('${home.path}/.local_gateway_endpoint.json').writeAsString(
      jsonEncode({
        'schema': 1,
        'host': '127.0.0.1',
        'port': runtime.agentPort,
        'pid': _daemonPid,
      }),
    );
  }

  sanad_dev.RuntimeProcessState incidentState() =>
      sanad_dev.RuntimeProcessState(
        agent: foreignDaemon(),
        ownedClients: [ownedClient()],
        crossOwnedClients: const [],
        ambiguousClients: const [],
      );

  sanad_dev.RuntimeOwnershipAssessment incidentOwnership(
    sanad_dev.RuntimeProcessState state,
  ) => sanad_dev.RuntimeOwnershipAssessment(
    classification: runtime_ownership.RuntimeOwnershipClass.orphaned,
    state: state,
    record: lease(),
    reason: sanad_dev.orphanReclaimIdentityReason,
  );

  Map<int, int> parentMap() => {
    _supervisorPid: 1,
    _daemonPid: _supervisorPid,
    _clientPid: _launcherPid,
    _launcherPid: 1,
  };

  group('orphan reclaim evidence', () {
    Future<sanad_dev.OrphanReclaimAssessment> assess({
      sanad_dev.RuntimeProcessState? state,
      sanad_dev.RuntimeOwnershipAssessment? ownership,
      Set<int>? livePids,
      String? launcherIdentity,
      int? daemonPid,
      restart_probe.AgentOwnershipSnapshot? holder,
      List<runtime_ownership.RuntimeLauncherRecord> otherLeases = const [],
    }) {
      final effectiveState = state ?? incidentState();
      return sanad_dev.assessOrphanReclaim(
        runtime: runtime,
        state: effectiveState,
        ownership: ownership ?? incidentOwnership(effectiveState),
        activeHome: home.path,
        processRunning: (pid) async =>
            (livePids ?? {_launcherPid, _clientPid, _daemonPid}).contains(pid),
        processIdentity: (pid) async => pid == _launcherPid
            ? (launcherIdentity ?? 'launcher-identity-$_launcherPid')
            : pid == _daemonPid
            ? _daemonIdentity
            : _supervisorIdentity,
        readHolder: (_) async => holder,
        readDaemonPid: (_, _) async => daemonPid ?? _daemonPid,
        readParentMap: () async => parentMap(),
        scanHomes: (_, _) async => [
          sanad_dev.InventoryHomeState(
            home: home.path,
            leases: [lease(), ...otherLeases],
            endpoint: null,
          ),
        ],
      );
    }

    test('proves the incident state is reclaimable', () async {
      final assessment = await assess();
      expect(assessment.blocker, isNull);
      final evidence = assessment.evidence!;
      expect(evidence.port, runtime.agentPort);
      expect(evidence.daemonPid, _daemonPid);
      expect(evidence.foreignLauncherId, _foreignLauncherId);
      expect(evidence.client.pid, _clientPid);
    });

    test('refuses a lease whose launcher is gone', () async {
      await writeIncidentShapes();
      final assessment = await assess(livePids: {_clientPid, _daemonPid});
      expect(assessment.blocker, contains('is not running'));
    });

    test('refuses a reused launcher pid', () async {
      final assessment = await assess(launcherIdentity: 'other-process');
      expect(assessment.blocker, contains('no longer matches the lease'));
    });

    test('refuses a daemon that is this lease', () async {
      final state = sanad_dev.RuntimeProcessState(
        agent: foreignDaemon(
          launcherId: _launcherId,
          runtimeNonce: _runtimeNonce,
        ),
        ownedClients: [ownedClient()],
        crossOwnedClients: const [],
        ambiguousClients: const [],
      );
      final assessment = await assess(
        state: state,
        ownership: sanad_dev.RuntimeOwnershipAssessment(
          classification: runtime_ownership.RuntimeOwnershipClass.managed,
          state: state,
          record: lease(),
        ),
      );
      expect(assessment.blocker, contains('not an orphaned lease'));
    });

    test('refuses a lease with another inconsistency', () async {
      final state = incidentState();
      final assessment = await assess(
        state: state,
        ownership: sanad_dev.RuntimeOwnershipAssessment(
          classification: runtime_ownership.RuntimeOwnershipClass.orphaned,
          state: state,
          record: lease(),
          reason: 'client PIDs do not match lease',
        ),
      );
      expect(assessment.blocker, contains('lease is inconsistent'));
    });

    test('refuses a daemon that answers through another Home', () async {
      final state = sanad_dev.RuntimeProcessState(
        agent: foreignDaemon(sanadHome: '${home.path}-other'),
        ownedClients: [ownedClient()],
        crossOwnedClients: const [],
        ambiguousClients: const [],
      );
      final assessment = await assess(
        state: state,
        ownership: incidentOwnership(state),
      );
      expect(assessment.blocker, contains('another Sanad Home'));
    });

    test('refuses a cross-owned client', () async {
      final client = ownedClient();
      final state = sanad_dev.RuntimeProcessState(
        agent: foreignDaemon(),
        ownedClients: const [],
        crossOwnedClients: [client],
        ambiguousClients: const [],
      );
      final assessment = await assess(
        state: state,
        ownership: incidentOwnership(state),
      );
      expect(assessment.blocker, contains('cross-owned'));
    });

    test(
      'refuses when another live lease names the foreign identity',
      () async {
        final assessment = await assess(
          livePids: {_launcherPid, _clientPid, _daemonPid, 777001},
          otherLeases: [
            lease(
              launcherPid: 777001,
              launcherId: _foreignLauncherId,
              runtimeNonce: _foreignNonce,
              clientPids: const [],
              vmPorts: const [],
            ),
          ],
        );
        expect(assessment.blocker, contains('belongs to live launcher'));
      },
    );

    test('refuses when another Home leases this port', () async {
      final assessment = await assess(
        livePids: {_launcherPid, _clientPid, _daemonPid, 777002},
        otherLeases: [
          lease(
            launcherPid: 777002,
            launcherId: 'launcher-other-home',
            runtimeNonce: 'nonce-other-home',
            homePath: '${home.path}-other',
            clientPids: const [],
            vmPorts: const [],
          ),
        ],
      );
      expect(assessment.blocker, contains('leases port'));
    });

    test('refuses when the Home holder is a different live process', () async {
      final assessment = await assess(
        livePids: {_launcherPid, _clientPid, _daemonPid, _supervisorPid},
        holder: restart_probe.AgentOwnershipSnapshot(
          pid: _supervisorPid,
          launcherId: _foreignLauncherId,
          runtimeNonce: _foreignNonce,
        ),
      );
      expect(assessment.blocker, contains('held by pid $_supervisorPid'));
    });

    test('refuses when the listener is a child of our launcher', () async {
      final assessment = await assess(
        state: incidentState(),
        livePids: {_launcherPid, _clientPid, _daemonPid},
        daemonPid: _clientPid,
      );
      expect(assessment.blocker, contains('is a child of launcher'));
    });
  });

  group('orphan reclaim ladder', () {
    late bool daemonAlive;
    late bool safeRestartAccepted;
    late bool forcedRestartAccepted;
    late bool identityChanges;
    late bool daemonDisappears;
    late List<String> events;
    late List<int> chain;

    setUp(() {
      daemonAlive = true;
      safeRestartAccepted = true;
      forcedRestartAccepted = true;
      identityChanges = false;
      daemonDisappears = true;
      events = [];
      chain = [];
    });

    Future<sanad_dev.OrphanReclaimOutcome> run({
      bool force = false,
    }) => sanad_dev.reclaimOrphanedDaemon(
      evidence: sanad_dev.OrphanReclaimEvidence(
        record: lease(),
        activeHome: home.path,
        agent: foreignDaemon(),
        client: ownedClient(),
        daemonPid: _daemonPid,
        holder: null,
      ),
      force: force,
      exitTimeout: Duration.zero,
      pollInterval: Duration.zero,
      readLiveDaemon: (port, sanadHome) async => daemonAlive
          ? foreignDaemon(
              launcherId: identityChanges
                  ? 'launcher-elsewhere'
                  : _foreignLauncherId,
            )
          : null,
      requestPermanentRestart: (port, sanadHome, {bool force = false}) async {
        events.add('restart:${force ? 'forced' : 'safe'}');
        final accepted = force ? forcedRestartAccepted : safeRestartAccepted;
        if (!accepted) return false;
        if (daemonDisappears) daemonAlive = false;
        return true;
      },
      proveChain: (pid) async {
        events.add('prove:$pid');
        return chain;
      },
      terminateTree: (pid) async {
        events.add('terminate:$pid');
        if (pid == _supervisorPid) daemonAlive = false;
      },
      processRunning: (pid) async => pid == _daemonPid ? daemonAlive : true,
      processIdentity: (pid) async =>
          pid == _daemonPid ? _daemonIdentity : _supervisorIdentity,
      log: (message) {},
    );

    test('drains through the daemon own safe restart by default', () async {
      final outcome = await run();
      expect(outcome.blocker, isNull);
      expect(outcome.tier, sanad_dev.OrphanReclaimTier.safeRestart);
      expect(outcome.killed, isFalse);
      expect(events, ['restart:safe']);
    });

    test('refuses without force when the safe restart is rejected', () async {
      safeRestartAccepted = false;
      final outcome = await run();
      expect(outcome.blocker, contains('--force'));
      expect(events, ['restart:safe']);
      expect(outcome.killed, isFalse);
    });

    test('refuses without force when the daemon keeps serving', () async {
      daemonDisappears = false;
      final outcome = await run();
      expect(outcome.blocker, contains('still serves'));
      expect(events, ['restart:safe']);
    });

    test('escalates to the forced permanent shutdown with force', () async {
      safeRestartAccepted = false;
      final outcome = await run(force: true);
      expect(outcome.tier, sanad_dev.OrphanReclaimTier.forcedShutdown);
      expect(events, ['restart:safe', 'restart:forced']);
    });

    test('terminates only the proven chain as the last resort', () async {
      safeRestartAccepted = false;
      forcedRestartAccepted = false;
      chain = [_supervisorPid, _daemonPid];
      final outcome = await run(force: true);
      expect(outcome.tier, sanad_dev.OrphanReclaimTier.provenChain);
      expect(outcome.killed, isTrue);
      expect(events, [
        'restart:safe',
        'restart:forced',
        'prove:$_daemonPid',
        'terminate:$_supervisorPid',
      ]);
    });

    test('signals nothing when the chain is unprovable', () async {
      safeRestartAccepted = false;
      forcedRestartAccepted = false;
      final outcome = await run(force: true);
      expect(outcome.blocker, contains('not provable'));
      expect(events, ['restart:safe', 'restart:forced', 'prove:$_daemonPid']);
    });

    test(
      'refuses when the daemon identity changed before the ladder',
      () async {
        identityChanges = true;
        final outcome = await run(force: true);
        expect(outcome.blocker, contains('changed identity'));
        expect(events, isEmpty);
      },
    );
  });

  group('agent tool origin guard', () {
    test('detects either requester variable and ignores empty values', () {
      expect(
        sanad_dev.hasAgentToolRequester({'SANAD_REQUESTER_SESSION_ID': 's'}),
        isTrue,
      );
      expect(
        sanad_dev.hasAgentToolRequester({'SANAD_REQUESTER_TOOL_CALL_ID': 't'}),
        isTrue,
      );
      expect(
        sanad_dev.hasAgentToolRequester({
          'SANAD_REQUESTER_SESSION_ID': '',
          'SANAD_REQUESTER_TOOL_CALL_ID': '',
        }),
        isFalse,
      );
      expect(sanad_dev.hasAgentToolRequester(const {}), isFalse);
    });
  });

  group('takeover reclaim handler', () {
    test(
      'reclaims the incident state and relaunches under a new lease',
      () async {
        await writeIncidentShapes();
        final live = {_launcherPid, _clientPid, _daemonPid};
        final drains = <String>[];
        final terminated = <int>[];
        var daemonAnswers = true;
        sanad_dev.TakeoverLaunchPlan? launched;

        await sanad_dev.handleRuntimeTakeover(
          sanadHomePath: home.path,
          isAgentToolCall: () => false,
          discoverAgents: ({sanadHomeOverride}) async => [foreignDaemon()],
          discoverClients: () async => [ownedClient()],
          processRunning: (pid) async => pid != null && live.contains(pid),
          processIdentity: (pid) async => pid == _launcherPid
              ? 'launcher-identity-$_launcherPid'
              : _daemonIdentity,
          readLiveDaemon: (port, sanadHome) async =>
              daemonAnswers ? foreignDaemon() : null,
          requestPermanentRestart:
              (port, sanadHome, {bool force = false}) async {
                drains.add('${force ? 'forced' : 'safe'}:$port');
                if (!force) {
                  daemonAnswers = false;
                  live.remove(_daemonPid);
                }
                return true;
              },
          readParentMap: () async => parentMap(),
          proveAgentChain: (pid) async => const [],
          terminateTree: (pid) async {
            terminated.add(pid);
            live.remove(pid);
            if (pid == _launcherPid) live.remove(_clientPid);
          },
          scanHomes: (_, _) async => [
            sanad_dev.InventoryHomeState(
              home: home.path,
              leases: [lease()],
              endpoint: null,
            ),
          ],
          runManagedLaunch: (plan) async {
            launched = plan;
            return true;
          },
        );

        expect(exitCode, 0);
        expect(drains, ['safe:${runtime.agentPort}']);
        expect(terminated, [_launcherPid]);
        expect(launched, isNotNull);
        expect(launched!.device, 'macos');
        expect(launched!.configPath, 'config/prod.json');
        expect(launched!.cloudEnabled, isTrue);
        expect(launched!.driverMode, isFalse);
        expect(launched!.homeSelector, home.path);
        expect(
          await File(
            runtime_ownership.runtimeLauncherRecordPath(
              home.path,
              runtime.agentPort,
            ),
          ).exists(),
          isFalse,
        );
      },
    );

    test('a blocked reclaim changes nothing and starts no launcher', () async {
      await writeIncidentShapes();
      final drains = <String>[];
      final terminated = <int>[];
      var launchCalls = 0;

      await sanad_dev.handleRuntimeTakeover(
        sanadHomePath: home.path,
        isAgentToolCall: () => false,
        discoverAgents: ({sanadHomeOverride}) async => [foreignDaemon()],
        discoverClients: () async => [ownedClient()],
        processRunning: (pid) async =>
            {_launcherPid, _clientPid, _daemonPid, 777003}.contains(pid),
        processIdentity: (pid) async => pid == _launcherPid
            ? 'launcher-identity-$_launcherPid'
            : _daemonIdentity,
        readLiveDaemon: (port, sanadHome) async => foreignDaemon(),
        requestPermanentRestart: (port, sanadHome, {bool force = false}) async {
          drains.add('restart');
          return true;
        },
        readParentMap: () async => parentMap(),
        proveAgentChain: (pid) async => const [],
        terminateTree: (pid) async => terminated.add(pid),
        scanHomes: (_, _) async => [
          sanad_dev.InventoryHomeState(
            home: home.path,
            leases: [
              lease(),
              lease(
                launcherPid: 777003,
                launcherId: _foreignLauncherId,
                runtimeNonce: _foreignNonce,
                clientPids: const [],
                vmPorts: const [],
              ),
            ],
            endpoint: null,
          ),
        ],
        runManagedLaunch: (plan) async {
          launchCalls++;
          return true;
        },
      );

      expect(exitCode, 1);
      expect(drains, isEmpty);
      expect(terminated, isEmpty);
      expect(launchCalls, 0);
      expect(
        await File(
          runtime_ownership.runtimeLauncherRecordPath(
            home.path,
            runtime.agentPort,
          ),
        ).exists(),
        isTrue,
      );
    });

    test('restores the previous runtime when the relaunch fails', () async {
      await writeIncidentShapes();
      final live = {_launcherPid, _clientPid, _daemonPid};
      var daemonAnswers = true;
      var restoreCalls = 0;
      bool? restoredClient;

      await sanad_dev.handleRuntimeTakeover(
        sanadHomePath: home.path,
        isAgentToolCall: () => false,
        discoverAgents: ({sanadHomeOverride}) async => [foreignDaemon()],
        discoverClients: () async => [ownedClient()],
        processRunning: (pid) async => pid != null && live.contains(pid),
        processIdentity: (pid) async => pid == _launcherPid
            ? 'launcher-identity-$_launcherPid'
            : _daemonIdentity,
        readLiveDaemon: (port, sanadHome) async =>
            daemonAnswers ? foreignDaemon() : null,
        requestPermanentRestart: (port, sanadHome, {bool force = false}) async {
          daemonAnswers = false;
          live.remove(_daemonPid);
          return true;
        },
        readParentMap: () async => parentMap(),
        proveAgentChain: (pid) async => const [],
        terminateTree: (pid) async {
          live.remove(pid);
          if (pid == _launcherPid) live.remove(_clientPid);
        },
        scanHomes: (_, _) async => [
          sanad_dev.InventoryHomeState(
            home: home.path,
            leases: [lease()],
            endpoint: null,
          ),
        ],
        runManagedLaunch: (plan) async => false,
        restoreManualRuntime:
            ({
              required runtime,
              required agentPort,
              required sanadHome,
              required client,
              required profile,
              required cloudEnabled,
              required restoreClient,
            }) async {
              restoreCalls++;
              restoredClient = restoreClient;
              return true;
            },
      );

      expect(restoreCalls, 1);
      expect(restoredClient, isTrue);
    });

    test(
      'refuses an incomplete manual pair with the existing message',
      () async {
        await sanad_dev.handleRuntimeTakeover(
          sanadHomePath: home.path,
          isAgentToolCall: () => false,
          discoverAgents: ({sanadHomeOverride}) async => const [],
          discoverClients: () async => const [],
          processRunning: (pid) async => false,
          scanHomes: (_, _) async => const [],
        );
        expect(exitCode, 1);
      },
    );
  });
}
