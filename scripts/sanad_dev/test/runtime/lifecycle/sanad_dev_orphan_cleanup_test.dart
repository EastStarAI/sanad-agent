import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

/// Dry-run, confirm, and refusal coverage for `sanad-dev cleanup-orphans`.
///
/// Every case uses a throwaway user home and a synthetic projection: no test
/// reads the developer's own Home, signals a process, or deletes a real runtime
/// record.
void main() {
  group('sanad-dev cleanup-orphans plan', () {
    late Directory root;
    late String userHome;
    late String primaryHome;
    late String devArea;

    setUp(() {
      root = Directory.systemTemp.createTempSync('sanad-cleanup-');
      userHome = p.join(root.path, 'user');
      primaryHome = p.join(userHome, '.sanad');
      devArea = p.join(primaryHome, 'dev');
      Directory(p.join(devArea, 'homes')).createSync(recursive: true);
      Directory(p.join(devArea, 'runtimes')).createSync(recursive: true);
      Directory(p.join(userHome, '.sanad-test')).createSync(recursive: true);
    });
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<sanad_dev.SanadDevOrphanCleanupPlan> planFor(
      List<sanad_dev.InventoryOrphan> orphans, {
      List<sanad_dev.InventoryRuntime> runtimes = const [],
      Future<bool> Function(int? pid) processRunning = _noLiveProcess,
    }) {
      return sanad_dev.buildSanadDevOrphanCleanupPlan(
        _inventory(
          userHome: userHome,
          primaryHome: primaryHome,
          orphans: orphans,
          runtimes: runtimes,
        ),
        now: DateTime.utc(2026, 11, 9, 12),
        processRunning: processRunning,
      );
    }

    sanad_dev.SanadDevOrphanCleanupEntry entry(
      sanad_dev.SanadDevOrphanCleanupPlan plan,
      String target,
    ) => plan.entries.singleWhere((entry) => entry.target == target);

    test('deletes a dev-area Home and runtime record it can prove orphaned',
        ()  async {
      final staleHome = Directory(p.join(devArea, 'homes', 'stale-11111111'))
        ..createSync();
      final staleRecord = Directory(p.join(devArea, 'runtimes', 'gone-22222222'))
        ..createSync();
      final plan = await planFor([
        _orphan(sanad_dev.InventoryOrphanKind.devHome, staleHome.path),
        _orphan(sanad_dev.InventoryOrphanKind.runtimeRecord, staleRecord.path),
      ]);

      expect(plan.entries, hasLength(2));
      expect(plan.entries.every((entry) => entry.deletable), isTrue);
      expect(plan.deletable, hasLength(2));
      expect(plan.refused, isEmpty);
      expect(plan.toJson()['summary'], {
        'targets': 2,
        'deletable': 2,
        'refused': 0,
      });
    });

    test('refuses the primary Home, a Test Home, and anything outside', ()  async {
      final primaryEndpoint = File(
        p.join(primaryHome, '.local_gateway_endpoint.json'),
      )..writeAsStringSync('{}');
      final testHomeEndpoint = File(
        p.join(userHome, '.sanad-test', '.local_gateway_endpoint.json'),
      )..writeAsStringSync('{}');
      final outside = Directory(p.join(root.path, 'elsewhere'))..createSync();
      final record = Directory(p.join(devArea, 'runtimes', 'gone-33333333'))
        ..createSync();

      final plan = await planFor([
        _orphan(sanad_dev.InventoryOrphanKind.endpointRecord, primaryEndpoint.path),
        _orphan(
          sanad_dev.InventoryOrphanKind.endpointRecord,
          testHomeEndpoint.path,
        ),
        _orphan(sanad_dev.InventoryOrphanKind.devHome, outside.path),
        _orphan(sanad_dev.InventoryOrphanKind.runtimeRecord, record.path),
      ]);

      expect(
        entry(plan, primaryEndpoint.path).refusal,
        'outside the sanad-dev dev area',
      );
      expect(entry(plan, testHomeEndpoint.path).refusal, 'target is a Test Home');
      expect(
        entry(plan, outside.path).refusal,
        'outside the sanad-dev dev area',
      );
      expect(entry(plan, record.path).deletable, isTrue);
      expect(plan.refused, hasLength(3));
    });

    test('refuses the dev area itself and its group directories', ()  async {
      final plan = await planFor([
        _orphan(sanad_dev.InventoryOrphanKind.devHome, devArea),
        _orphan(
          sanad_dev.InventoryOrphanKind.runtimeRecord,
          p.join(devArea, 'runtimes'),
        ),
      ]);

      expect(entry(plan, devArea).refusal, 'target is the dev area itself');
      expect(
        entry(plan, p.join(devArea, 'runtimes')).refusal,
        'target is a dev-area group directory',
      );
    });

    test('refuses a symbolic link even when it resolves inside the dev area',
        ()  async {
      if (Platform.isWindows) return;
      final real = Directory(p.join(devArea, 'homes', 'real-44444444'))
        ..createSync();
      final link = Link(p.join(devArea, 'homes', 'link-55555555'))
        ..createSync(real.path);
      final plan = await planFor([
        _orphan(sanad_dev.InventoryOrphanKind.devHome, link.path),
      ]);

      expect(entry(plan, link.path).refusal, 'target is a symbolic link');
    });

    test('refuses a target a live runtime still owns', ()  async {
      final home = Directory(p.join(devArea, 'homes', 'live-66666666'))
        ..createSync();
      final plan = await planFor(
        [_orphan(sanad_dev.InventoryOrphanKind.devHome, home.path)],
        runtimes: [
          _runtime(
            worktreeId: 'live-66666666',
            home: home.path,
            runtimeClass: sanad_dev.InventoryRuntimeClass.managed,
            agentPort: 58092,
          ),
        ],
      );

      expect(entry(plan, home.path).refusal, 'live runtime (agent port 58092)');
    });

    test('refuses a record whose recorded process is still running', () async {
      // A record is evidence: it is the last on-disk pointer to a live process,
      // so deleting it removes the only cheap way to find that process.
      final record = Directory(p.join(devArea, 'runtimes', 'live-88888888'))
        ..createSync();
      File(p.join(record.path, 'runtime.json')).writeAsStringSync(
        '{"agent_pid": 4321, "client_pid": 8765}',
      );

      final plan = await planFor(
        [_orphan(sanad_dev.InventoryOrphanKind.runtimeRecord, record.path)],
        processRunning: (pid) async => pid == 8765,
      );

      expect(entry(plan, record.path).refusal,
          'recorded process pid 8765 is still running');
    });

    test('an endpoint record naming a live pid is refused too', () async {
      final home = Directory(p.join(devArea, 'homes', 'stale-99999999'))
        ..createSync();
      final endpointFile = File(
        p.join(home.path, '.local_gateway_endpoint.json'),
      )..writeAsStringSync('{"schema": 1, "pid": 4321}');

      final plan = await planFor(
        [
          _orphan(
            sanad_dev.InventoryOrphanKind.endpointRecord,
            endpointFile.path,
          ),
        ],
        processRunning: (pid) async => pid == 4321,
      );

      expect(entry(plan, endpointFile.path).refusal,
          'recorded process pid 4321 is still running');
    });

    test('an unreadable record names no process and stays deletable', () async {
      final record = Directory(p.join(devArea, 'runtimes', 'broken-12121212'))
        ..createSync();
      File(p.join(record.path, 'runtime.json')).writeAsStringSync('{not json');

      final plan = await planFor(
        [_orphan(sanad_dev.InventoryOrphanKind.runtimeRecord, record.path)],
      );

      expect(entry(plan, record.path).deletable, isTrue);
    });

    test('refuses a deletion whose parent now escapes the dev area', () async {
      if (Platform.isWindows) return;
      final outsideHomes = Directory(p.join(root.path, 'outside-homes'))
        ..createSync();
      final outsideTarget = Directory(
        p.join(outsideHomes.path, 'swap-77777777'),
      )..createSync();
      Directory(p.join(devArea, 'homes')).deleteSync(recursive: true);
      Link(p.join(devArea, 'homes')).createSync(outsideHomes.path);

      await expectLater(
        sanad_dev.deleteSanadDevOrphanTarget(
          p.join(devArea, 'homes', 'swap-77777777'),
          devArea: devArea,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(outsideTarget.existsSync(), isTrue);
    });
  });

  group('sanad-dev cleanup-orphans command', () {
    late Directory root;
    late String userHome;
    late String primaryHome;
    late String devArea;
    late Directory staleHome;
    late Directory staleRecord;
    late String testHomeEndpoint;

    setUp(() {
      exitCode = 0;
      root = Directory.systemTemp.createTempSync('sanad-cleanup-run-');
      userHome = p.join(root.path, 'user');
      primaryHome = p.join(userHome, '.sanad');
      devArea = p.join(primaryHome, 'dev');
      staleHome = Directory(p.join(devArea, 'homes', 'stale-11111111'))
        ..createSync(recursive: true);
      File(p.join(staleHome.path, 'dev', 'runtime-launcher-58092.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      staleRecord = Directory(p.join(devArea, 'runtimes', 'gone-22222222'))
        ..createSync(recursive: true);
      File(p.join(staleRecord.path, 'startup-attempt.json'))
        .writeAsStringSync('{}');
      testHomeEndpoint = p.join(
        userHome,
        '.sanad-test',
        '.local_gateway_endpoint.json',
      );
      File(testHomeEndpoint)
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
    });
    tearDown(() {
      exitCode = 0;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    sanad_dev.SanadDevInventory inventory() => _inventory(
      userHome: userHome,
      primaryHome: primaryHome,
      orphans: [
        _orphan(sanad_dev.InventoryOrphanKind.devHome, staleHome.path),
        _orphan(sanad_dev.InventoryOrphanKind.runtimeRecord, staleRecord.path),
        _orphan(sanad_dev.InventoryOrphanKind.endpointRecord, testHomeEndpoint),
      ],
    );

    test('dry run lists every target and deletes nothing', () async {
      final output = await _capture(() async {
        await sanad_dev.handleSanadDevOrphanCleanup(
          confirm: false,
          json: false,
          collect: () async => inventory(),
          clock: () => DateTime.utc(2026, 11, 9, 12),
        );
      });

      expect(output, contains('Orphan cleanup (dry run)'));
      expect(output, contains('Nothing is deleted without --confirm.'));
      expect(output, contains('delete'));
      expect(output, contains('refuse'));
      expect(output, contains('2 deletable, 1 refused'));
      expect(output, contains('cleanup-orphans --confirm'));
      expect(output, isNot(contains('removed')));
      expect(staleHome.existsSync(), isTrue);
      expect(staleRecord.existsSync(), isTrue);
      expect(File(testHomeEndpoint).existsSync(), isTrue);
      expect(exitCode, 0);
    });

    test('confirm deletes only the listed in-area targets, then is idempotent',
        () async {
      final inventoryValue = inventory();
      final output = await _capture(() async {
        await sanad_dev.handleSanadDevOrphanCleanup(
          confirm: true,
          json: false,
          collect: () async => inventoryValue,
          clock: () => DateTime.utc(2026, 11, 9, 12),
        );
      });

      expect(output, contains('Orphan cleanup (confirmed)'));
      expect(output, contains('deleted'));
      expect(output, contains('Deleted 2, absent 0, failed 0.'));
      expect(staleHome.existsSync(), isFalse);
      expect(staleRecord.existsSync(), isFalse);
      expect(File(testHomeEndpoint).existsSync(), isTrue);
      expect(exitCode, 0);

      staleHome.createSync(recursive: true);
      staleHome.deleteSync(recursive: true);
      final second = await _capture(() async {
        await sanad_dev.handleSanadDevOrphanCleanup(
          confirm: true,
          json: false,
          collect: () async => _inventory(
            userHome: userHome,
            primaryHome: primaryHome,
            orphans: [
              _orphan(sanad_dev.InventoryOrphanKind.endpointRecord, testHomeEndpoint),
            ],
          ),
          clock: () => DateTime.utc(2026, 11, 9, 12),
        );
      });
      expect(second, contains('Nothing to clean'));
      expect(second, contains('kept endpoint_record'));
      expect(File(testHomeEndpoint).existsSync(), isTrue);
      expect(exitCode, 0);
    });

    test('stops at the first failure, reports it, and keeps the target', () async {
      final output = await _capture(() async {
        await sanad_dev.handleSanadDevOrphanCleanup(
          confirm: true,
          json: false,
          collect: () async => inventory(),
          clock: () => DateTime.utc(2026, 11, 9, 12),
          deleteTarget: (target) async =>
              throw FileSystemException('permission denied', target),
        );
      });

      expect(output, contains('failed'));
      expect(output, contains('permission denied'));
      expect(output, contains('Stopped at the first failure'));
      expect(output, contains('Deleted 0, absent 0, failed 1.'));
      expect(staleHome.existsSync(), isTrue);
      expect(staleRecord.existsSync(), isTrue);
      expect(exitCode, 1);
    });

    test('reports an already absent target without failing', () async {
      staleHome.deleteSync(recursive: true);
      final output = await _capture(() async {
        await sanad_dev.handleSanadDevOrphanCleanup(
          confirm: true,
          json: false,
          collect: () async => inventory(),
          clock: () => DateTime.utc(2026, 11, 9, 12),
        );
      });

      expect(output, contains('absent'));
      expect(output, contains('absent 1'));
      expect(exitCode, 0);
      expect(staleRecord.existsSync(), isFalse);
    });

    test('the confirmed run re-reads the projection before deleting', () async {
      var projections = 0;
      await _capture(() async {
        await sanad_dev.handleSanadDevOrphanCleanup(
          confirm: true,
          json: false,
          collect: () async {
            projections++;
            return inventory();
          },
          clock: () => DateTime.utc(2026, 11, 9, 12),
        );
      });
      expect(projections, 2, reason: 'dry-run projection, then re-verification');
    });
  });
}

/// Synthetic projections name no running process.
Future<bool> _noLiveProcess(int? pid) async => false;

sanad_dev.InventoryOrphan _orphan(
  sanad_dev.InventoryOrphanKind kind,
  String target,
) {
  return sanad_dev.InventoryOrphan(
    kind: kind,
    target: target,
    reason: 'no matching worktree',
    cleanupCommand: 'rm -rf $target',
    detail: null,
  );
}

sanad_dev.InventoryRuntime _runtime({
  required String worktreeId,
  required String home,
  required sanad_dev.InventoryRuntimeClass runtimeClass,
  int? agentPort,
}) {
  return sanad_dev.InventoryRuntime(
    worktreeId: worktreeId,
    worktreePath: null,
    home: home,
    primary: false,
    runtimeClass: runtimeClass,
    agentPort: agentPort,
    agentPid: null,
    agentAlive: runtimeClass != sanad_dev.InventoryRuntimeClass.stopped,
    vmServicePort: null,
    sourceCommit: '',
    clients: const [],
    leaseOwner: null,
    leaseStatus: null,
    leasePid: null,
    leaseAlive: false,
    detail: 'fixture',
  );
}

sanad_dev.SanadDevInventory _inventory({
  required String userHome,
  required String primaryHome,
  required List<sanad_dev.InventoryOrphan> orphans,
  List<sanad_dev.InventoryRuntime> runtimes = const [],
}) {
  return sanad_dev.SanadDevInventory(
    generatedAt: DateTime.utc(2026, 11, 9, 12),
    userHome: userHome,
    primaryHome: primaryHome,
    repositoryRoot: p.join(userHome, 'repo'),
    callerWorktreeId: 'caller-00000000',
    worktrees: const [],
    runtimes: runtimes,
    clients: const [],
    testHomes: const [],
    orphans: orphans,
    agentProbeTimedOut: false,
    clientProbeTimedOut: false,
  );
}

Future<String> _capture(Future<void> Function() action) async {
  final lines = <String>[];
  await runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines.join('\n');
}
