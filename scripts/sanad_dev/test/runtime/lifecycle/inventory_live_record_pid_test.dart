import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

/// A record that still names a running process is evidence, not an orphan.
///
/// The projection and the cleanup plan both use `recordedPids`, so this covers
/// the shared reading and the projection decision in one place.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sanad-inventory-pid-');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<List<sanad_dev.InventoryRuntimeRecord>> writeRecord({
    Map<String, Object?> legacy = const {'agent_pid': 4321, 'client_pid': 8765},
  }) async {
    final directory = Directory(p.join(root.path, 'gone-12345678'))
      ..createSync(recursive: true);
    File(p.join(directory.path, 'runtime.json')).writeAsStringSync(
      jsonEncode({
        'worktree_id': 'gone-12345678',
        'agent_port': 58090,
        'vm_service_port': 51090,
        'sanad_home': p.join(root.path, '.sanad'),
        ...legacy,
      }),
    );
    return sanad_dev.readInventoryRuntimeRecords(root.path);
  }

  Future<List<sanad_dev.InventoryOrphan>> orphansFor(
    List<sanad_dev.InventoryRuntimeRecord> records, {
    Future<bool> Function(int? pid)? processRunning,
  }) => sanad_dev.buildInventoryOrphans(
    userHome: root.path,
    devHomes: const [],
    records: records,
    homeStates: const [],
    worktrees: const [],
    leases: const [],
    agents: const [],
    leaseIsAlive: (_) => false,
    processRunning: processRunning ?? (pid) async => false,
  );

  test('the legacy record pids are read', () async {
    final records = await writeRecord();
    expect(records.single.agentPid, 4321);
    expect(records.single.clientPid, 8765);
    expect(records.single.recordedPids, [4321, 8765]);
  });

  test('a record naming a live client pid is not an orphan', () async {
    final records = await writeRecord();
    expect(
      await orphansFor(records, processRunning: (pid) async => pid == 8765),
      isEmpty,
    );
  });

  test('a record naming a live agent pid is not an orphan', () async {
    final records = await writeRecord();
    expect(
      await orphansFor(records, processRunning: (pid) async => pid == 4321),
      isEmpty,
    );
  });

  test('a record naming only dead pids stays an orphan', () async {
    final records = await writeRecord();
    final orphans = await orphansFor(records);
    expect(orphans, hasLength(1));
    expect(orphans.single.kind, sanad_dev.InventoryOrphanKind.runtimeRecord);
    expect(orphans.single.reason, 'no matching worktree');
  });

  test('a record with no recorded pids keeps the previous behaviour', () async {
    final records = await writeRecord(legacy: const {});
    expect(records.single.recordedPids, isEmpty);
    expect(await orphansFor(records), hasLength(1));
  });
}
