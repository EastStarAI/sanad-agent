import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_client/features/client_cli/data/client_cli_home_resolver.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_exceptions.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_record.dart';

void main() {
  group('ClientCliRecord', () {
    test('serializes and deserializes correctly', () {
      final now = DateTime.utc(2026, 9, 25, 12, 0, 0);
      final record = ClientCliRecord(
        pid: 1234,
        port: 58190,
        token: 'secret-token-123',
        sanadHome: '/tmp/test_sanad',
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: now,
      );

      final json = record.toJson();
      expect(json['version'], clientCliRecordVersion);
      expect(json['pid'], 1234);
      expect(json['port'], 58190);
      expect(json['token'], 'secret-token-123');
      expect(json['sanad_home'], '/tmp/test_sanad');
      expect(json['client_version'], '1.0.15');
      expect(json['enabled'], true);
      expect(json['permission_mode'], 'default');
      expect(json['updated_at'], now.toIso8601String());

      final restored = ClientCliRecord.fromJson(json);
      expect(restored.pid, 1234);
      expect(restored.port, 58190);
      expect(restored.token, 'secret-token-123');
      expect(restored.sanadHome, '/tmp/test_sanad');
      expect(restored.clientVersion, '1.0.15');
      expect(restored.enabled, true);
      expect(restored.permissionMode, 'default');
      expect(restored.updatedAt, now);
    });

    test('rejects unsupported version', () {
      final json = {
        'version': 999,
        'pid': 1234,
        'port': 58190,
        'token': 'tok',
        'sanad_home': '/tmp',
        'client_version': '1.0',
        'enabled': true,
        'permission_mode': 'default',
      };
      expect(() => ClientCliRecord.fromJson(json), throwsFormatException);
    });
  });

  group('ClientCliHomeResolver', () {
    const resolver = ClientCliHomeResolver();

    test('prefers explicit home parameter over all others', () {
      final resolved = resolver.resolveSanadHome(
        explicitHome: '/custom/sanad',
        environment: {
          'SANAD_HOME': '/env/sanad',
          'HOME': '/user/home',
        },
      );
      expect(resolved, p.normalize(p.absolute('/custom/sanad')));
    });

    test('falls back to SANAD_HOME when explicit home is null or empty', () {
      final resolved = resolver.resolveSanadHome(
        explicitHome: '   ',
        environment: {
          'SANAD_HOME': '/env/sanad',
          'HOME': '/user/home',
        },
      );
      expect(resolved, p.normalize(p.absolute('/env/sanad')));
    });

    test('falls back to default user home when SANAD_HOME is absent', () {
      final resolved = resolver.resolveSanadHome(
        explicitHome: null,
        environment: {
          'HOME': '/user/home',
        },
      );
      expect(resolved, p.normalize(p.absolute('/user/home/.sanad')));
    });
  });

  group('ClientCliOwnership', () {
    late Directory tempHome;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('sanad_cli_test_');
    });

    tearDown(() async {
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('acquires ownership and reads record with owner-only permissions', () async {
      final ownership = ClientCliOwnership(
        processAliveChecker: (pid) async => false,
      );

      final record = ClientCliRecord(
        pid: pid,
        port: 58200,
        token: 'auth-token-xyz',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );

      await ownership.acquireOwnership(record);

      final recordFile = File(ownership.recordPath(tempHome.path));
      expect(await recordFile.exists(), isTrue);

      if (!Platform.isWindows) {
        final stat = await recordFile.stat();
        expect(stat.mode & 0x1ff, 0x180); // 0600
      }

      final loaded = await ownership.readRecord(tempHome.path);
      expect(loaded, isNotNull);
      expect(loaded!.pid, pid);
      expect(loaded.port, 58200);
      expect(loaded.token, 'auth-token-xyz');
      expect(loaded.enabled, isTrue);
    });

    test('rejects insecure file permissions on POSIX', () async {
      if (Platform.isWindows) return;

      final ownership = ClientCliOwnership();
      final record = ClientCliRecord(
        pid: pid,
        port: 58201,
        token: 'auth-token-xyz',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );

      await ownership.acquireOwnership(record);

      final recordFile = File(ownership.recordPath(tempHome.path));

      // 1. Group read / other read (644)
      await Process.run('chmod', ['644', recordFile.path]);
      expect(
        () => ownership.readRecord(tempHome.path, verifyPermissions: true),
        throwsA(isA<ClientCliSecurityException>()),
      );

      // 2. Group execute only (610)
      await Process.run('chmod', ['610', recordFile.path]);
      expect(
        () => ownership.readRecord(tempHome.path, verifyPermissions: true),
        throwsA(isA<ClientCliSecurityException>()),
      );

      // 3. Other execute only (601)
      await Process.run('chmod', ['601', recordFile.path]);
      expect(
        () => ownership.readRecord(tempHome.path, verifyPermissions: true),
        throwsA(isA<ClientCliSecurityException>()),
      );

      // 4. Executable record file (700)
      await Process.run('chmod', ['700', recordFile.path]);
      expect(
        () => ownership.readRecord(tempHome.path, verifyPermissions: true),
        throwsA(isA<ClientCliSecurityException>()),
      );
    });

    test('cleans up stale owner when process is dead', () async {
      final ownership = ClientCliOwnership(
        processAliveChecker: (checkPid) async => false, // simulates dead process
      );

      // Write an old record from a dead process
      final staleRecord = ClientCliRecord(
        pid: 99999,
        port: 58202,
        token: 'stale-token',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );
      await ownership.acquireOwnership(staleRecord);

      // Now a new process acquires ownership
      final newRecord = ClientCliRecord(
        pid: pid,
        port: 58203,
        token: 'new-token',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'full_access',
        updatedAt: DateTime.now().toUtc(),
      );

      // Should succeed because stale owner was cleaned up
      await ownership.acquireOwnership(newRecord);

      final loaded = await ownership.readRecord(tempHome.path);
      expect(loaded!.pid, pid);
      expect(loaded.port, 58203);
      expect(loaded.permissionMode, 'full_access');
    });

    test('throws ClientCliAmbiguousOwnerException if another live Client owns the Home', () async {
      final ownership = ClientCliOwnership(
        processAliveChecker: (checkPid) async => true, // simulates alive process
        healthProber: (host, port, token) async => true, // healthy
      );

      // Existing live owner
      final existingRecord = ClientCliRecord(
        pid: 88888,
        port: 58204,
        token: 'other-live-token',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );
      final initialOwnership = ClientCliOwnership(
        processAliveChecker: (_) async => false,
      );
      await initialOwnership.acquireOwnership(existingRecord);

      // Competing live process tries to acquire
      final competingRecord = ClientCliRecord(
        pid: 77777,
        port: 58205,
        token: 'competing-token',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );

      expect(
        () => ownership.acquireOwnership(competingRecord),
        throwsA(isA<ClientCliAmbiguousOwnerException>()),
      );
    });

    test('releases ownership cleanly', () async {
      final ownership = ClientCliOwnership();
      final record = ClientCliRecord(
        pid: pid,
        port: 58206,
        token: 'token-to-delete',
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
        enabled: true,
        permissionMode: 'default',
        updatedAt: DateTime.now().toUtc(),
      );

      await ownership.acquireOwnership(record);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isTrue);

      await ownership.releaseOwnership(tempHome.path, pid: pid);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isFalse);
    });
  });
}
