import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

import '../../support/sanad_dev_inventory_fixture.dart';

/// Output, attribution, and bounded-probe coverage for `sanad-dev inventory`.
void main() {
  group('sanad-dev inventory output', () {
    late InventoryFixture fixture;

    setUp(() => fixture = InventoryFixture.create());
    tearDown(() => fixture.dispose());

    test('attributes a drifted Client PID to its registered worktree', () async {
      fixture.writeLease(
        home: fixture.primaryHome.path,
        port: 58085,
        sourceRoot: fixture.primaryPath,
        workspaceHash: fixture.primaryId.split('-').last,
        launcherPid: 4200,
        status: 'running',
        clientPids: const [4001],
        vmServicePorts: const [51001],
      );

      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
          ],
          dirty: {fixture.primaryPath: 0},
          tracking: const {},
        ).call,
        processRunning: (pid) async => pid == 4200,
        probeAgents: (runtime, ports) async => [
          sanad_dev.AgentInstance(
            58085,
            fixture.primaryId.split('-').last,
            'default',
            launcherId: 'launcher-primary',
            runtimeNonce: 'nonce-primary',
            sanadHome: fixture.primaryHome.path,
          ),
        ],
        discoverClients: (runtime) async => [
          // The lease recorded 4001, but the live Client is 4002 with the same
          // launcher identity: it must still resolve to its worktree.
          fixtureInventoryClient(
            port: 51001,
            pid: 4002,
            gatewayPort: 58085,
            launcherId: 'launcher-primary',
            nonce: 'nonce-primary',
            home: fixture.primaryHome.path,
          ),
          fixtureInventoryClient(
            port: 51002,
            pid: 4001,
            gatewayPort: 58085,
            launcherId: 'launcher-primary',
            nonce: 'nonce-primary',
            home: fixture.primaryHome.path,
            withoutProfile: true,
          ),
        ],
      );

      final drifted = inventory.clients.firstWhere(
        (client) => client.pid == 4002,
      );
      expect(drifted.worktreeId, fixture.primaryId);
      expect(drifted.managed, isTrue);
      expect(drifted.leasePidMismatch, isTrue);
      expect(drifted.deviceId, 'macos');
      expect(drifted.gatewayPort, 58085);

      final recorded = inventory.clients.firstWhere(
        (client) => client.pid == 4001,
      );
      expect(recorded.worktreeId, fixture.primaryId);
      expect(recorded.leasePidMismatch, isFalse);
      expect(inventory.runtimes.single.clients, hasLength(2));
      // The Client token is never part of the report.
      expect(
        jsonEncode(inventory.toJson()),
        isNot(contains('token-not-printed')),
      );
    });

    test('prints a stable json schema', () async {
      fixture.writeRecord(
        fixture.primaryId,
        workspaceHash: fixture.primaryId.split('-').last,
        agentPort: 58085,
        resolvedHome: fixture.primaryHome.path,
      );
      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
          ],
          dirty: {fixture.primaryPath: 2},
          tracking: {
            fixture.primaryPath: (behind: 1, ahead: 4),
          },
        ).call,
        processRunning: (pid) async => false,
        probeAgents: (runtime, ports) async => const [],
        discoverClients: (runtime) async => const [],
        clock: () => DateTime.utc(2026, 10, 23, 12),
      );
      final document = inventory.toJson();

      expect(document.keys, [
        'schema',
        'generated_at',
        'user_home',
        'primary_home',
        'repository_root',
        'caller_worktree_id',
        'agent_probe_timed_out',
        'client_probe_timed_out',
        'summary',
        'worktrees',
        'runtimes',
        'clients',
        'test_homes',
        'orphans',
      ]);
      expect(document['schema'], sanad_dev.sanadDevInventorySchemaVersion);
      expect(document['generated_at'], '2026-10-23T12:00:00.000Z');
      expect(document['summary'], {
        'worktrees': 1,
        'runtimes': 1,
        'live_runtimes': 0,
        'clients': 0,
        'test_homes': 0,
        'orphans': 0,
      });
      expect((document['worktrees']! as List).single.keys, [
        'path',
        'branch',
        'detached',
        'head',
        'short_head',
        'locked',
        'lock_reason',
        'prunable',
        'prunable_reason',
        'missing',
        'is_linked',
        'primary_checkout',
        'dirty_count',
        'ahead',
        'behind',
        'worktree_id',
        'home',
        'recorded_home',
      ]);
      expect((document['runtimes']! as List).single.keys, [
        'worktree_id',
        'worktree_path',
        'home',
        'primary',
        'class',
        'agent_port',
        'agent_pid',
        'agent_alive',
        'vm_service_port',
        'source_commit',
        'lease_owner',
        'lease_status',
        'lease_pid',
        'lease_alive',
        'detail',
        'clients',
      ]);
      // The document round-trips through JSON without loss.
      final decoded = jsonDecode(jsonEncode(document)) as Map<String, Object?>;
      expect(decoded['schema'], document['schema']);
    });

    test('abandons a hung probe at the deadline instead of blocking', () async {
      final stopwatch = Stopwatch()..start();
      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
          ],
          dirty: {fixture.primaryPath: 0},
          tracking: const {},
        ).call,
        processRunning: (pid) async => false,
        probeAgents: (runtime, ports) =>
            Completer<List<sanad_dev.AgentInstance>>().future,
        discoverClients: (runtime) async => const [],
        probeTimeout: const Duration(milliseconds: 50),
      );
      stopwatch.stop();

      expect(inventory.agentProbeTimedOut, isTrue);
      expect(inventory.clientProbeTimedOut, isFalse);
      expect(
        inventory.runtimes.single.runtimeClass,
        sanad_dev.InventoryRuntimeClass.stopped,
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('renders a compact table and hides empty sections', () async {
      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
          ],
          dirty: {fixture.primaryPath: 1},
          tracking: {
            fixture.primaryPath: (behind: 0, ahead: 0),
          },
        ).call,
        processRunning: (pid) async => false,
        probeAgents: (runtime, ports) async => const [],
        discoverClients: (runtime) async => const [],
      );
      final compact = _capture(inventory, showAll: false);
      expect(compact, contains('Inventory (read-only)'));
      expect(compact, contains('Worktrees (1)'));
      expect(compact, isNot(contains('Clients (')));
      expect(compact, isNot(contains('Orphans (')));
      expect(compact, isNot(contains('Test Homes (')));
      // One line per worktree item (the caller header line is not an item row).
      expect(
        compact
            .split('\n')
            .where((line) => line.startsWith('  ${fixture.primaryId}'))
            .length,
        1,
      );

      final detailed = _capture(inventory, showAll: true);
      expect(detailed, contains('head: ${'a' * 40}'));
      expect(detailed, contains('Runtimes (0 live, 1 total)'));
      expect(
        detailed,
        contains('detail: no live Agent or Client'),
      );
    });
  });
}

String _capture(sanad_dev.SanadDevInventory inventory, {required bool showAll}) {
  final lines = <String>[];
  runZoned(
    () => sanad_dev.printSanadDevInventory(inventory, showAll: showAll),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines.join('\n');
}
