import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

void main() {
  group('LocalWorkspaceRuntimeService.browseWorkspaceTree', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late LocalWorkspaceRuntimeService service;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'sanad-agent-workspace-runtime-test',
      );
      workspaceDir = Directory('${tempDir.path}/workspace')..createSync();
      Directory('${workspaceDir.path}/nested').createSync();
      service = LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: workspaceDir.path,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('returns system roots when path is empty', () async {
      final snapshot = await service.browseWorkspaceTree();

      if (Platform.isWindows) {
        expect(snapshot['path'], isEmpty);
        expect(snapshot['root_path'], isEmpty);
      } else {
        expect(snapshot['path'], Platform.pathSeparator);
        expect(snapshot['root_path'], Platform.pathSeparator);
      }
      expect(snapshot['parent_path'], isNull);
      expect(snapshot['entries'], isNotEmpty);
    });

    test('allows browsing outside the daemon working directory', () async {
      final snapshot = await service.browseWorkspaceTree(path: tempDir.path);
      final normalizedTempDir = Directory(
        tempDir.path,
      ).resolveSymbolicLinksSync();

      expect(snapshot['path'], normalizedTempDir);
      final entries = snapshot['entries'] as List<dynamic>;
      expect(
        entries.any(
          (entry) =>
              entry['path'] ==
              Directory(workspaceDir.path).resolveSymbolicLinksSync(),
        ),
        isTrue,
      );
    });

    test('returns parent path for arbitrary directory navigation', () async {
      final snapshot = await service.browseWorkspaceTree(
        path: '${workspaceDir.path}/nested',
      );

      expect(
        snapshot['parent_path'],
        Directory(workspaceDir.path).resolveSymbolicLinksSync(),
      );
    });

    test('creates a workspace from path when name is omitted', () async {
      final selectedPath = '${tempDir.path}/picked-workspace';

      final workspace = await service.createWorkspace(path: selectedPath);

      expect(
        workspace['path'],
        Directory(selectedPath).resolveSymbolicLinksSync(),
      );
      expect(workspace['name'], 'picked-workspace');
    });

    group('folder mutations', () {
      test('creates one direct child and rejects traversal names', () async {
        final createdPath = await service.createFolder(
          parentPath: workspaceDir.path,
          name: 'created',
        );

        expect(Directory(createdPath).existsSync(), isTrue);
        for (final invalidName in [
          '',
          '.',
          '..',
          '../outside',
          r'nested/name',
          r'nested\name',
        ]) {
          await expectLater(
            service.createFolder(
              parentPath: workspaceDir.path,
              name: invalidName,
            ),
            throwsA(isA<FormatException>()),
          );
        }
        expect(Directory('${tempDir.path}/outside').existsSync(), isFalse);
      });

      test(
        'does not treat an existing file or folder as create success',
        () async {
          await File('${workspaceDir.path}/taken').writeAsString('content');

          await expectLater(
            service.createFolder(parentPath: workspaceDir.path, name: 'taken'),
            throwsA(isA<StateError>()),
          );
          await expectLater(
            service.createFolder(parentPath: workspaceDir.path, name: 'nested'),
            throwsA(isA<StateError>()),
          );
        },
      );

      test('renames a directory without crossing its parent', () async {
        final source = Directory('${workspaceDir.path}/source')..createSync();

        final renamedPath = await service.renameFolder(
          path: source.path,
          newName: 'renamed',
        );

        expect(source.existsSync(), isFalse);
        expect(Directory(renamedPath).existsSync(), isTrue);
        await expectLater(
          service.renameFolder(path: renamedPath, newName: '../escaped'),
          throwsA(isA<FormatException>()),
        );
      });

      test('rejects rename collisions', () async {
        final source = Directory('${workspaceDir.path}/source')..createSync();
        Directory('${workspaceDir.path}/target').createSync();

        await expectLater(
          service.renameFolder(path: source.path, newName: 'target'),
          throwsA(isA<StateError>()),
        );
        expect(source.existsSync(), isTrue);
      });

      test('deletes a directory recursively', () async {
        final target = Directory('${workspaceDir.path}/delete-me/nested')
          ..createSync(recursive: true);
        await File('${target.path}/file.txt').writeAsString('content');

        final expectedPath = target.parent.resolveSymbolicLinksSync();
        final deletedPath = await service.deleteFolder(target.parent.path);

        expect(deletedPath, expectedPath);
        expect(target.parent.existsSync(), isFalse);
      });

      test('rejects files and filesystem roots as mutable folders', () async {
        final file = await File(
          '${workspaceDir.path}/file.txt',
        ).writeAsString('content');

        await expectLater(
          service.deleteFolder(file.path),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          service.deleteFolder(_fileSystemRoot(tempDir.path)),
          throwsA(isA<StateError>()),
        );
      });

      test('rejects symbolic-link folder mutation', () async {
        if (Platform.isWindows) return;
        final target = Directory('${workspaceDir.path}/target')..createSync();
        final link = Link('${workspaceDir.path}/target-link');
        await link.create(target.path);

        await expectLater(
          service.deleteFolder(link.path),
          throwsA(isA<StateError>()),
        );
        expect(target.existsSync(), isTrue);
      });
    });
  });

  group('LocalWorkspaceRuntimeService managed remote', () {
    late Directory tempDir;
    late LocalWorkspaceRuntimeService service;
    late String managedRoot;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'sanad-agent-managed-workspace-test',
      );
      await SanadHomeBootstrap.atRoot(
        tempDir.path,
        scope: SanadHomeScope.identity,
      ).prepare();
      service = LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
      );
      managedRoot = Directory(
        '${tempDir.path}/${SanadHomeBootstrap.managedWorkspacesDirectoryName}',
      ).resolveSymbolicLinksSync();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('creates a name-based workspace under the managed root', () async {
      final workspace = await service.createWorkspace(
        name: 'notes',
        description: 'Remote notes',
        managedRemote: true,
      );

      expect(workspace['name'], 'Remote notes');
      expect(
        workspace['path'],
        Directory('$managedRoot/notes').resolveSymbolicLinksSync(),
      );
      expect(Directory('$managedRoot/notes').existsSync(), isTrue);
    });

    test('rejects a client-supplied absolute path on managed create', () async {
      final outside = Directory('${tempDir.path}/outside')..createSync();
      await expectLater(
        service.createWorkspace(
          name: 'notes',
          path: outside.path,
          managedRemote: true,
        ),
        throwsA(
          isA<WorkspaceCommandException>().having(
            (error) => error.code,
            'code',
            WorkspaceCommandErrorCodes.invalidRequest,
          ),
        ),
      );
      expect(Directory('$managedRoot/notes').existsSync(), isFalse);
    });

    test(
      'empty managed browse lists allowed roots, not filesystem root',
      () async {
        await service.createWorkspace(name: 'notes', managedRemote: true);
        final snapshot = await service.browseWorkspaceTree(managedRemote: true);
        final entries = snapshot['entries'] as List<dynamic>;
        final paths = entries.map((entry) => entry['path']).toSet();

        expect(snapshot['path'], isEmpty);
        expect(snapshot['parent_path'], isNull);
        expect(paths, contains(managedRoot));
        expect(paths, isNot(contains(Platform.pathSeparator)));
        expect(paths, isNot(contains(tempDir.resolveSymbolicLinksSync())));
      },
    );

    test('rejects browsing Sanad Home internals', () async {
      File('${tempDir.path}/auth.json').writeAsStringSync('secret');
      await expectLater(
        service.browseWorkspaceTree(path: tempDir.path, managedRemote: true),
        throwsA(
          isA<WorkspaceCommandException>().having(
            (error) => error.code,
            'code',
            WorkspaceCommandErrorCodes.pathNotAllowed,
          ),
        ),
      );
    });

    test('rejects traversal and filesystem root browsing', () async {
      await expectLater(
        service.browseWorkspaceTree(
          path: Platform.pathSeparator,
          managedRemote: true,
        ),
        throwsA(isA<WorkspaceCommandException>()),
      );
      await expectLater(
        service.browseWorkspaceTree(
          path: '$managedRoot/../${p.basename(tempDir.path)}',
          managedRemote: true,
        ),
        throwsA(isA<WorkspaceCommandException>()),
      );
    });

    test('does not treat a host path as a remote workspace id', () async {
      final outside = await Directory.systemTemp.createTemp(
        'sanad-unregistered-workspace-test',
      );
      addTearDown(() async {
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      await File('${outside.path}/secret.txt').writeAsString('private');

      await expectLater(
        service.browseWorkspaceTree(
          workspaceId: outside.path,
          managedRemote: true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await service.listWorkspaces(), isEmpty);
    });

    test(
      'creates, renames, and deletes a folder inside the managed root',
      () async {
        final workspace = await service.createWorkspace(
          name: 'notes',
          managedRemote: true,
        );
        final workspacePath = workspace['path'] as String;
        final created = await service.createFolder(
          parentPath: workspacePath,
          name: 'drafts',
          managedRemote: true,
        );
        expect(Directory(created).existsSync(), isTrue);

        final renamed = await service.renameFolder(
          path: created,
          newName: 'archive',
          managedRemote: true,
        );
        expect(Directory(created).existsSync(), isFalse);
        expect(Directory(renamed).existsSync(), isTrue);

        final preview = await service.previewDeleteFolder(
          renamed,
          managedRemote: true,
        );
        final deleted = await service.deleteFolder(
          renamed,
          managedRemote: true,
          expectedFingerprint: preview.fingerprint,
        );
        expect(deleted, renamed);
        expect(Directory(renamed).existsSync(), isFalse);
      },
    );

    test('rejects deleting the managed root or a workspace root', () async {
      final workspace = await service.createWorkspace(
        name: 'notes',
        managedRemote: true,
      );
      await expectLater(
        service.deleteFolder(managedRoot, managedRemote: true),
        throwsA(isA<WorkspaceCommandException>()),
      );
      await expectLater(
        service.deleteFolder(workspace['path'] as String, managedRemote: true),
        throwsA(isA<WorkspaceCommandException>()),
      );
    });

    test('rejects a symlink folder as a managed mutation target', () async {
      if (Platform.isWindows) return;
      final workspace = await service.createWorkspace(
        name: 'notes',
        managedRemote: true,
      );
      final workspacePath = workspace['path'] as String;
      final target = Directory('$workspacePath/real')..createSync();
      final link = Link('$workspacePath/alias');
      await link.create(target.path);

      await expectLater(
        service.deleteFolder(link.path, managedRemote: true),
        throwsA(isA<WorkspaceCommandException>()),
      );
      expect(target.existsSync(), isTrue);
    });

    test(
      'fail-injection replaces a folder with a symlink after preview',
      () async {
        if (Platform.isWindows) return;
        final workspace = await service.createWorkspace(
          name: 'notes',
          managedRemote: true,
        );
        final workspacePath = workspace['path'] as String;
        final folder = await service.createFolder(
          parentPath: workspacePath,
          name: 'drafts',
          managedRemote: true,
        );
        File('$folder/keep.txt').writeAsStringSync('keep');
        final preview = await service.previewDeleteFolder(
          folder,
          managedRemote: true,
        );
        final outside = Directory('${tempDir.path}/outside-secret')
          ..createSync();
        File('${outside.path}/secret.txt').writeAsStringSync('untouched');
        await Directory(folder).delete(recursive: true);
        await Link(folder).create(outside.path);

        await expectLater(
          service.deleteFolder(
            folder,
            managedRemote: true,
            expectedFingerprint: preview.fingerprint,
          ),
          throwsA(isA<WorkspaceCommandException>()),
        );
        expect(outside.existsSync(), isTrue);
        expect(
          File('${outside.path}/secret.txt').readAsStringSync(),
          'untouched',
        );
      },
    );

    test('rejects a stale delete fingerprint after a race', () async {
      final workspace = await service.createWorkspace(
        name: 'notes',
        managedRemote: true,
      );
      final folder = await service.createFolder(
        parentPath: workspace['path'] as String,
        name: 'drafts',
        managedRemote: true,
      );
      final preview = await service.previewDeleteFolder(
        folder,
        managedRemote: true,
      );
      File('$folder/new.txt').writeAsStringSync('changed');

      await expectLater(
        service.deleteFolder(
          folder,
          managedRemote: true,
          expectedFingerprint: preview.fingerprint,
        ),
        throwsA(
          isA<WorkspaceCommandException>().having(
            (error) => error.code,
            'code',
            WorkspaceCommandErrorCodes.staleConfirmation,
          ),
        ),
      );
      expect(Directory(folder).existsSync(), isTrue);
    });

    test('lost-success recovery does not repeat a completed delete', () async {
      final workspace = await service.createWorkspace(
        name: 'notes',
        managedRemote: true,
      );
      final folder = await service.createFolder(
        parentPath: workspace['path'] as String,
        name: 'drafts',
        managedRemote: true,
      );
      final preview = await service.previewDeleteFolder(
        folder,
        managedRemote: true,
      );
      await service.deleteFolder(
        folder,
        managedRemote: true,
        expectedFingerprint: preview.fingerprint,
      );

      await expectLater(
        service.deleteFolder(
          folder,
          managedRemote: true,
          expectedFingerprint: preview.fingerprint,
        ),
        throwsA(anything),
      );
      expect(Directory(folder).existsSync(), isFalse);
    });

    test('serializes concurrent managed folder mutations', () async {
      final workspace = await service.createWorkspace(
        name: 'notes',
        managedRemote: true,
      );
      final workspacePath = workspace['path'] as String;
      final first = service.createFolder(
        parentPath: workspacePath,
        name: 'a',
        managedRemote: true,
      );
      final second = service.createFolder(
        parentPath: workspacePath,
        name: 'b',
        managedRemote: true,
      );
      await Future.wait([first, second]);
      expect(Directory('$workspacePath/a').existsSync(), isTrue);
      expect(Directory('$workspacePath/b').existsSync(), isTrue);
    });
  });

  test(
    'keeps stable identity while renaming and changing a missing path',
    () async {
      final stateHome = await Directory.systemTemp.createTemp(
        'sanad-workspace-identity-test',
      );
      final state = AgentStateDatabase.atPath(stateHome.path);
      final db = SessionDB.fromState(state);
      try {
        final service = LocalWorkspaceRuntimeService(
          sanadHomePath: stateHome.path,
          currentWorkingDirectory: stateHome.path,
          sessionDb: db,
        );
        final original = Directory('${stateHome.path}/original')..createSync();
        final created = await service.createWorkspace(
          path: original.path,
          name: 'Original name',
        );
        final workspaceId = created['id'] as String;
        expect(workspaceId, isNot(original.path));

        final renamed = await service.renameWorkspace(
          workspaceId: workspaceId,
          displayName: 'Renamed workspace',
        );
        expect(renamed['id'], workspaceId);
        expect(renamed['name'], 'Renamed workspace');

        original.deleteSync(recursive: true);
        final missing = (await service.listWorkspaces()).single;
        expect(missing['id'], workspaceId);
        expect(missing['availability'], 'missing');

        final replacement = Directory('${stateHome.path}/replacement')
          ..createSync();
        final relocated = await service.relocateWorkspace(
          workspaceId: workspaceId,
          newPath: replacement.path,
        );
        expect(relocated['id'], workspaceId);
        expect(relocated['path'], replacement.resolveSymbolicLinksSync());
        expect(relocated['availability'], 'available');
      } finally {
        state.dispose();
        if (stateHome.existsSync()) await stateHome.delete(recursive: true);
      }
    },
  );

  test(
    'removes only workspace metadata and preserves files and sessions',
    () async {
      final stateHome = await Directory.systemTemp.createTemp(
        'sanad-workspace-remove-test',
      );
      final state = AgentStateDatabase.atPath(stateHome.path);
      final db = SessionDB.fromState(state);
      try {
        final service = LocalWorkspaceRuntimeService(
          sanadHomePath: stateHome.path,
          currentWorkingDirectory: stateHome.path,
          sessionDb: db,
        );
        final directory = Directory('${stateHome.path}/kept-workspace')
          ..createSync();
        final marker = File('${directory.path}/keep.txt')
          ..writeAsStringSync('keep');
        final created = await service.createWorkspace(path: directory.path);
        final workspaceId = created['id'] as String;
        db.saveSession(
          SessionState(
            sessionId: 'kept-session',
            model: 'test-model',
            title: 'Kept conversation',
            workspaceId: workspaceId,
            createdAt: DateTime.utc(2026, 8, 30),
            updatedAt: DateTime.utc(2026, 8, 30),
          ),
        );

        expect(
          await service.removeWorkspace(workspaceId: workspaceId),
          workspaceId,
        );

        expect(await service.listWorkspaces(), isEmpty);
        expect(directory.existsSync(), isTrue);
        expect(marker.readAsStringSync(), 'keep');
        expect(db.getSession('kept-session')?.workspaceId, workspaceId);
      } finally {
        state.dispose();
        if (stateHome.existsSync()) await stateHome.delete(recursive: true);
      }
    },
  );
}

String _fileSystemRoot(String path) {
  var current = Directory(path).absolute;
  while (current.parent.path != current.path) {
    current = current.parent;
  }
  return current.path;
}
