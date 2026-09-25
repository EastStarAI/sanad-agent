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

void main() {
  group('SanadClientRunner', () {
    late Directory tempHome;
    late ClientCliOwnership ownership;
    late ClientCliHomeResolver resolver;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('sanad_client_cli_test_');
      ownership = ClientCliOwnership(
        processAliveChecker: (pid) async => true,
      );
      resolver = const ClientCliHomeResolver();
    });

    tearDown(() async {
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('prints help documentation with --help or -h', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = const SanadClientRunner();

      final code = await runner.run(['--help'], stdoutSink: out, stderrSink: err);
      expect(code, 0);
      expect(out.toString(), contains('sanad-client'));
      expect(out.toString(), contains('devices'));
    });

    test('prints version with --version or -v', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = const SanadClientRunner(version: '1.2.3');

      final code = await runner.run(['-v'], stdoutSink: out, stderrSink: err);
      expect(code, 0);
      expect(out.toString().trim(), 'sanad-client 1.2.3');
    });

    test('fails deterministically when no Client owns the Sanad Home', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final discovery = ClientCliDiscovery(
        homeResolver: resolver,
        ownership: ownership,
      );
      final runner = SanadClientRunner(discovery: discovery);

      final code = await runner.run(
        ['--home', tempHome.path, 'devices'],
        stdoutSink: out,
        stderrSink: err,
      );
      expect(code, 1);
      expect(err.toString(), contains('No active Sanad Client found'));
    });

    test('fails deterministically when Client CLI is disabled in settings', () async {
      final out = StringBuffer();
      final err = StringBuffer();

      // Write a record where enabled is false
      final record = ClientCliRecord(
        pid: pid,
        port: 58210,
        token: 'test-tok',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: false,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );
      await ownership.acquireOwnership(record);

      final discovery = ClientCliDiscovery(
        homeResolver: resolver,
        ownership: ownership,
      );
      final runner = SanadClientRunner(discovery: discovery);

      final code = await runner.run(
        ['--home', tempHome.path, 'devices'],
        stdoutSink: out,
        stderrSink: err,
      );
      expect(code, 1);
      expect(err.toString(), contains('Client CLI is disabled in Sanad Client settings'));
    });

    test('lists remote devices correctly in human-readable and json formats', () async {
      final record = ClientCliRecord(
        pid: pid,
        port: 58211,
        token: 'test-tok',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );
      await ownership.acquireOwnership(record);

      final mockHttp = MockClient((request) async {
        if (request.url.path == '/health') {
          return http.Response(
            jsonEncode({'status': 'ok', 'enabled': true, 'client_version': '1.0.15'}),
            200,
          );
        }
        if (request.url.path == '/devices') {
          return http.Response(
            jsonEncode({
              'devices': [
                {
                  'id': 'dev-remote-1',
                  'name': 'MacBook Remote',
                  'platform': 'macos',
                  'status': 'online',
                  'is_current': true,
                },
                {
                  'id': 'dev-remote-2',
                  'name': 'Ubuntu Server',
                  'platform': 'linux',
                  'status': 'offline',
                  'is_current': false,
                },
              ],
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final discovery = ClientCliDiscovery(
        homeResolver: resolver,
        ownership: ownership,
        clientFactory: () => mockHttp,
      );
      final runner = SanadClientRunner(
        discovery: discovery,
        httpClientFactory: () => mockHttp,
      );

      // 1. Text table output
      final out = StringBuffer();
      final err = StringBuffer();
      var code = await runner.run(
        ['--home', tempHome.path, 'devices'],
        stdoutSink: out,
        stderrSink: err,
      );
      expect(code, 0);
      expect(out.toString(), contains('dev-remote-1 — MacBook Remote [macos] (online) (current)'));
      expect(out.toString(), contains('dev-remote-2 — Ubuntu Server [linux] (offline)'));

      // 2. JSON output
      final jsonOut = StringBuffer();
      code = await runner.run(
        ['--home', tempHome.path, 'devices', '--json'],
        stdoutSink: jsonOut,
        stderrSink: err,
      );
      expect(code, 0);
      final parsed = jsonDecode(jsonOut.toString());
      expect(parsed['devices'].length, 2);
    });

    test('fails if target device is omitted when running a command', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final runner = const SanadClientRunner();

      final code = await runner.run(
        ['ws', 'list'],
        stdoutSink: out,
        stderrSink: err,
      );
      expect(code, 1);
      expect(err.toString(), contains('Missing target device'));
    });
  });
}
