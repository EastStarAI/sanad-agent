// Task 123: managed-remote (cloud) workspace access is confined to the
// runtime Home's managed workspaces root, `<SANAD_HOME>/workspaces`.
//
// Each rejection case from the task's security table (S1-S20) has its own
// test. Paths are always derived from the test Home; no test assumes a
// `.sanad` directory name.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

Matcher _coded(String code) => throwsA(
  isA<WorkspaceCommandException>().having((error) => error.code, 'code', code),
);

final Matcher _pathNotAllowed = _coded(
  WorkspaceCommandErrorCodes.pathNotAllowed,
);
final Matcher _workspaceInUse = _coded(
  WorkspaceCommandErrorCodes.workspaceInUse,
);
final Matcher _invalidRequest = _coded(
  WorkspaceCommandErrorCodes.invalidRequest,
);

/// One managed request type that takes a path, invoked with [path].
typedef _PathRequest = Future<Object?> Function(String path);

void main() {
  late Directory tempDir;
  late String home;
  late String stateHome;
  late LocalWorkspaceRuntimeService service;
  late String root;
  late String workspaceId;
  late String workspacePath;

  Future<LocalWorkspaceRuntimeService> buildService(String homePath) async {
    await SanadHomeBootstrap.atRoot(
      homePath,
      scope: SanadHomeScope.identity,
    ).prepare();
    return LocalWorkspaceRuntimeService(
      sanadHomePath: homePath,
      currentWorkingDirectory: homePath,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sanad-managed-confine');
    // A Test-Home-shaped name, deliberately not the default Home name.
    home = p.join(tempDir.path, '.sanad-test-2');
    stateHome = p.join(tempDir.path, 'state');
    Directory(stateHome).createSync();
    setSanadHomeOverride(home);
    setSanadStateHomeOverride(stateHome);
    service = await buildService(home);
    root = Directory(
      p.join(home, SanadHomeBootstrap.managedWorkspacesDirectoryName),
    ).resolveSymbolicLinksSync();
    final created = await service.createWorkspace(
      name: 'notes',
      managedRemote: true,
    );
    workspaceId = created['id'] as String;
    workspacePath = created['path'] as String;
    Directory(p.join(root, 'plain')).createSync();
  });

  tearDown(() async {
    await service.dispose();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    try {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Map<String, _PathRequest> pathRequests() => {
    'browse_workspace_tree': (path) =>
        service.browseWorkspaceTree(path: path, managedRemote: true),
    'create_folder parent_path': (path) => service.createFolder(
      parentPath: path,
      name: 'child',
      managedRemote: true,
    ),
    'rename_folder path': (path) => service.renameFolder(
      path: path,
      newName: 'renamed',
      managedRemote: true,
    ),
    'delete_folder preview path': (path) =>
        service.previewDeleteFolder(path, managedRemote: true),
    'delete_folder path': (path) =>
        service.deleteFolder(path, managedRemote: true),
    'create_workspace path': (path) =>
        service.createWorkspace(path: path, managedRemote: true),
    'relocate new_path': (path) => service.relocateWorkspace(
      workspaceId: workspaceId,
      newPath: path,
      managedRemote: true,
    ),
  };

  const destructive = {
    'create_folder parent_path',
    'rename_folder path',
    'delete_folder preview path',
    'delete_folder path',
  };

  /// Runs [path] against every path-taking request and expects [matcher].
  ///
  /// Real host paths (the user's home, the system temp root, `/`) pass
  /// [hostPath] so they never reach a mutating request, even under a bug.
  Future<void> expectEveryRequest(
    String path,
    Matcher matcher, {
    bool hostPath = false,
  }) async {
    for (final entry in pathRequests().entries) {
      if (hostPath && destructive.contains(entry.key)) continue;
      await expectLater(entry.value(path), matcher, reason: entry.key);
    }
  }

  group('managed root follows the runtime Home', () {
    test('empty browse opens the custom Home workspaces root', () async {
      final snapshot = await service.browseWorkspaceTree(managedRemote: true);
      expect(snapshot['root_path'], root);
      expect(snapshot['path'], root);
      expect(snapshot['parent_path'], isNull);
      expect(p.basename(p.dirname(root)), '.sanad-test-2');
      final names = (snapshot['entries'] as List)
          .map((entry) => (entry as Map)['name'])
          .toSet();
      expect(names, containsAll(['notes', 'plain']));
    });

    test('a service without an explicit Home uses the runtime Home', () async {
      final runtimeHome = p.join(tempDir.path, 'other-home');
      setSanadHomeOverride(runtimeHome);
      await SanadHomeBootstrap.atRoot(
        runtimeHome,
        scope: SanadHomeScope.identity,
      ).prepare();
      final implicit = LocalWorkspaceRuntimeService(
        currentWorkingDirectory: runtimeHome,
      );
      addTearDown(implicit.dispose);
      final expected = Directory(
        p.join(runtimeHome, SanadHomeBootstrap.managedWorkspacesDirectoryName),
      ).resolveSymbolicLinksSync();
      final snapshot = await implicit.browseWorkspaceTree(managedRemote: true);
      expect(snapshot['root_path'], expected);
      expect(snapshot['path'], expected);
    });
  });

  group('positive managed navigation', () {
    test('nested browse steps parent_path back to the root', () async {
      final a = await service.createFolder(
        parentPath: root,
        name: 'a',
        managedRemote: true,
      );
      final b = await service.createFolder(
        parentPath: a,
        name: 'b',
        managedRemote: true,
      );
      final c = await service.createFolder(
        parentPath: b,
        name: 'c',
        managedRemote: true,
      );

      final atC = await service.browseWorkspaceTree(
        path: c,
        managedRemote: true,
      );
      expect(atC['root_path'], root);
      expect(atC['parent_path'], b);
      final atB = await service.browseWorkspaceTree(
        path: atC['parent_path'] as String,
        managedRemote: true,
      );
      expect(atB['parent_path'], a);
      final atA = await service.browseWorkspaceTree(
        path: atB['parent_path'] as String,
        managedRemote: true,
      );
      expect(atA['parent_path'], root);
      final atRoot = await service.browseWorkspaceTree(
        path: atA['parent_path'] as String,
        managedRemote: true,
      );
      expect(atRoot['parent_path'], isNull);
    });

    test('picks a nested folder as a workspace, idempotently', () async {
      final parent = await service.createFolder(
        parentPath: root,
        name: 'parent',
        managedRemote: true,
      );
      final picked = await service.createFolder(
        parentPath: parent,
        name: 'picked',
        managedRemote: true,
      );

      final first = await service.createWorkspace(
        path: picked,
        managedRemote: true,
      );
      expect(first['path'], picked);
      expect(first['name'], 'picked');
      final again = await service.createWorkspace(
        path: picked,
        managedRemote: true,
      );
      expect(again['id'], first['id']);
      final described = await service.describeWorkspaceById(
        first['id'] as String,
      );
      expect(described?['path'], picked);
      expect(described?['availability'], 'available');
    });

    test('allows a workspace nested inside another workspace', () async {
      final inner = await service.createFolder(
        parentPath: workspacePath,
        name: 'inner',
        managedRemote: true,
      );
      final nested = await service.createWorkspace(
        path: inner,
        managedRemote: true,
      );
      expect(nested['path'], inner);
      expect(nested['id'], isNot(workspaceId));
    });

    test('name-based create still creates a direct child', () async {
      final created = await service.createWorkspace(
        name: 'by-name',
        managedRemote: true,
      );
      expect(created['path'], p.join(root, 'by-name'));
    });

    test('relocates a workspace to another folder inside the root', () async {
      final target = await service.createFolder(
        parentPath: root,
        name: 'moved',
        managedRemote: true,
      );
      final preview = await service.previewRelocateWorkspace(
        workspaceId: workspaceId,
        newPath: target,
      );
      final relocated = await service.relocateWorkspace(
        workspaceId: workspaceId,
        newPath: target,
        managedRemote: true,
        expectedFingerprint: preview.fingerprint,
      );
      expect(relocated['path'], target);
    });
  });

  group('security rejections', () {
    test('S1 a NUL byte is a coded path_not_allowed', () async {
      await expectEveryRequest('$root/plain\u0000x', _pathNotAllowed);
    });

    test('S2 a raw .. segment is rejected even when it stays inside', () async {
      await expectEveryRequest('$root/plain/../plain', _pathNotAllowed);
      await expectEveryRequest('$root/plain/../../x', _pathNotAllowed);
    });

    test('S3 a relative path is rejected', () async {
      for (final relative in ['plain', 'a/b', '.']) {
        await expectEveryRequest(relative, _pathNotAllowed);
      }
    });

    test('S4 an absolute path outside the root is rejected', () async {
      final outside = Directory(p.join(tempDir.path, 'outside'))..createSync();
      await expectEveryRequest(outside.path, _pathNotAllowed);
      for (final path in <String>[
        Directory.systemTemp.path,
        ?Platform.environment['HOME'],
      ]) {
        await expectEveryRequest(path, _pathNotAllowed, hostPath: true);
      }
      expect(outside.existsSync(), isTrue);
    });

    test('S5 the filesystem root is rejected', () async {
      await expectEveryRequest(
        p.rootPrefix(root),
        _pathNotAllowed,
        hostPath: true,
      );
    });

    test('S5 a Windows drive root is rejected under Windows rules', () async {
      if (!Platform.isWindows) return;
      await expectEveryRequest(r'C:\', _pathNotAllowed, hostPath: true);
    });

    test(
      'S6 a registered workspace outside the root is not browsable',
      () async {
        final outside = Directory(p.join(tempDir.path, 'host-project'))
          ..createSync();
        final local = await service.createWorkspace(path: outside.path);
        final outsideId = local['id'] as String;

        await expectLater(
          service.browseWorkspaceTree(path: outside.path, managedRemote: true),
          _pathNotAllowed,
        );
        await expectLater(
          service.browseWorkspaceTree(
            workspaceId: outsideId,
            managedRemote: true,
          ),
          _pathNotAllowed,
        );
        await expectLater(
          service.createFolder(
            parentPath: outside.path,
            name: 'x',
            managedRemote: true,
          ),
          _pathNotAllowed,
        );
        expect(Directory(p.join(outside.path, 'x')).existsSync(), isFalse);
      },
    );

    test('S6 an inside workspace is browsable by workspace_id', () async {
      final snapshot = await service.browseWorkspaceTree(
        workspaceId: workspaceId,
        managedRemote: true,
      );
      expect(snapshot['path'], workspacePath);
    });

    test('S7 the Home, state home and Home files are rejected', () async {
      File(p.join(home, 'config.yaml')).writeAsStringSync('k: v');
      for (final path in [
        home,
        stateHome,
        p.join(home, 'config.yaml'),
        p.join(home, 'agent.db'),
      ]) {
        await expectEveryRequest(path, _pathNotAllowed);
      }
      expect(Directory(home).existsSync(), isTrue);
    });

    test('S8 a final-component symlink pointing outside is rejected', () async {
      if (Platform.isWindows) return;
      final outside = Directory(p.join(tempDir.path, 'outside'))..createSync();
      final link = Link(p.join(root, 'escape'))..createSync(outside.path);
      await expectEveryRequest(link.path, _pathNotAllowed);
      expect(outside.existsSync(), isTrue);
    });

    test(
      'S9 a path through a symlinked middle directory is rejected',
      () async {
        if (Platform.isWindows) return;
        final outside = Directory(p.join(tempDir.path, 'outside'))
          ..createSync();
        Directory(p.join(outside.path, 'inner')).createSync();
        Link(p.join(root, 'escape')).createSync(outside.path);
        await expectEveryRequest(
          p.join(root, 'escape', 'inner'),
          _pathNotAllowed,
        );
        expect(Directory(p.join(outside.path, 'inner')).existsSync(), isTrue);
      },
    );

    test('S10 a symlink to a folder inside the root is rejected', () async {
      if (Platform.isWindows) return;
      final link = Link(p.join(root, 'alias'))
        ..createSync(p.join(root, 'plain'));
      await expectEveryRequest(link.path, _pathNotAllowed);
      expect(Directory(p.join(root, 'plain')).existsSync(), isTrue);
    });

    test('S11 listings omit links and never disclose a target', () async {
      if (Platform.isWindows) return;
      final outside = Directory(p.join(tempDir.path, 'outside'))..createSync();
      File(p.join(outside.path, 'secret.txt')).writeAsStringSync('x');
      Link(p.join(root, 'escape')).createSync(outside.path);
      Link(
        p.join(root, 'secret-file'),
      ).createSync(p.join(outside.path, 'secret.txt'));
      Link(p.join(root, 'alias')).createSync(p.join(root, 'plain'));

      final snapshot = await service.browseWorkspaceTree(
        path: root,
        managedRemote: true,
      );
      final entries = (snapshot['entries'] as List)
          .cast<Map<String, dynamic>>();
      final names = entries.map((entry) => entry['name']).toSet();
      expect(names, isNot(contains('escape')));
      expect(names, isNot(contains('secret-file')));
      expect(names, isNot(contains('alias')));
      for (final entry in entries) {
        final path = entry['path'] as String;
        expect(p.isWithin(root, path), isTrue, reason: path);
        expect(path, isNot(contains(outside.path)));
      }
    });

    test('S12 picking the managed root itself is rejected', () async {
      await expectLater(
        service.createWorkspace(path: root, managedRemote: true),
        _pathNotAllowed,
      );
    });

    test('S13 renaming or deleting the managed root is rejected', () async {
      await expectLater(
        service.renameFolder(path: root, newName: 'x', managedRemote: true),
        _pathNotAllowed,
      );
      await expectLater(
        service.previewDeleteFolder(root, managedRemote: true),
        _pathNotAllowed,
      );
      await expectLater(
        service.deleteFolder(root, managedRemote: true),
        _pathNotAllowed,
      );
      expect(Directory(root).existsSync(), isTrue);
    });

    test('S14 a workspace root is workspace_in_use', () async {
      await expectLater(
        service.renameFolder(
          path: workspacePath,
          newName: 'x',
          managedRemote: true,
        ),
        _workspaceInUse,
      );
      await expectLater(
        service.previewDeleteFolder(workspacePath, managedRemote: true),
        _workspaceInUse,
      );
      await expectLater(
        service.deleteFolder(workspacePath, managedRemote: true),
        _workspaceInUse,
      );
      expect(Directory(workspacePath).existsSync(), isTrue);
    });

    test('S14 an ancestor of a workspace is workspace_in_use', () async {
      final parent = await service.createFolder(
        parentPath: root,
        name: 'parent',
        managedRemote: true,
      );
      final child = await service.createFolder(
        parentPath: parent,
        name: 'child',
        managedRemote: true,
      );
      await service.createWorkspace(path: child, managedRemote: true);

      await expectLater(
        service.renameFolder(path: parent, newName: 'x', managedRemote: true),
        _workspaceInUse,
      );
      await expectLater(
        service.previewDeleteFolder(parent, managedRemote: true),
        _workspaceInUse,
      );
      await expectLater(
        service.deleteFolder(parent, managedRemote: true),
        _workspaceInUse,
      );
      expect(Directory(child).existsSync(), isTrue);
    });

    test(
      'S15 invalid folder names are rejected on create and rename',
      () async {
        final target = await service.createFolder(
          parentPath: root,
          name: 'target',
          managedRemote: true,
        );
        for (final name in ['.', '..', 'a/b', r'a\b', '', 'a\u0000b']) {
          await expectLater(
            service.createFolder(
              parentPath: root,
              name: name,
              managedRemote: true,
            ),
            throwsA(isA<FormatException>()),
            reason: 'create $name',
          );
          await expectLater(
            service.renameFolder(
              path: target,
              newName: name,
              managedRemote: true,
            ),
            throwsA(isA<FormatException>()),
            reason: 'rename $name',
          );
        }
        expect(Directory(target).existsSync(), isTrue);
      },
    );

    test('S16 create_workspace needs exactly one of name or path', () async {
      await expectLater(
        service.createWorkspace(
          name: 'both',
          path: p.join(root, 'plain'),
          managedRemote: true,
        ),
        _invalidRequest,
      );
      await expectLater(
        service.createWorkspace(managedRemote: true),
        _invalidRequest,
      );
      await expectLater(
        service.createWorkspace(name: '  ', path: '', managedRemote: true),
        _invalidRequest,
      );
      expect(Directory(p.join(root, 'both')).existsSync(), isFalse);
    });

    test('S17 picking a file or a missing path registers nothing', () async {
      final file = File(p.join(root, 'notes.txt'))..writeAsStringSync('x');
      final before = (await service.listWorkspaces()).length;
      await expectLater(
        service.createWorkspace(path: file.path, managedRemote: true),
        _pathNotAllowed,
      );
      await expectLater(
        service.createWorkspace(
          path: p.join(root, 'missing'),
          managedRemote: true,
        ),
        throwsA(anything),
      );
      expect((await service.listWorkspaces()).length, before);
      expect(Directory(p.join(root, 'missing')).existsSync(), isFalse);
    });

    test('S18 a stale delete fingerprint is stale_confirmation', () async {
      final folder = await service.createFolder(
        parentPath: root,
        name: 'drafts',
        managedRemote: true,
      );
      final preview = await service.previewDeleteFolder(
        folder,
        managedRemote: true,
      );
      File(p.join(folder, 'new.txt')).writeAsStringSync('changed');
      await expectLater(
        service.deleteFolder(
          folder,
          managedRemote: true,
          expectedFingerprint: preview.fingerprint,
        ),
        _coded(WorkspaceCommandErrorCodes.staleConfirmation),
      );
      expect(Directory(folder).existsSync(), isTrue);
    });

    test(
      'S20 a folder swapped for a symlink after preview is refused',
      () async {
        if (Platform.isWindows) return;
        final folder = await service.createFolder(
          parentPath: root,
          name: 'drafts',
          managedRemote: true,
        );
        final preview = await service.previewDeleteFolder(
          folder,
          managedRemote: true,
        );
        final outside = Directory(p.join(tempDir.path, 'outside'))
          ..createSync();
        File(p.join(outside.path, 'keep.txt')).writeAsStringSync('keep');
        await Directory(folder).delete(recursive: true);
        Link(folder).createSync(outside.path);

        await expectLater(
          service.deleteFolder(
            folder,
            managedRemote: true,
            expectedFingerprint: preview.fingerprint,
          ),
          _pathNotAllowed,
        );
        await expectLater(
          service.renameFolder(path: folder, newName: 'x', managedRemote: true),
          _pathNotAllowed,
        );
        await expectLater(
          service.createWorkspace(path: folder, managedRemote: true),
          _pathNotAllowed,
        );
        expect(File(p.join(outside.path, 'keep.txt')).existsSync(), isTrue);
      },
    );
  });

  group('local mode is unchanged', () {
    test('local browse still reaches host folders outside the root', () async {
      final outside = Directory(p.join(tempDir.path, 'outside'))..createSync();
      final snapshot = await service.browseWorkspaceTree(path: outside.path);
      expect(snapshot['path'], outside.resolveSymbolicLinksSync());
    });

    test('local create accepts a host path', () async {
      final outside = Directory(p.join(tempDir.path, 'outside'))..createSync();
      final created = await service.createWorkspace(path: outside.path);
      expect(created['path'], outside.resolveSymbolicLinksSync());
    });
  });
}
