import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_client/features/client_cli/cli/sanad_client_runner.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_discovery.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_home_resolver.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_record.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_relay_policy.dart';

/// Minimal loopback stand-in for the running Client: it answers the discovery
/// health probe and upgrades `/ws` into the relay socket.
class _FakeRelayHost {
  _FakeRelayHost._(this._server);

  final HttpServer _server;
  final List<Map<String, dynamic>> frames = [];
  final _frameController = StreamController<Map<String, dynamic>>.broadcast();
  WebSocket? _socket;

  static Future<_FakeRelayHost> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _FakeRelayHost._(server);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'status': 'ok',
              'enabled': true,
              'client_version': '1.0.15',
            }),
          );
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      host._socket = socket;
      socket.listen((data) {
        final frame = jsonDecode(data.toString()) as Map<String, dynamic>;
        host.frames.add(frame);
        if (!host._frameController.isClosed) host._frameController.add(frame);
      });
    });
    return host;
  }

  int get port => _server.port;

  List<Map<String, dynamic>> get executes =>
      frames.where((frame) => frame['type'] == 'execute').toList();

  Map<String, dynamic> get execute => executes.last;

  Future<Map<String, dynamic>> waitForExecute() async {
    if (executes.isNotEmpty) return executes.last;
    return _frameController.stream
        .firstWhere((frame) => frame['type'] == 'execute')
        .timeout(const Duration(seconds: 5));
  }

  void send(Map<String, dynamic> frame) => _socket!.add(jsonEncode(frame));

  Future<void> close() async {
    await _socket?.close();
    await _server.close(force: true);
    await _frameController.close();
  }
}

