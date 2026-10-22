import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_dev/src/infrastructure/runtime_home_fixture.dart';
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late Directory workspace;
  late Directory home;

  Future<void> writeHomeFile(String relative, String contents) async {
    final file = File(p.join(home.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-home-fixture-');
    workspace = Directory(p.join(fixture.path, 'worktree'))
      ..createSync(recursive: true);
    home = Directory(p.join(fixture.path, 'home'))..createSync(recursive: true);
    await writeHomeFile('state.db', 'database-v1');
    await writeHomeFile('config.yaml', 'model: test');
    await writeHomeFile('memories/notes.md', '# memory');
    await writeHomeFile('skills/custom/SKILL.md', '# skill');
    await writeHomeFile('workspaces/registry.json', '{}');
    // Everything below must never enter a fixture.
    await writeHomeFile('.env', 'API_KEY=secret');
    await writeHomeFile('.local_token', 'credential');
    await writeHomeFile('.local_token.lock', 'lock');
    await writeHomeFile('provider_secrets.json', '{"key":"secret"}');
    await writeHomeFile('agent_credentials.json', '{"token":"secret"}');
    await writeHomeFile('logs/agent.log', 'noise');
    await writeHomeFile('dev/runtime-launcher-58092.json', '{}');
    await writeHomeFile('sessions/one.json', '{}');
    await writeHomeFile('media/image.png', 'binary');
    await writeHomeFile('bin/sanad', 'binary');
    await writeHomeFile('memories/.env.backup', 'secret');
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  group('fixture capture rules', () {
    test('captures databases and config only', () {
      expect(isFixtureCapturedPath('state.db'), isTrue);
      expect(isFixtureCapturedPath('state.db-wal'), isTrue);
      expect(isFixtureCapturedPath('config.yaml'), isTrue);
      expect(isFixtureCapturedPath('models_dev_cache.json'), isTrue);
      expect(isFixtureCapturedPath('mcp_config.json'), isTrue);
      expect(isFixtureCapturedPath('memories/notes.md'), isTrue);
      expect(isFixtureCapturedPath('skills/custom/SKILL.md'), isTrue);
      expect(isFixtureCapturedPath('workspaces/registry.json'), isTrue);
    });

    test('never captures secrets, runtime state, or content directories', () {
      for (final path in const [
        '.env',
        '.local_token',
        '.local_token.lock',
        'provider_secrets.json',
        'provider_auth.json',
        'mcp_secrets.json',
        'auth.json',
        'agent_credentials.json',
        'agent_credential_backend.json',
        'logs/agent.log',
        'dev/runtime-launcher-58092.json',
        'sessions/one.json',
        'media/image.png',
        'bin/sanad',
        'attachments/file.pdf',
        'memories/.env.backup',
        'skills/vault.json',
        'skills/keyring.dat',
        'workspaces/private.pem',
      ]) {
        expect(
          isFixtureCapturedPath(path),
          isFalse,
          reason: '$path must never be captured by a fixture',
        );
      }
    });

    test('lists only the captured Home paths', () {
      final paths = listFixtureSourcePaths(home.path);

      expect(
        paths,
        containsAll(['config.yaml', 'state.db', 'memories/notes.md']),
      );
      expect(
        paths.any((path) => path.startsWith('.env') || path.contains('token')),
        isFalse,
      );
      expect(paths, isNot(contains('logs/agent.log')));
      expect(paths, isNot(contains('dev/runtime-launcher-58092.json')));
      expect(paths, isNot(contains('memories/.env.backup')));
    });

    test('rejects unsafe fixture names', () {
      for (final name in const [
        '',
        '../escape',
        'UPPER',
        'with space',
        'a/b',
      ]) {
        expect(isValidSanadDevFixtureName(name), isFalse, reason: name);
      }
      expect(isValidSanadDevFixtureName('clean-1.0'), isTrue);
    });
  });

  group('fixture save and restore', () {
    test('saves a manifest with hashes and excludes every secret', () async {
      final manifest = await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      final paths = manifest.entries
          .map((entry) => entry.relativePath)
          .toList();
      expect(paths, contains('state.db'));
      expect(paths, contains('config.yaml'));
      expect(paths, isNot(contains('.env')));
      expect(paths, isNot(contains('.local_token')));
      expect(paths, isNot(contains('provider_secrets.json')));
      final stateDb = manifest.entries.firstWhere(
        (entry) => entry.relativePath == 'state.db',
      );
      expect(stateDb.size, 'database-v1'.length);
      expect(
        stateDb.sha256,
        sha256.convert(utf8.encode('database-v1')).toString(),
      );
      expect(
        File(
          p.join(sanadDevFixturePath(workspace.path, 'clean'), 'state.db'),
        ).readAsStringSync(),
        'database-v1',
      );
      expect(
        Directory(sanadDevFixturePath(workspace.path, 'clean'))
            .listSync(recursive: true)
            .whereType<File>()
            .any((file) => file.path.endsWith('.env')),
        isFalse,
      );
    });

    test('restores the fixture and removes stale captured files', () async {
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      await writeHomeFile('state.db', 'database-v2');
      await writeHomeFile('memories/stale.md', '# stale');
      await writeHomeFile('.local_token', 'rotated-credential');

      final report = await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      expect(report.restoredFiles, greaterThan(0));
      expect(
        File(p.join(home.path, 'state.db')).readAsStringSync(),
        'database-v1',
      );
      expect(
        File(p.join(home.path, 'memories', 'stale.md')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(home.path, 'memories', 'notes.md')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(home.path, '.local_token')).readAsStringSync(),
        'rotated-credential',
        reason: 'restoring a fixture must never touch the gateway credential',
      );
      expect(File(p.join(home.path, '.env')).existsSync(), isTrue);
      expect(File(p.join(home.path, 'logs', 'agent.log')).existsSync(), isTrue);
      expect(
        File(
          p.join(home.path, 'dev', 'runtime-launcher-58092.json'),
        ).existsSync(),
        isTrue,
        reason: 'runtime leases must survive a fixture restore',
      );
      expect(
        Directory(p.join(home.path, '.sanad-dev-reset-staging')).existsSync(),
        isFalse,
        reason: 'the staging directory is always cleaned up',
      );
    });

    test('fails closed for an unknown, corrupt, or partial fixture', () async {
      await expectLater(
        restoreHomeFixture(
          workspaceRoot: workspace.path,
          homePath: home.path,
          name: 'missing',
        ),
        throwsA(isA<StateError>()),
      );

      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      await File(
        p.join(sanadDevFixturePath(workspace.path, 'clean'), 'state.db'),
      ).writeAsString('tampered');

      await expectLater(
        restoreHomeFixture(
          workspaceRoot: workspace.path,
          homePath: home.path,
          name: 'clean',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('corrupt'),
          ),
        ),
      );

      final manifestFile = File(
        p.join(sanadDevFixturePath(workspace.path, 'clean'), 'fixture.json'),
      );
      final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map;
      manifest['schema_version'] = 99;
      await manifestFile.writeAsString(jsonEncode(manifest));
      await expectLater(
        readHomeFixtureManifest(workspaceRoot: workspace.path, name: 'clean'),
        throwsA(isA<FormatException>()),
      );
    });

    test('replaces an existing fixture of the same name', () async {
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      await writeHomeFile('state.db', 'database-v2');
      final manifest = await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      expect(
        manifest.entries
            .firstWhere((entry) => entry.relativePath == 'state.db')
            .sha256,
        sha256.convert(utf8.encode('database-v2')).toString(),
      );
      expect(
        Directory(
          '${sanadDevFixturePath(workspace.path, 'clean')}.building',
        ).existsSync(),
        isFalse,
      );
    });

    test('refuses an unknown Home and an unsafe fixture name', () async {
      await expectLater(
        saveHomeFixture(
          workspaceRoot: workspace.path,
          homePath: p.join(fixture.path, 'absent'),
          name: 'clean',
        ),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        saveHomeFixture(
          workspaceRoot: workspace.path,
          homePath: home.path,
          name: '../escape',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
