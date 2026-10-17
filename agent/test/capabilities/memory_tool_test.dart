import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/capabilities/tools/memory_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/memory/file_memory_store.dart';

void main() {
  group('MemoryTool', () {
    late Directory tempDir;
    late FileMemoryStore store;
    late MemoryTool tool;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('memory-tool-test');
      setSanadHomeOverride(tempDir.path);
      setSanadStateHomeOverride(tempDir.path);
      store = FileMemoryStore()..loadFromDisk();
      tool = MemoryTool(store: store);
    });

    tearDown(() {
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('schema supports strict-provider-safe single and batch shapes', () {
      final parameters = tool.schema.parameters;
      expect(parameters['type'], 'object');
      expect(parameters['required'], ['target']);
      expect(parameters, isNot(contains('oneOf')));
      expect(parameters, isNot(contains('anyOf')));
      expect(parameters, isNot(contains('allOf')));

      final properties = parameters['properties'] as Map<String, dynamic>;
      expect(properties['operations']['type'], 'array');
      expect(
        properties['operations']['items']['properties']['action']['enum'],
        ['add', 'replace', 'remove'],
      );
    });

    test(
      'add returns compact result while explicit read returns entries',
      () async {
        final addPayload =
            jsonDecode(
                  await tool.execute({
                    'action': 'add',
                    'target': 'memory',
                    'content': 'Project uses fvm for Dart commands.',
                  }),
                )
                as Map<String, dynamic>;

        expect(addPayload['success'], isTrue);
        expect(addPayload['done'], isTrue);
        expect(addPayload, isNot(contains('entries')));
        expect(addPayload, isNot(contains('path')));

        final readPayload =
            jsonDecode(
                  await tool.execute({'action': 'read', 'target': 'memory'}),
                )
                as Map<String, dynamic>;
        expect(
          readPayload['entries'],
          contains('Project uses fvm for Dart commands.'),
        );
        expect(readPayload, isNot(contains('path')));
      },
    );

    test('missing old_text returns inventory for a corrected retry', () async {
      await tool.execute({
        'action': 'add',
        'target': 'memory',
        'content': 'Project uses Dart.',
      });

      final payload =
          jsonDecode(
                await tool.execute({
                  'action': 'replace',
                  'target': 'memory',
                  'content': 'Project uses Dart 3.',
                }),
              )
              as Map<String, dynamic>;

      expect(payload['success'], isFalse);
      expect(payload['current_entries'], ['Project uses Dart.']);
      expect(payload['error'], contains('old_text'));
    });

    test('operations apply atomically without requiring action', () async {
      await tool.execute({
        'action': 'add',
        'target': 'user',
        'content': 'User prefers verbose answers.',
      });

      final payload =
          jsonDecode(
                await tool.execute({
                  'target': 'user',
                  'operations': [
                    {
                      'action': 'replace',
                      'old_text': 'verbose',
                      'content': 'User prefers concise answers.',
                    },
                    {
                      'action': 'add',
                      'content': 'User prefers Arabic responses.',
                    },
                  ],
                }),
              )
              as Map<String, dynamic>;

      expect(payload['success'], isTrue);
      expect(payload['done'], isTrue);
      expect(payload, isNot(contains('entries')));
      expect(store.read('user')['entries'], [
        'User prefers concise answers.',
        'User prefers Arabic responses.',
      ]);
    });

    test('invalid batch leaves the original store unchanged', () async {
      await tool.execute({
        'action': 'add',
        'target': 'memory',
        'content': 'Keep this.',
      });

      final payload =
          jsonDecode(
                await tool.execute({
                  'target': 'memory',
                  'operations': [
                    {'action': 'add', 'content': 'Do not persist.'},
                    {'action': 'remove', 'old_text': 'missing'},
                  ],
                }),
              )
              as Map<String, dynamic>;

      expect(payload['success'], isFalse);
      expect(store.read('memory')['entries'], ['Keep this.']);
    });

    test('rejects malformed operations before store execution', () async {
      final empty =
          jsonDecode(await tool.execute({'target': 'memory', 'operations': []}))
              as Map<String, dynamic>;
      final nonObject =
          jsonDecode(
                await tool.execute({
                  'target': 'memory',
                  'operations': ['bad'],
                }),
              )
              as Map<String, dynamic>;

      final nonStringKey =
          jsonDecode(
                await tool.execute({
                  'target': 'memory',
                  'operations': [
                    {1: 'bad'},
                  ],
                }),
              )
              as Map<String, dynamic>;

      expect(empty['success'], isFalse);
      expect(nonObject['success'], isFalse);
      expect(nonStringKey['success'], isFalse);
    });

    test('typed success and error preserve legacy JSON projections', () async {
      final typedRead = await tool.executeResult({
        'action': 'read',
        'target': 'memory',
      });
      final legacyRead = await tool.execute({
        'action': 'read',
        'target': 'memory',
      });
      expect(typedRead.displayText, legacyRead);
      expect(typedRead.isError, isFalse);

      final typedError = await tool.executeResult({'target': 'invalid'});
      final legacyError = await tool.execute({'target': 'invalid'});
      expect(typedError.displayText, legacyError);
      expect(typedError.isError, isTrue);
      expect(typedError.errorCode, ToolResultErrorCode.invalidInput);
    });
  });
}
