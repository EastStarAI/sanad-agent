import 'dart:io';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:test/test.dart';

import '../support/sanad_dev_test_fixtures.dart';

sanad_dev.ClientInstance _client({
  int pid = 4242,
  int? devServicePid = 4343,
  int vmServicePort = 51092,
}) => sanad_dev.ClientInstance(
  vmServicePort,
  'token',
  platformNeutralTestPath('/repo/client'),
  'macos',
  pid: pid,
  devServicePid: devServicePid,
);

void main() {
  group('sanad-dev ui target cache entry', () {
    test('records the leases, endpoints, and both process ids', () {
      final runtime = createTestRuntime(platformNeutral: true);
      final entry = sanad_dev.uiDriverTargetCacheFor(
        runtime: runtime,
        client: _client(),
        sanadHome: runtime.sanadHome,
        agentPort: 58092,
      );

      expect(entry, isNotNull);
      expect(entry!.worktreeId, runtime.worktreeId);
      expect(entry.sanadHome, runtime.sanadHome);
      expect(entry.agentPort, 58092);
      expect(entry.clientPid, 4242);
      expect(entry.devServicePid, 4343);
      expect(entry.vmServicePort, 51092);
      expect(entry.candidatePids, [4343, 4242]);
    });

    test('has nothing to narrow without a development-service pid', () {
      final runtime = createTestRuntime(platformNeutral: true);
      expect(
        sanad_dev.uiDriverTargetCacheFor(
          runtime: runtime,
          client: _client(devServicePid: null),
          sanadHome: runtime.sanadHome,
          agentPort: 58092,
        ),
        isNull,
      );
    });

    test('a matching worktree and Home is usable', () {
      final runtime = createTestRuntime(platformNeutral: true);
      final now = DateTime.utc(2026, 3, 1, 12);
      final entry = sanad_dev.uiDriverTargetCacheFor(
        runtime: runtime,
        client: _client(),
        sanadHome: runtime.sanadHome,
        agentPort: 58092,
        now: now,
      );

      expect(
        sanad_dev.validateUiDriverTargetCache(
          entry,
          runtime: runtime,
          resolvedSanadHome: runtime.sanadHome,
          now: now.add(const Duration(minutes: 1)),
        ),
        isNull,
      );
    });

    test('another worktree, another Home, or age rejects the entry', () {
      final runtime = createTestRuntime(platformNeutral: true);
      final now = DateTime.utc(2026, 3, 1, 12);
      final entry = sanad_dev.uiDriverTargetCacheFor(
        runtime: runtime,
        client: _client(),
        sanadHome: runtime.sanadHome,
        agentPort: 58092,
        now: now,
      );
      final otherWorktree = createTestRuntime(
        platformNeutral: true,
        worktreeId: 'other-aabbccdd',
      );

      expect(
        sanad_dev.validateUiDriverTargetCache(
          entry,
          runtime: otherWorktree,
          resolvedSanadHome: runtime.sanadHome,
        ),
        contains('another worktree'),
      );
      expect(
        sanad_dev.validateUiDriverTargetCache(
          entry,
          runtime: runtime,
          resolvedSanadHome: '/other/home',
        ),
        contains('another Sanad Home'),
      );
      expect(
        sanad_dev.validateUiDriverTargetCache(
          entry,
          runtime: runtime,
          resolvedSanadHome: runtime.sanadHome,
          now: now.add(sanad_dev.uiDriverTargetCacheMaxAge * 2),
        ),
        contains('stale'),
      );
      expect(
        sanad_dev.validateUiDriverTargetCache(
          null,
          runtime: runtime,
          resolvedSanadHome: runtime.sanadHome,
        ),
        'no cached target',
      );
    });

    test('an unknown schema version is not a usable entry', () {
      final encoded = sanad_dev
          .uiDriverTargetCacheFor(
            runtime: createTestRuntime(platformNeutral: true),
            client: _client(),
            sanadHome: '/isolated/home',
            agentPort: 58092,
          )!
          .toJson();
      encoded['version'] = sanad_dev.uiDriverTargetCacheVersion + 1;
      expect(sanad_dev.UiDriverTargetCache.fromJson(encoded), isNull);
      expect(sanad_dev.UiDriverTargetCache.fromJson('nonsense'), isNull);
    });
  });

  group('sanad-dev ui target cache file', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sanad-ui-cache-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'round-trips inside the worktree runtime directory, owner-only',
      () async {
        final runtime = createTestRuntime(runtimeDirectory: root.path);
        final entry = sanad_dev.uiDriverTargetCacheFor(
          runtime: runtime,
          client: _client(),
          sanadHome: runtime.sanadHome,
          agentPort: 58092,
        )!;

        await sanad_dev.writeUiDriverTargetCache(runtime, entry);
        final file = File(sanad_dev.uiDriverTargetCachePath(root.path));
        expect(file.existsSync(), isTrue);
        if (!Platform.isWindows) {
          final mode = file.statSync().mode & 0x1FF;
          expect(mode, 0x180, reason: 'the entry must stay owner-only (0600)');
        }

        final read = await sanad_dev.readUiDriverTargetCache(runtime);
        expect(read, isNotNull);
        expect(read!.toJson(), entry.toJson());

        await sanad_dev.deleteUiDriverTargetCache(runtime);
        expect(file.existsSync(), isFalse);
        expect(await sanad_dev.readUiDriverTargetCache(runtime), isNull);
      },
    );

    test('an unreadable entry is ignored instead of trusted', () async {
      final runtime = createTestRuntime(runtimeDirectory: root.path);
      final file = File(sanad_dev.uiDriverTargetCachePath(root.path));
      await file.writeAsString('{"version": 1}');
      expect(await sanad_dev.readUiDriverTargetCache(runtime), isNull);
    });
  });

  group('sanad-dev ui cached endpoint liveness', () {
    test('reports a listening loopback port and a closed one', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((client) => client.destroy());
      final port = server.port;
      addTearDown(() => server.close());

      expect(await sanad_dev.uiDriverVmServiceReachable(port), isTrue);
      await server.close();

      var closed = false;
      for (var i = 0; i < 10; i++) {
        if (!await sanad_dev.uiDriverVmServiceReachable(port)) {
          closed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(closed, isTrue);
      expect(await sanad_dev.uiDriverVmServiceReachable(0), isFalse);
    });
  });
}
