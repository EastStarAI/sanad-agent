import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/capabilities/image/image_policy.dart';
import 'package:sanad_agent/capabilities/image/image_worker.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/view_image_handler.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:test/test.dart';

final class _FakeImageWorker extends ImageWorker {
  _FakeImageWorker({this.failure});

  final ImagePolicyFailure? failure;

  @override
  Future<ImagePolicyResult> process(
    Uint8List bytes, {
    required ToolImageDetail detail,
  }) async =>
      failure ??
      ImagePolicySuccess(
        bytes: Uint8List.fromList([0xff, 0xd8, 0xff, 0xd9]),
        mimeType: 'image/jpeg',
        width: 4,
        height: 2,
      );
}

void main() {
  group('ViewImageHandler', () {
    late Directory root;
    late Directory workspace;
    late Directory external;
    late File internalImage;
    late File externalImage;
    late int reads;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('view-image-handler-test');
      workspace = Directory('${root.path}/workspace')..createSync();
      external = Directory('${root.path}/external')..createSync();
      internalImage = File('${workspace.path}/inside.bin')
        ..writeAsBytesSync([1, 2, 3]);
      externalImage = File('${external.path}/outside.bin')
        ..writeAsBytesSync([4, 5, 6]);
      reads = 0;
    });

    tearDown(() => root.delete(recursive: true));

    ViewImageHandler handler({_FakeImageWorker? worker}) => ViewImageHandler(
      const WorkspacePathResolver(),
      imageWorker: worker ?? _FakeImageWorker(),
      readBytes: (path) async {
        reads++;
        return File(path).readAsBytes();
      },
    );

    test(
      'returns safe text then truthful image for an internal path',
      () async {
        var approvalCalled = false;
        final result = await handler().executeResult(
          {'path': 'inside.bin'},
          workspacePath: workspace.path,
          admittedAttachmentPaths: const [],
          authorizeExternal: (path, arguments, context) async {
            approvalCalled = true;
          },
        );

        expect(result.isError, isFalse);
        expect(result.blocks, [isA<ToolTextBlock>(), isA<ToolImageBlock>()]);
        expect(result.displayText, contains('4×2'));
        expect(result.displayText, isNot(contains(workspace.path)));
        expect(approvalCalled, isFalse);
        expect(reads, 1);
      },
    );

    test(
      'authorizes the canonical external target before reading bytes',
      () async {
        var authorizedPath = '';
        final result = await handler().executeResult(
          {'path': externalImage.path, 'detail': 'high'},
          workspacePath: workspace.path,
          admittedAttachmentPaths: const [],
          authorizeExternal: (path, arguments, context) async {
            expect(reads, 0);
            authorizedPath = path;
          },
        );

        expect(result.isError, isFalse);
        expect(authorizedPath, externalImage.resolveSymbolicLinksSync());
        expect(reads, 1);
      },
    );

    test('denial and symlink escape fail before byte read', () async {
      final link = Link('${workspace.path}/linked-image')
        ..createSync(externalImage.path);
      var approvalPath = '';
      final result = await handler().executeResult(
        {'path': link.path},
        workspacePath: workspace.path,
        admittedAttachmentPaths: const [],
        authorizeExternal: (path, arguments, context) async {
          approvalPath = path;
          throw Exception('denied');
        },
      );

      expect(approvalPath, externalImage.resolveSymbolicLinksSync());
      expect(result.isError, isTrue);
      expect(result.errorCode, ToolResultErrorCode.permissionDenied);
      expect(result.blocks, everyElement(isA<ToolTextBlock>()));
      expect(reads, 0);
    });

    test(
      'attachment-only scope allows exactly the canonical granted file',
      () async {
        final granted = await handler().executeResult(
          {'path': externalImage.path},
          workspacePath: null,
          admittedAttachmentPaths: [externalImage.path],
          authorizeExternal: (path, arguments, context) async =>
              fail('attachment grants must not request workspace approval'),
        );
        expect(granted.isError, isFalse);
        expect(reads, 1);

        reads = 0;
        final sibling = File('${external.path}/sibling.bin')
          ..writeAsBytesSync([7, 8, 9]);
        final denied = await handler().executeResult(
          {'path': sibling.path},
          workspacePath: null,
          admittedAttachmentPaths: [externalImage.path],
          authorizeExternal: (path, arguments, context) async {},
        );
        expect(denied.errorCode, ToolResultErrorCode.permissionDenied);
        expect(reads, 0);
      },
    );

    test(
      'rejects remote, invalid detail, directory, and worker failures',
      () async {
        for (final arguments in [
          {'path': 'https://example.test/image.png'},
          {'path': internalImage.path, 'detail': 'maximum'},
        ]) {
          final result = await handler().executeResult(
            arguments,
            workspacePath: workspace.path,
            admittedAttachmentPaths: const [],
            authorizeExternal: (path, arguments, context) async {},
          );
          expect(result.errorCode, ToolResultErrorCode.invalidInput);
        }

        final directoryResult = await handler().executeResult(
          {'path': workspace.path},
          workspacePath: workspace.path,
          admittedAttachmentPaths: const [],
          authorizeExternal: (path, arguments, context) async {},
        );
        expect(directoryResult.errorCode, ToolResultErrorCode.invalidInput);

        final failed =
            await handler(
              worker: _FakeImageWorker(
                failure: const ImagePolicyFailure(
                  code: ToolResultErrorCode.unsupportedFormat,
                  message: 'Unsupported image.',
                ),
              ),
            ).executeResult(
              {'path': internalImage.path},
              workspacePath: workspace.path,
              admittedAttachmentPaths: const [],
              authorizeExternal: (path, arguments, context) async {},
            );
        expect(failed.errorCode, ToolResultErrorCode.unsupportedFormat);
        expect(failed.blocks, everyElement(isA<ToolTextBlock>()));
      },
    );
  });
}
