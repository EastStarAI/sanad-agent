import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/agent_restart_probe.dart';

/// Post-restart identity coverage for `sanad-dev restart agent`.
///
/// Every case answers from a throwaway loopback server: no test starts an Agent,
/// reads a real Home credential, or signals a process.
void main() {
  late Directory root;
  late HttpServer server;
  Map<String, dynamic>? document;
  var statusCode = HttpStatus.ok;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('sanad-restart-probe-');
    document = {
      'status': 'ok',
      'workspace_hash': '00000000',
      'dev_launcher_id': 'launcher-a',
      'dev_runtime_nonce': 'nonce-a',
    };
    statusCode = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = statusCode;
      request.response.write(jsonEncode(document ?? const <String, dynamic>{}));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<AgentRestartProbeResult> probe({
    String launcherId = 'launcher-a',
    String runtimeNonce = 'nonce-a',
    String workspaceHash = '00000000',
    Duration timeout = const Duration(seconds: 1),
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    int? port,
  }) => waitForRestartedAgentIdentity(
    port: port ?? server.port,
    workspaceHash: workspaceHash,
    launcherId: launcherId,
    runtimeNonce: runtimeNonce,
    sanadHome: root.path,
    timeout: timeout,
    clock: clock,
    delay: delay,
  );

  test('an Agent carrying the lease identity proves the restart', () async {
    final result = await probe();

    expect(result.outcome, AgentRestartProbeOutcome.matched);
    expect(result.matched, isTrue);
    expect(result.observedLauncherId, 'launcher-a');
    expect(result.observedRuntimeNonce, 'nonce-a');
  });

  test('a foreign Agent ends the wait instead of timing out', () async {
    document = {
      'status': 'ok',
      'workspace_hash': '11111111',
      'dev_launcher_id': 'launcher-orphan',
      'dev_runtime_nonce': 'nonce-orphan',
    };

    final result = await probe(timeout: const Duration(seconds: 30));

    // A healthy answer with another identity is terminal: the restart did not
    // take effect, and waiting the full window only delays the diagnosis.
    expect(result.outcome, AgentRestartProbeOutcome.foreignIdentity);
    expect(result.sawForeignIdentity, isTrue);
    final described = result.describeObserved(pid: 4711);
    expect(described, contains('pid 4711'));
    expect(described, contains('launcher-orphan'));
    expect(described, contains('nonce-orphan'));
    expect(described, contains('expected workspace 00000000'));
  });

  test('an unfinished health payload keeps waiting', () async {
    // A restarting daemon publishes `status: ok` only once. Anything else is
    // progress, not a foreign owner.
    document = {'status': 'starting'};
    var calls = 0;
    final started = DateTime.utc(2026, 11, 9, 17, 30);
    DateTime clock() => started.add(Duration(seconds: calls++));

    final result = await probe(
      timeout: const Duration(seconds: 30),
      clock: clock,
      delay: (_) async {},
    );

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
  });

  test('a port with no listener reports no answer', () async {
    final port = server.port;
    await server.close(force: true);
    var calls = 0;
    final started = DateTime.utc(2026, 11, 9, 17, 30);
    DateTime clock() => started.add(Duration(seconds: calls++));

    final result = await probe(port: port, clock: clock, delay: (_) async {});

    expect(result.outcome, AgentRestartProbeOutcome.unanswered);
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
