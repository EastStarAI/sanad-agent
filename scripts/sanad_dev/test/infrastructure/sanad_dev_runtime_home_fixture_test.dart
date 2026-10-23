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
  late Directory outside;

  Future<void> writeHomeFile(String relative, String contents) async {
    final file = File(p.join(home.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  /// Rewrites the saved manifest with extra entries that point where they must
  /// never point, so the restore is exercised against a malicious fixture.
  Future<void> corruptManifest(
    String name,
    List<Map<String, Object>> entries,
  ) async {
    final path = p.join(sanadDevFixturePath(workspace.path, name), 'fixture.json');
    final decoded =
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    decoded['entries'] = [
      ...(decoded['entries'] as List),
      ...entries,
    ];
    File(path).writeAsStringSync(jsonEncode(decoded));
  }

  Map<String, Object> entryFor(String relativePath) => {
    'path': relativePath,
    'size': 5,
    'sha256': sha256.convert(utf8.encode('pwned')).toString(),
  };

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-home-fixture-');
    workspace = Directory(p.join(fixture.path, 'worktree'))
      ..createSync(recursive: true);
    home = Directory(p.join(fixture.path, 'home'))..createSync(recursive: true);
    outside = Directory(p.join(fixture.path, 'outside'))
      ..createSync(recursive: true);
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
      expect(isFixtureCapturedPath('memories/notes.md'), isTrue);
      expect(isFixtureCapturedPath('skills/custom/SKILL.md'), isTrue);
      expect(isFixtureCapturedPath('workspaces/registry.json'), isTrue);
    });

    test('mcp_config.json is opt-in only', () {
      expect(isFixtureCapturedPath('mcp_config.json'), isFalse);
      expect(
        isFixtureCapturedPath('mcp_config.json', includeMcpConfig: true),
        isTrue,
      );
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
        'workspaces/id_ed25519',
        'workspaces/deploy.key',
        'workspaces/cert.p12',
        'memories/.netrc',
        'workspaces/one/logs/agent.log',
        'workspaces/one/request_dumps/call.json',
        'skills/one/logs/trace.log',
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
      expect(paths, isNot(contains('mcp_config.json')));
    });

    test('rejects unsafe fixture names', () {
      for (final name in const ['', '../escape', 'UPPER', 'with space', 'a/b']) {
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
      expect(paths, isNot(contains('mcp_config.json')));
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

    test('an opt-in fixture captures mcp_config.json and records it', () async {
      await writeHomeFile('mcp_config.json', '{"mcp":{}}');

      final manifest = await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'with-mcp',
        includeMcpConfig: true,
      );

      expect(manifest.includeMcpConfig, isTrue);
      expect(
        manifest.entries.map((entry) => entry.relativePath),
        contains('mcp_config.json'),
      );
      final decoded =
          jsonDecode(
                File(
                  p.join(
                    sanadDevFixturePath(workspace.path, 'with-mcp'),
                    'fixture.json',
                  ),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(decoded['include_mcp_config'], isTrue);
    });

    test('fixture files and directories are owner-only', () async {
      if (Platform.isWindows) return;
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      final root = sanadDevFixturePath(workspace.path, 'clean');
      final directoryMode = (await Process.run('stat', [
        '-f',
        '%Lp',
        root,
      ])).stdout.toString().trim();
      final fileMode = (await Process.run('stat', [
        '-f',
        '%Lp',
        p.join(root, 'state.db'),
      ])).stdout.toString().trim();

      expect(directoryMode, '700');
      expect(fileMode, '600');

      // Every level the capture created is owner-only, not just the root: a
      // nested `memories/` or `skills/custom/` directory left at the process
      // default would make a shared fixture tree world-traversable.
      final directories = Directory(
        root,
      ).listSync(recursive: true).whereType<Directory>();
      for (final directory in directories) {
        expect(
          (await Process.run('stat', [
            '-f',
            '%Lp',
            directory.path,
          ])).stdout.toString().trim(),
          '700',
          reason: '${p.relative(directory.path, from: root)} must be owner-only',
        );
      }
      final files = Directory(
        root,
      ).listSync(recursive: true).whereType<File>();
      for (final file in files) {
        expect(
          (await Process.run('stat', [
            '-f',
            '%Lp',
            file.path,
          ])).stdout.toString().trim(),
          '600',
          reason: '${p.relative(file.path, from: root)} must be owner-only',
        );
      }
    });

    test('a restore creates owner-only directories in the Home', () async {
      if (Platform.isWindows) return;
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      // Remove the nested directories so the restore has to create them.
      for (final relative in const ['memories', 'skills']) {
        Directory(p.join(home.path, relative)).deleteSync(recursive: true);
      }

      await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      for (final relative in const ['memories', 'skills', 'skills/custom']) {
        final directory = p.join(home.path, relative);
        expect(
          Directory(directory).existsSync(),
          isTrue,
          reason: '$relative must be restored',
        );
        expect(
          (await Process.run('stat', [
            '-f',
            '%Lp',
            directory,
          ])).stdout.toString().trim(),
          '700',
          reason: 'a restore must never widen a Home directory to the default',
        );
      }
      expect(
        (await Process.run('stat', [
          '-f',
          '%Lp',
          p.join(home.path, 'memories', 'notes.md'),
        ])).stdout.toString().trim(),
        '600',
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
      expect(report.removedFiles, 1, reason: 'memories/stale.md is stale');
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
        Directory(sanadDevFixtureStagingPath(home.path)).existsSync(),
        isFalse,
        reason: 'the staging directory is always cleaned up',
      );
    });

    test('the database family swaps as one unit', () async {
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      // A stale sidecar from a later session must not survive beside the
      // restored database.
      await writeHomeFile('state.db', 'database-v2');
      await writeHomeFile('state.db-wal', 'stale-wal');
      await writeHomeFile('state.db-shm', 'stale-shm');

      await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      expect(
        File(p.join(home.path, 'state.db')).readAsStringSync(),
        'database-v1',
      );
      expect(File(p.join(home.path, 'state.db-wal')).existsSync(), isFalse);
      expect(File(p.join(home.path, 'state.db-shm')).existsSync(), isFalse);
    });

    test('restores a fixture that carries the database sidecars', () async {
      await writeHomeFile('state.db-wal', 'wal-v1');
      await writeHomeFile('state.db-shm', 'shm-v1');
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      File(p.join(home.path, 'state.db-wal')).deleteSync();
      File(p.join(home.path, 'state.db-shm')).deleteSync();

      await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      expect(
        File(p.join(home.path, 'state.db-wal')).readAsStringSync(),
        'wal-v1',
      );
      expect(
        File(p.join(home.path, 'state.db-shm')).readAsStringSync(),
        'shm-v1',
      );
    });

    test('recovers displaced files from an interrupted restore', () async {
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      // Simulate a crash after the original files were displaced.
      final staging = Directory(sanadDevFixtureStagingPath(home.path));
      final backup = Directory(p.join(staging.path, 'backup'));
      backup.createSync(recursive: true);
      File(p.join(home.path, 'state.db')).renameSync(
        p.join(backup.path, 'state.db'),
      );
      expect(File(p.join(home.path, 'state.db')).existsSync(), isFalse);

      await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );

      expect(
        File(p.join(home.path, 'state.db')).readAsStringSync(),
        'database-v1',
      );
      expect(staging.existsSync(), isFalse);
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

  group('malicious fixture refusal', () {
    /// A malicious fixture must fail closed and leave the Home and every
    /// sibling path byte-identical.
    Future<void> expectRefused({required String reason}) async {
      final outsideFile = File(p.join(outside.path, 'stolen.txt'));
      final beforeHome = listFixtureSourcePaths(home.path);
      final beforeToken = File(
        p.join(home.path, '.local_token'),
      ).readAsStringSync();

      await expectLater(
        restoreHomeFixture(
          workspaceRoot: workspace.path,
          homePath: home.path,
          name: 'evil',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains(reason),
          ),
        ),
      );

      expect(
        listFixtureSourcePaths(home.path),
        beforeHome,
        reason: 'a refused restore must not add or remove a captured file',
      );
      expect(
        File(p.join(home.path, '.local_token')).readAsStringSync(),
        beforeToken,
      );
      expect(
        outsideFile.existsSync(),
        isFalse,
        reason: 'nothing may be written outside the Home',
      );
      expect(
        Directory(sanadDevFixtureStagingPath(home.path)).existsSync(),
        isFalse,
      );
    }

    setUp(() async {
      await saveHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      // Mirror the captured files so every legitimate entry validates; only the
      // appended malicious entries are left to refuse.
      final cleanRoot = Directory(sanadDevFixturePath(workspace.path, 'clean'));
      final evilRoot = Directory(sanadDevFixturePath(workspace.path, 'evil'))
        ..createSync(recursive: true);
      for (final entity in cleanRoot.listSync(recursive: true)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: cleanRoot.path);
        final target = File(p.join(evilRoot.path, relative));
        target.parent.createSync(recursive: true);
        entity.copySync(target.path);
      }
    });

    test('refuses a relative traversal out of the Home', () async {
      await corruptManifest('evil', [
        entryFor('../../outside/stolen.txt'),
        entryFor('memories/../../outside/stolen.txt'),
      ]);

      await expectRefused(reason: 'contains an empty, "." or ".." segment');
    });

    test('refuses an absolute path', () async {
      await corruptManifest('evil', [
        entryFor(p.join(outside.path, 'stolen.txt')),
        entryFor('/etc/passwd'),
      ]);

      await expectRefused(reason: 'is an absolute path');
    });

    test('refuses a symlinked parent that escapes the Home', () async {
      // `skills` is a captured directory; pointing it at another tree must not
      // let the restore write through it.
      final skills = Directory(p.join(home.path, 'skills'))
        ..createSync(recursive: true);
      final linked = File(p.join(skills.path, 'custom', 'SKILL.md'));
      linked.parent.createSync(recursive: true);
      linked.writeAsStringSync('# skill');
      await Directory(
        p.join(sanadDevFixturePath(workspace.path, 'evil'), 'skills', 'custom'),
      ).create(recursive: true);
      File(
        p.join(
          sanadDevFixturePath(workspace.path, 'evil'),
          'skills',
          'custom',
          'SKILL.md',
        ),
      ).writeAsStringSync('pwned');
      final realSkills = Directory(p.join(outside.path, 'skills'))
        ..createSync(recursive: true);
      Directory(p.join(home.path, 'skills')).deleteSync(recursive: true);
      Link(p.join(home.path, 'skills')).createSync(realSkills.path);
      addTearDown(() {
        final link = Link(p.join(home.path, 'skills'));
        if (link.existsSync()) link.deleteSync();
      });

      await corruptManifest('evil', [
        {
          'path': 'skills/custom/SKILL.md',
          'size': 5,
          'sha256': sha256.convert(utf8.encode('pwned')).toString(),
        },
      ]);

      await expectLater(
        restoreHomeFixture(
          workspaceRoot: workspace.path,
          homePath: home.path,
          name: 'evil',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('symbolic link'),
          ),
        ),
      );
      expect(
        File(p.join(realSkills.path, 'custom', 'SKILL.md')).existsSync(),
        isFalse,
        reason: 'nothing may be written through a symlinked parent',
      );
    });

    test('refuses a denylisted entry such as the gateway credential', () async {
      await corruptManifest('evil', [
        entryFor('.local_token'),
        entryFor('.env'),
        entryFor('logs/agent.log'),
        entryFor('workspaces/private.pem'),
      ]);

      await expectRefused(reason: 'is not a captured fixture path');
    });
  });
}
