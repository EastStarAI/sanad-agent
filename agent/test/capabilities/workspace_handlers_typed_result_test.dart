import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_edit_handler.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_read_handler.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/file_write_handler.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/search_glob_handler.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/search_grep_handler.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:test/test.dart';

void main() {
  group('Workspace handler typed results', () {
    late Directory workspace;
    const resolver = WorkspacePathResolver();

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp(
        'workspace-handlers-typed-',
      );
    });

    tearDown(() async {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    });

    test('all migrated handlers emit text-only typed results', () async {
      const write = FileWriteHandler(resolver);
      const read = FileReadHandler(resolver);
      const edit = FileEditHandler(resolver);
      const glob = SearchGlobHandler(resolver);
      const grep = SearchGrepHandler(resolver);

      final results = <ToolExecutionResult>[
        await write.executeResult({
          'path': 'notes.txt',
          'content': 'hello workspace',
        }, workspace.path),
        await read.executeResult({'path': 'notes.txt'}, workspace.path),
        await edit.executeResult({
          'path': 'notes.txt',
          'old_string': 'workspace',
          'new_string': 'Sanad',
        }, workspace.path),
        await glob.executeResult({'pattern': '*.txt'}, workspace.path),
        await grep.executeResult({'pattern': 'Sanad'}, workspace.path),
      ];

      for (final result in results) {
        expect(result.isError, isFalse);
        expect(result.blocks, hasLength(1));
        expect(result.blocks.single, isA<ToolTextBlock>());
        expect(() => jsonDecode(result.displayText), returnsNormally);
      }
    });

    test(
      'legacy execute projects the authoritative typed read result',
      () async {
        const handler = FileReadHandler(resolver);
        await File('${workspace.path}/notes.txt').writeAsString('same text');

        final typed = await handler.executeResult({
          'path': 'notes.txt',
        }, workspace.path);
        final legacy = await handler.execute({
          'path': 'notes.txt',
        }, workspace.path);

        expect(legacy, typed.displayText);
      },
    );
  });
}
