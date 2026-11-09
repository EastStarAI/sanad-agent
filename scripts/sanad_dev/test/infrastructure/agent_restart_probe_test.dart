import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/agent_restart_probe.dart';

/// Post-restart proof coverage for `sanad-dev restart agent`.
///
/// Every case answers from a throwaway loopback server and a temporary Home: no
/// test starts an Agent, reads a real Home credential, or signals a process.
/// The owner record is what separates the daemon that accepted `/restart` from
/// the replacement that inherits its launcher identity, so most cases below
/// change only that file.
void main() {
  late Directory root;
  late HttpServer server;
  late int requests;
  Map<String, dynamic>? document;
  var statusCode = HttpStatus.ok;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('sanad-restart-probe-');
    requests = 0;
    document = {
      'status': 'ok',
      'workspace_hash': '00000000',
      'dev_launcher_id': 'launcher-a',
      'dev_runtime_nonce': 'nonce-a',
    };
    statusCode = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.statusCode = statusCode;
      request.response.write(jsonEncode(document ?? const <String, dynamic>{}));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Writes the Home owner record the daemon publishes beside its lock.
  void recordOwner({
    required int? pid,
    String launcherId = 'launcher-a',
    String runtimeNonce = 'nonce-a',
  }) => File(p.join(root.path, '.runtime-owner.json')).writeAsStringSync(
    jsonEncode({
      'schema': 1,
      'pid': pid,
      'launcher_id': launcherId,
      'runtime_nonce': runtimeNonce,
    }),
  );

  /// A clock that jumps [step] per read, so a bounded window stays cheap.
  DateTime Function() stepper({int step = 1}) {
    var calls = 0;
    final started = DateTime.utc(2026, 11, 9, 17, 30);
    return () => started.add(Duration(seconds: step * calls++));
  }

  Future<AgentRestartProbeResult> probe({
    String launcherId = 'launcher-a',
    String runtimeNonce = 'nonce-a',
    String workspaceHash = '00000000',
    int? previousDaemonPid,
    Duration timeout = const Duration(seconds: 5),
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Future<bool> Function(int pid) processRunning = _neverRunning,
    int? port,
  }) => waitForRestartedAgentIdentity(
    port: port ?? server.port,
    workspaceHash: workspaceHash,
    launcherId: launcherId,
    runtimeNonce: runtimeNonce,
    sanadHome: root.path,
    previousDaemonPid: previousDaemonPid,
    timeout: timeout,
    clock: clock,
    delay: delay,
    processRunning: processRunning,
  );

  test('the daemon that accepted the request is not the restart proof', () async {
    // This is the false success a live run produced 17-20 ms after the request,
    // 5.9 s before the replacement existed: the supervised respawn keeps the
    // launcher id and nonce, so the shutting-down daemon still verified.
    recordOwner(pid: 4700);
    final result = await probe(
      previousDaemonPid: 4700,
      clock: stepper(),
      delay: (_) async {},
    );

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
    expect(result.matched, isFalse);
    expect(result.previousDaemonPid, 4700);
    expect(result.recordedHolder?.pid, 4700);
    expect(result.describeStalledRestart(), contains('pid 4700'));
  });

  test(
    'a replacement owner with the lease identity proves the restart',
    () async {
      recordOwner(pid: 4700);
      final result = await probe(
        previousDaemonPid: 4700,
        clock: stepper(),
        // The supervised respawn writes its own owner record; only then may the
        // probe accept the identity that both generations share.
        delay: (_) async => recordOwner(pid: 4800),
      );

      expect(result.outcome, AgentRestartProbeOutcome.matched);
      expect(result.recordedHolder?.pid, 4800);
      expect(result.observedLauncherId, 'launcher-a');
      expect(result.observedRuntimeNonce, 'nonce-a');
      // One poll observed the old owner, so matching on the first answer is
      // impossible by construction.
      expect(requests, greaterThanOrEqualTo(2));
    },
  );

  test(
    'an unrecorded baseline still requires a recorded replacement',
    () async {
      recordOwner(pid: 4800);
      final result = await probe(previousDaemonPid: null, clock: stepper());

      expect(result.outcome, AgentRestartProbeOutcome.matched);
      expect(result.previousDaemonPid, isNull);
    },
  );

  test('a Home without an owner record never claims success', () async {
    // A daemon too old to publish the record cannot prove a replacement, and a
    // false success here is the exact failure mode this proof exists to stop.
    final result = await probe(
      previousDaemonPid: 4700,
      clock: stepper(),
      delay: (_) async {},
    );

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
    expect(result.recordedHolder, isNull);
  });

  test('a live unmanaged holder is named instead of waiting', () async {
    recordOwner(pid: 4300, launcherId: '', runtimeNonce: '');
    final result = await probe(
      previousDaemonPid: 4700,
      timeout: const Duration(seconds: 30),
      clock: stepper(),
      processRunning: (pid) async => pid == 4300,
    );

    expect(result.outcome, AgentRestartProbeOutcome.foreignHolder);
    expect(result.sawForeignHolder, isTrue);
    expect(result.recordedHolder?.describe(), contains('pid 4300'));
    expect(result.recordedHolder?.describe(), contains('unmanaged'));
    expect(result.describeStalledRestart(), contains('pid 4300'));
    // The holder alone is terminal: no health request is needed to name it.
    expect(requests, 0);
  });

  test(
    'a live holder with another launcher is named with both identities',
    () async {
      recordOwner(
        pid: 4300,
        launcherId: 'launcher-orphan',
        runtimeNonce: 'nonce-orphan',
      );
      final result = await probe(
        previousDaemonPid: 4700,
        timeout: const Duration(seconds: 30),
        clock: stepper(),
        processRunning: (_) async => true,
      );

      expect(result.outcome, AgentRestartProbeOutcome.foreignHolder);
      expect(result.recordedHolder?.describe(), contains('launcher-orphan'));
      expect(result.recordedHolder?.describe(), contains('nonce-orphan'));
    },
  );

  test('a stale foreign record does not end the wait early', () async {
    // A dead pid is history, not a holder: a replacement may still take over.
    recordOwner(pid: 4300, launcherId: 'launcher-orphan', runtimeNonce: 'n');
    final result = await probe(
      previousDaemonPid: 4700,
      clock: stepper(),
      delay: (_) async {},
      processRunning: (_) async => false,
    );

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
  });

  test(
    'a foreign Agent on the port ends the wait instead of timing out',
    () async {
      recordOwner(pid: 4700);
      document = {
        'status': 'ok',
        'workspace_hash': '11111111',
        'dev_launcher_id': 'launcher-orphan',
        'dev_runtime_nonce': 'nonce-orphan',
      };

      final result = await probe(
        previousDaemonPid: 4700,
        timeout: const Duration(seconds: 30),
        clock: stepper(),
      );

      // A healthy answer with another identity is terminal: the restart did not
      // take effect, and waiting the full window only delays the diagnosis.
      expect(result.outcome, AgentRestartProbeOutcome.foreignIdentity);
      expect(result.sawForeignIdentity, isTrue);
      final described = result.describeObserved(pid: 4711);
      expect(described, contains('pid 4711'));
      expect(described, contains('launcher-orphan'));
      expect(described, contains('expected workspace 00000000'));
    },
  );

  test('an unfinished health payload keeps waiting', () async {
    recordOwner(pid: 4800);
    document = {'status': 'starting'};
    final result = await probe(
      previousDaemonPid: 4700,
      timeout: const Duration(seconds: 30),
      clock: stepper(step: 10),
      delay: (_) async {},
    );

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
  });

  test('a port with no listener reports no answer', () async {
    final port = server.port;
    await server.close(force: true);
    recordOwner(pid: 4800);

    final result = await probe(
      port: port,
      previousDaemonPid: 4700,
      clock: stepper(),
      delay: (_) async {},
    );

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
  });

  test('the stale-restart line names both owners', () async {
    recordOwner(pid: 4700);
    final result = await probe(
      previousDaemonPid: 4700,
      clock: stepper(),
      delay: (_) async {},
    );

    final stalled = result.describeStalledRestart();
    expect(stalled, contains('pre-restart owner was pid 4700'));
    expect(stalled, contains('Home owner is now pid 4700'));
  });

  test('the recorded owner is described without a credential', () async {
    recordOwner(pid: 4800);
    expect(
      await describeHomeHolder(root.path),
      'Home holder: pid 4800 '
      '(launcher launcher-a, nonce nonce-a)',
    );

    File(
      p.join(root.path, '.runtime-owner.json'),
    ).writeAsStringSync('{not json');
    expect(await describeHomeHolder(root.path), isNull);
    expect(await readAgentOwnershipSnapshot(root.path), isNull);
  });

  test('the restart baseline prefers the owner record', () async {
    recordOwner(pid: 4800);
    File(p.join(root.path, '.local_gateway_endpoint.json')).writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'host': '127.0.0.1',
        'port': 58085,
        'pid': 4700,
      }),
    );

    expect(await readRestartBaselineDaemonPid(root.path, 58085), 4800);

    File(p.join(root.path, '.runtime-owner.json')).deleteSync();
    expect(await readRestartBaselineDaemonPid(root.path, 58085), 4700);
    expect(await readRestartBaselineDaemonPid(root.path, 58086), isNull);
  });

  test('the recorded daemon pid is read only for the matching port', () async {
    final home = Directory(p.join(root.path, 'home'))..createSync();
    final record = File(p.join(home.path, '.local_gateway_endpoint.json'))
      ..writeAsStringSync(
        jsonEncode({
          'schema': 1,
          'host': '127.0.0.1',
          'port': 58085,
          'pid': 47800,
        }),
      );

    expect(await readRecordedDaemonPid(home.path, 58085), 47800);
    expect(await readRecordedDaemonPid(home.path, 58086), isNull);

    record.writeAsStringSync('{not json');
    expect(await readRecordedDaemonPid(home.path, 58085), isNull);
  });
}

/// Default process probe: no test asserts on a real user process.
Future<bool> _neverRunning(int pid) async => false;
