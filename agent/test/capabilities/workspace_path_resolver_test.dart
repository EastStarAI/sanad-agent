import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:test/test.dart';

void main() {
  group('WorkspacePathResolver external authorization', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late Directory externalDir;
    const resolver = WorkspacePathResolver();

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('workspace-path-test-');
      workspaceDir = Directory(p.join(tempDir.path, 'workspace'))
        ..createSync(recursive: true);
      externalDir = Directory(p.join(tempDir.path, 'external'))
        ..createSync(recursive: true);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('classifies traversal and absolute paths after canonicalization', () {
      final externalFile = File(p.join(externalDir.path, 'outside.txt'))
        ..writeAsStringSync('outside');
      final traversed = resolver.classifyExistingPath(
        workspaceRoot: workspaceDir.path,
        inputPath: p.join('..', 'external', 'outside.txt'),
      );
      final absolute = resolver.classifyExistingPath(
        workspaceRoot: workspaceDir.path,
        inputPath: externalFile.path,
      );

      expect(traversed.isExternal, isTrue);
      expect(traversed.resolvedPath, externalFile.resolveSymbolicLinksSync());
      expect(absolute.resolvedPath, traversed.resolvedPath);
      expect(
        () => resolver.resolveExistingPath(
          workspaceRoot: workspaceDir.path,
          inputPath: externalFile.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('allows only the authorized external root and its descendants', () {
      final child = File(p.join(externalDir.path, 'child.txt'))
        ..writeAsStringSync('child');
      final sibling = File(p.join(tempDir.path, 'sibling.txt'))
        ..writeAsStringSync('sibling');

      expect(
        resolver.resolveExistingPath(
          workspaceRoot: workspaceDir.path,
          inputPath: child.path,
          authorizedExternalRoot: externalDir.path,
        ),
        child.resolveSymbolicLinksSync(),
      );
      expect(
        () => resolver.resolveExistingPath(
          workspaceRoot: workspaceDir.path,
          inputPath: sibling.path,
          authorizedExternalRoot: externalDir.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('classifies a workspace symlink by its external target', () {
      final target = File(p.join(externalDir.path, 'target.txt'))
        ..writeAsStringSync('target');
      final link = Link(p.join(workspaceDir.path, 'linked.txt'))
        ..createSync(target.path);

      final resolution = resolver.classifyExistingPath(
        workspaceRoot: workspaceDir.path,
        inputPath: link.path,
      );

      expect(resolution.isExternal, isTrue);
      expect(resolution.resolvedPath, target.resolveSymbolicLinksSync());
    });

    test(
      'canonicalizes an external missing write target through its ancestor',
      () {
        final target = p.join(externalDir.path, 'nested', 'new.txt');
        final resolution = resolver.classifyPathAllowMissing(
          workspaceRoot: workspaceDir.path,
          inputPath: target,
        );

        expect(resolution.isExternal, isTrue);
        expect(
          resolution.resolvedPath,
          p.join(externalDir.resolveSymbolicLinksSync(), 'nested', 'new.txt'),
        );
        expect(
          resolver.resolvePathAllowMissing(
            workspaceRoot: workspaceDir.path,
            inputPath: target,
            authorizedExternalRoot: resolution.resolvedPath,
          ),
          resolution.resolvedPath,
        );
      },
    );
  });
}