void main() {
  group('SanadClientRunner remote relay', () {
    late Directory tempHome;
    late ClientCliOwnership ownership;
    late _FakeRelayHost relayHost;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('sanad_client_relay_');
      ownership = ClientCliOwnership(processAliveChecker: (_) async => true);
      relayHost = await _FakeRelayHost.start();
      await ownership.acquireOwnership(
        ClientCliRecord(
          pid: pid,
          port: relayHost.port,
          token: 'test-tok',
          sanadHome: tempHome.path,
          clientVersion: '1.0.15',
          enabled: true,
          permissionMode: 'default',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    });

    tearDown(() async {
      await relayHost.close();
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    SanadClientRunner buildRunner({
      ClientCliStdinReader? stdinReader,
      String version = '1.0.15',
    }) {
      final discovery = ClientCliDiscovery(
        homeResolver: const ClientCliHomeResolver(),
        ownership: ownership,
        clientFactory: () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': 'ok',
              'enabled': true,
              'client_version': '1.0.15',
            }),
            200,
          ),
        ),
      );
      return SanadClientRunner(
        discovery: discovery,
        version: version,
        stdinReader: stdinReader,
      );
    }

    test('forwards the command timeout as the relay window', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = buildRunner();

      final run = runner.run(
        [
          '--home',
          tempHome.path,
          '-d',
          'remote-1',
          'run',
          '--workspace',
          'ws-core',
          '--timeout',
          '5400',
          'do the work',
        ],
        stdoutSink: out,
        stderrSink: err,
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['timeout_seconds'], 5430);
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
        'cancelled': false,
        'timed_out': false,
      });
      expect(await run, 0);
    });

    test('keeps the protocol default window without a command timeout', () async {
      final runner = buildRunner();
      final run = runner.run(
        ['--home', tempHome.path, '-d', 'remote-1', 'ws', 'list'],
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['timeout_seconds'], clientCliRelayDefaultTimeoutSeconds);
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
      });
      expect(await run, 0);
    });

    test('a brief-file run never waits for standard input', () async {
      final briefFile = File('${tempHome.path}/brief.md')
        ..writeAsStringSync('# Task brief\nDo the work.\n');
      var stdinReads = 0;
      final runner = buildRunner(
        stdinReader: () async {
          stdinReads++;
          return 'PIPED-STDIN';
        },
      );

      final run = runner.run(
        [
          '--home',
          tempHome.path,
          '-d',
          'remote-1',
          'run',
          '--workspace',
          'ws-core',
          '--brief-file',
          briefFile.path,
        ],
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['brief_content'], contains('Do the work.'));
      expect(execute['stdin'], isNull);
      expect(stdinReads, 0);
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
      });
      expect(await run, 0);
    });

    test('a command that takes no prompt never waits for standard input', () async {
      // A background caller owns a non-TTY standard input that never reaches
      // EOF; reading it would hang before anything is forwarded.
      final neverEndingStdin = Completer<String?>();
      addTearDown(() {
        if (!neverEndingStdin.isCompleted) neverEndingStdin.complete(null);
      });
      final runner = buildRunner(stdinReader: () => neverEndingStdin.future);

      final run = runner.run(
        [
          '--home',
          tempHome.path,
          '-d',
          'remote-1',
          'providers',
          'list',
        ],
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['argv'], ['providers', 'list']);
      expect(execute['stdin'], isNull);
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 64,
      });
      expect(await run, 64);
    });

    test('a session steer is relayed as verbatim argv with no stdin wait', () async {
      // The relay forwards the argument vector to the target Agent's own
      // command runner, so a session subcommand needs no caller-side
      // allow-list entry to be relayable.
      final neverEndingStdin = Completer<String?>();
      addTearDown(() {
        if (!neverEndingStdin.isCompleted) neverEndingStdin.complete(null);
      });
      final runner = buildRunner(stdinReader: () => neverEndingStdin.future);

      final run = runner.run(
        [
          '--home',
          tempHome.path,
          '-d',
          'remote-1',
          'session',
          'steer',
          'sess-remote-1',
          '--message',
          'Add an audit trail',
          '--timeout',
          '20',
        ],
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['argv'], [
        'session',
        'steer',
        'sess-remote-1',
        '--message',
        'Add an audit trail',
        '--timeout',
        '20',
      ]);
      expect(execute['stdin'], isNull);
      expect(execute['timeout_seconds'], 50);
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
      });
      expect(await run, 0);
    });

    test('a run without a prompt still forwards piped standard input', () async {
      var stdinReads = 0;
      final runner = buildRunner(
        stdinReader: () async {
          stdinReads++;
          return 'PROMPT FROM STDIN';
        },
      );

      final run = runner.run(
        ['--home', tempHome.path, '-d', 'remote-1', 'run', '--workspace', 'ws'],
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['stdin'], 'PROMPT FROM STDIN');
      expect(stdinReads, 1);
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
      });
      expect(await run, 0);
    });

    test('an explicit --stdin forces forwarding and is not relayed as argv', () async {
      final briefFile = File('${tempHome.path}/brief.md')
        ..writeAsStringSync('# Task brief\n');
      final runner = buildRunner(stdinReader: () async => 'EXTRA CONTEXT');

      final run = runner.run(
        [
          '--home',
          tempHome.path,
          '-d',
          'remote-1',
          'run',
          briefFile.path,
          '--stdin',
        ],
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );

      final execute = await relayHost.waitForExecute();
      expect(execute['argv'], ['run', briefFile.path]);
      expect(execute['stdin'], 'EXTRA CONTEXT');
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
      });
      expect(await run, 0);
    });

    test('announces a pending approval once on stderr, never on stdout', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = buildRunner();

      final run = runner.run(
        [
          '--home',
          tempHome.path,
          '-d',
          'remote-1',
          'ws',
          'list',
          '--json',
        ],
        stdoutSink: out,
        stderrSink: err,
      );

      final execute = await relayHost.waitForExecute();
      relayHost.send({
        'type': 'status',
        'request_id': execute['request_id'],
        'code': clientCliApprovalPendingStatus,
        'message': clientCliApprovalPendingMessage,
      });
      relayHost.send({
        'type': 'result',
        'request_id': execute['request_id'],
        'exit_code': 0,
      });
      expect(await run, 0);

      final stderrText = err.toString();
      expect(
        stderrText.split('\n').where((line) => line.contains('Waiting for approval')),
        hasLength(1),
      );
      expect(out.toString(), isNot(contains('Waiting for approval')));
    });

    test('fails closed when the relay ends without a terminal result', () async {
      final err = StringBuffer();
      final runner = buildRunner();

      final run = runner.run(
        ['--home', tempHome.path, '-d', 'remote-1', 'ws', 'list'],
        stdoutSink: StringBuffer(),
        stderrSink: err,
      );

      await relayHost.waitForExecute();
      await relayHost.close();

      expect(await run, isNot(0));
      expect(err.toString(), contains('without a terminal result'));
    });
  });
}
