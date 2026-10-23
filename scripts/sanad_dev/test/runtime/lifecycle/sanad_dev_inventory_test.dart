import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

import '../../support/sanad_dev_inventory_fixture.dart';

void main() {
  group('sanad-dev inventory', () {
    late InventoryFixture fixture;

    setUp(() => fixture = InventoryFixture.create());
    tearDown(() => fixture.dispose());

    test(
      'reads worktree identity, dirty counts, tracking and derived Homes',
      () async {
        fixture.writeLease(
          home: fixture.linkedHome,
          port: 58092,
          sourceRoot: fixture.linkedPath,
          workspaceHash: fixture.linkedId.split('-').last,
          launcherPid: 4200,
          status: 'running',
          clientPids: const [7100],
          vmServicePorts: const [51092],
          sourceCommit: 'abcdef1234567890',
        );
        fixture.writeRecord(
          fixture.linkedId,
          workspaceHash: fixture.linkedId.split('-').last,
          agentPort: 58092,
          resolvedHome: fixture.linkedHome,
        );

        final inventory = await sanad_dev.collectSanadDevInventory(
          callerDirectory: fixture.linkedPath,
          environment: fixture.environment,
          git: FakeInventoryGit(
            entries: [
              FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
              FakeWorktreeEntry(fixture.linkedPath, 'feat/inventory', 'b' * 40),
              FakeWorktreeEntry(
                p.join(
                  fixture.root.path,
                  'repo',
                  '.agent',
                  'worktrees',
                  'gone-home',
                ),
                null,
                'c' * 40,
                locked: true,
                lockReason: 'held by another session',
              ),
            ],
            dirty: {fixture.primaryPath: 0, fixture.linkedPath: 3},
            tracking: {
              fixture.primaryPath: (behind: 2, ahead: 0),
            },
          ).call,
          processRunning: (pid) async => pid == 4200,
          probeAgents: (runtime, ports) async => const [],
          discoverClients: (runtime) async => const [],
        );

        expect(inventory.worktrees, hasLength(3));
        final primary = inventory.worktrees.first;
        expect(primary.path, fixture.primaryPath);
        expect(primary.displayBranch, 'main');
        expect(primary.primaryCheckout, isTrue);
        expect(primary.isLinked, isFalse);
        expect(primary.home, fixture.primaryHome.path);
        expect(primary.ahead, 0);
        expect(primary.behind, 2);
        expect(primary.shortHead, 'a' * 8);

        final linked = inventory.worktrees[1];
        expect(linked.worktreeId, fixture.linkedId);
        expect(linked.isLinked, isTrue);
        expect(linked.primaryCheckout, isFalse);
        expect(linked.dirtyCount, 3);
        expect(linked.home, fixture.linkedHome);
        expect(linked.recordedHome, fixture.linkedHome);

        final missing = inventory.worktrees[2];
        expect(missing.missing, isTrue);
        expect(missing.locked, isTrue);
        expect(missing.lockReason, 'held by another session');
        expect(missing.detached, isTrue);
        expect(missing.dirtyCount, 0);
        expect(missing.ahead, isNull);
        expect(missing.behind, isNull);
        expect(inventory.callerWorktreeId, fixture.linkedId);
      },
    );

    test('marks only the ~/.sanad runtime on port 58085 as primary', () async {
      fixture.writeLease(
        home: fixture.primaryHome.path,
        port: 58085,
        sourceRoot: fixture.primaryPath,
        workspaceHash: fixture.primaryId.split('-').last,
        launcherPid: 4200,
        status: 'running',
        clientPids: const [4400],
        vmServicePorts: const [51894],
        sourceCommit: 'd' * 40,
      );
      fixture.writeEndpoint(fixture.primaryHome.path, pid: 4300, port: 58085);
      fixture.writeLease(
        home: fixture.linkedHome,
        port: 58092,
        sourceRoot: fixture.linkedPath,
        workspaceHash: fixture.linkedId.split('-').last,
        launcherPid: 4210,
        status: 'running',
        clientPids: const [4410],
        vmServicePorts: const [51092],
        sourceCommit: 'e' * 40,
      );
      fixture.writeRecord(
        fixture.linkedId,
        workspaceHash: fixture.linkedId.split('-').last,
        agentPort: 58092,
        resolvedHome: fixture.linkedHome,
      );

      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.linkedPath, 'feat/inventory', 'b' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.linkedPath: 0},
          tracking: const {},
        ).call,
        processRunning: (pid) async =>
            pid == 4200 || pid == 4210 || pid == 4300,
        probeAgents: (runtime, ports) async => [
          sanad_dev.AgentInstance(
            58085,
            fixture.primaryId.split('-').last,
            'default',
            gatewayEnabled: true,
            launcherId: 'launcher-primary',
            runtimeNonce: 'nonce-primary',
            sanadHome: fixture.primaryHome.path,
          ),
          sanad_dev.AgentInstance(
            58092,
            fixture.linkedId.split('-').last,
            'worktree',
            launcherId: 'launcher-linked',
            runtimeNonce: 'nonce-linked',
            sanadHome: fixture.linkedHome,
          ),
        ],
        discoverClients: (runtime) async => [
          fixtureInventoryClient(
            port: 51894,
            pid: 4400,
            gatewayPort: 58085,
            launcherId: 'launcher-primary',
            nonce: 'nonce-primary',
            home: fixture.primaryHome.path,
          ),
          fixtureInventoryClient(
            port: 51092,
            pid: 4410,
            gatewayPort: 58092,
            launcherId: 'launcher-linked',
            nonce: 'nonce-linked',
            home: fixture.linkedHome,
          ),
        ],
      );

      final primary = inventory.runtimes.firstWhere(
        (runtime) => runtime.worktreeId == fixture.primaryId,
      );
      expect(primary.primary, isTrue);
      expect(primary.runtimeClass, sanad_dev.InventoryRuntimeClass.managed);
      expect(primary.agentPort, 58085);
      expect(
        primary.agentPid,
        4300,
        reason: 'the PID comes from the endpoint record',
      );
      expect(primary.agentAlive, isTrue);
      expect(primary.vmServicePort, 51894);
      expect(primary.shortCommit, 'd' * 8);
      expect(primary.leaseOwner, 'launcher-primary');
      expect(primary.leaseAlive, isTrue);
      expect(primary.clients, hasLength(1));
      expect(primary.devices, ['macos']);

      final linked = inventory.runtimes.firstWhere(
        (runtime) => runtime.worktreeId == fixture.linkedId,
      );
      expect(linked.primary, isFalse);
      expect(linked.runtimeClass, sanad_dev.InventoryRuntimeClass.managed);
      expect(linked.agentAlive, isTrue);
      expect(inventory.liveRuntimes, hasLength(2));
    });

    test('reports orphaned Homes, runtime records and endpoint records',
        () async {
      final staleHome = p.join(
        fixture.primaryHome.path,
        'dev',
        'homes',
        'stale-feature-11111111',
      );
      Directory(p.join(staleHome, 'dev')).createSync(recursive: true);
      fixture.writeLease(
        home: staleHome,
        port: 58099,
        sourceRoot: p.join(fixture.root.path, 'gone-source'),
        workspaceHash: '11111111',
        launcherPid: 4999,
        status: 'running',
        clientPids: const [],
        vmServicePorts: const [],
      );
      fixture.writeRecord(
        'gone-feature-22222222',
        workspaceHash: '22222222',
        agentPort: 58098,
        resolvedHome: p.join(
          fixture.primaryHome.path,
          'dev',
          'homes',
          'gone-feature-22222222',
        ),
      );
      // The live worktree keeps a record whose lease launcher is dead.
      fixture.writeLease(
        home: fixture.linkedHome,
        port: 58092,
        sourceRoot: fixture.linkedPath,
        workspaceHash: fixture.linkedId.split('-').last,
        launcherPid: 4998,
        status: 'running',
        clientPids: const [],
        vmServicePorts: const [],
      );
      fixture.writeRecord(
        fixture.linkedId,
        workspaceHash: fixture.linkedId.split('-').last,
        agentPort: 58092,
        resolvedHome: fixture.linkedHome,
      );
      fixture.writeEndpoint(fixture.primaryHome.path, pid: 4300, port: 58085);
      final staleEndpointHome = Directory(
        p.join(fixture.userHome.path, '.sanad-test'),
      )..createSync(recursive: true);
      fixture.writeEndpoint(staleEndpointHome.path, pid: 4400, port: 58107);
      Directory(p.join(staleEndpointHome.path, 'dev')).createSync();

      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.linkedPath, 'feat/inventory', 'b' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.linkedPath: 0},
          tracking: const {},
        ).call,
        // 4300 (the primary endpoint owner) is alive; every other PID is dead.
        processRunning: (pid) async => pid == 4300,
        probeAgents: (runtime, ports) async => const [],
        discoverClients: (runtime) async => const [],
      );

      final targets = inventory.orphans.map((orphan) => orphan.target).toList();
      expect(targets.toSet(), hasLength(targets.length));

      final staleHomeOrphan = inventory.orphans.singleWhere(
        (orphan) =>
            orphan.kind == sanad_dev.InventoryOrphanKind.devHome &&
            orphan.target == staleHome,
      );
      expect(staleHomeOrphan.reason, 'no matching worktree');
      expect(
        staleHomeOrphan.cleanupCommand,
        Platform.isWindows ? contains('Remove-Item') : "rm -rf '$staleHome'",
      );

      final goneRecord = inventory.orphans.singleWhere(
        (orphan) =>
            orphan.kind == sanad_dev.InventoryOrphanKind.runtimeRecord &&
            orphan.target.endsWith('gone-feature-22222222'),
      );
      expect(goneRecord.reason, 'no matching worktree');
      expect(goneRecord.cleanupCommand, contains('gone-feature-22222222'));

      final deadLauncher = inventory.orphans.singleWhere(
        (orphan) =>
            orphan.kind == sanad_dev.InventoryOrphanKind.runtimeRecord &&
            orphan.target.endsWith(fixture.linkedId),
      );
      expect(deadLauncher.reason, 'dead launcher pid 4998');
      expect(deadLauncher.detail, contains('sanad-dev doctor --fix'));

      final staleEndpoint = inventory.orphans.singleWhere(
        (orphan) =>
            orphan.kind == sanad_dev.InventoryOrphanKind.endpointRecord,
      );
      expect(
        staleEndpoint.target,
        p.join(
          fixture.userHome.path,
          '.sanad-test',
          '.local_gateway_endpoint.json',
        ),
      );
      expect(staleEndpoint.reason, 'dead endpoint pid 4400');
      expect(
        staleEndpoint.cleanupCommand,
        Platform.isWindows ? contains('Remove-Item') : startsWith('rm -f '),
      );

      // The live worktree's Home and the live primary endpoint are clean.
      expect(
        inventory.orphans.any(
          (orphan) =>
              orphan.target ==
              p.join(fixture.primaryHome.path, '.local_gateway_endpoint.json'),
        ),
        isFalse,
      );
      expect(
        inventory.orphans.any(
          (orphan) =>
              orphan.kind == sanad_dev.InventoryOrphanKind.devHome &&
              orphan.target == fixture.linkedHome,
        ),
        isFalse,
      );
    });

    test('reports Test Home slots for worktrees using ~/.sanad-test* Homes',
        () async {
      final testHome = Directory(p.join(fixture.userHome.path, '.sanad-test'))
        ..createSync();
      fixture.writeRecord(
        fixture.testHomeWorktreeId,
        workspaceHash: fixture.testHomeWorktreeId.split('-').last,
        agentPort: 58107,
        resolvedHome: testHome.path,
      );
      fixture.writeRecord(
        'gone-feature-22222222',
        workspaceHash: '22222222',
        agentPort: 58108,
        resolvedHome: testHome.path,
      );

      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.primaryPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.testHomePath, 'test/test-home', 'c' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.testHomePath: 0},
          tracking: const {},
        ).call,
        processRunning: (pid) async => false,
        probeAgents: (runtime, ports) async => const [],
        discoverClients: (runtime) async => const [],
      );

      // The existing worktree is a slot; the deleted worktree's record is only
      // an orphan, never a phantom slot.
      expect(inventory.testHomes, hasLength(1));
      final slot = inventory.testHomes.single;
      expect(slot.worktreeId, fixture.testHomeWorktreeId);
      expect(slot.home, testHome.path);
      expect(slot.agentPort, 58107);
      expect(slot.state, sanad_dev.InventorySlotState.stopped);
      expect(
        inventory.orphans.any(
          (orphan) => orphan.target.endsWith('gone-feature-22222222'),
        ),
        isTrue,
      );
    });
  });
}
