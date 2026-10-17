import 'dart:convert';

import '../models/tool_schema.dart';
import '../../core/models/tool_execution_result.dart';
import '../../evolution/memory/file_memory_store.dart';
import 'base_tool.dart';

class MemoryTool extends BaseTool {
  MemoryTool({required FileMemoryStore store}) : _store = store;

  final FileMemoryStore _store;

  static const String memoryGuidance =
      'You have persistent memory across sessions. Save durable declarative facts with the memory tool: '
      'user preferences, recurring corrections, environment details, tool quirks, and stable project conventions. '
      'Prioritize facts that prevent the user from having to repeat guidance. Write facts, not instructions to yourself. '
      'Memory is injected into future turns, so keep it compact and useful later. '
      'Do not save task progress, completed-work logs, temporary TODO state, PR/issue numbers, or facts likely to go stale soon. '
      'Reusable procedures belong in skills and past session details belong in session search. '
      'Use target="user" for user profile facts and target="memory" for durable environment/project notes.';

  @override
  ToolSchema get schema => ToolSchema(
    name: 'memory',
    description:
        'Save durable facts to persistent file-backed memory. Prefer one operations batch when consolidating or making multiple changes; the batch is atomic and checked against final capacity. '
        'Use target="user" for user identity/preferences and target="memory" for durable environment/project notes. '
        'Use a single action for one add, replace, remove, or explicit read.',
    parameters: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['add', 'replace', 'remove', 'read'],
          'description': 'Single-operation action. Omit when using operations.',
        },
        'target': {
          'type': 'string',
          'enum': ['memory', 'user'],
          'description': 'Which file-backed memory store to use.',
        },
        'content': {
          'type': 'string',
          'description':
              'Entry content for a single add or replacement content for replace.',
        },
        'old_text': {
          'type': 'string',
          'description':
              'Short unique substring identifying the entry for a single replace or remove.',
        },
        'operations': {
          'type': 'array',
          'description':
              'Atomic add/replace/remove operations applied to one target and checked against final capacity.',
          'items': {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['add', 'replace', 'remove'],
              },
              'content': {
                'type': 'string',
                'description': 'Content for add or replace.',
              },
              'old_text': {
                'type': 'string',
                'description': 'Unique substring for replace or remove.',
              },
            },
            'required': ['action'],
          },
        },
      },
      'required': ['target'],
    },
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => jsonEncode(await _executePayload(args));

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final payload = await _executePayload(args);
    final isError = payload['success'] != true;
    return ToolExecutionResult.text(
      jsonEncode(payload),
      isError: isError,
      errorCode: isError ? ToolResultErrorCode.invalidInput : null,
    );
  }

  Future<Map<String, dynamic>> _executePayload(
    Map<String, dynamic> args,
  ) async {
    final action = args['action']?.toString().trim();
    final target = args['target']?.toString().trim() ?? 'memory';
    final content = args['content']?.toString().trim();
    final oldText = args['old_text']?.toString().trim() ?? '';

    if (target != 'memory' && target != 'user') {
      return {'success': false, 'error': "target must be 'memory' or 'user'."};
    }

    final rawOperations = args['operations'];
    if (rawOperations != null) {
      if (rawOperations is! List || rawOperations.isEmpty) {
        return {
          'success': false,
          'error': 'operations must be a non-empty array.',
        };
      }
      final operations = <Map<String, dynamic>>[];
      for (final operation in rawOperations) {
        if (operation is! Map) {
          return {
            'success': false,
            'error': 'Every operation must be an object.',
          };
        }
        try {
          operations.add(Map<String, dynamic>.from(operation));
        } on TypeError {
          return {
            'success': false,
            'error': 'Every operation key must be a string.',
          };
        }
      }
      return _store.applyBatch(target, operations);
    }

    if (action == null || action.isEmpty) {
      return {
        'success': false,
        'error': 'action is required when operations is not provided.',
      };
    }

    Map<String, dynamic> result;
    switch (action) {
      case 'add':
        result = content == null || content.isEmpty
            ? {'success': false, 'error': 'content is required for add.'}
            : _store.add(target, content);
        break;
      case 'replace':
        result = content == null || content.isEmpty
            ? {'success': false, 'error': 'content is required for replace.'}
            : _store.replace(target, oldText, content);
        break;
      case 'remove':
        result = _store.remove(target, oldText);
        break;
      case 'read':
        result = _store.read(target);
        break;
      default:
        result = {
          'success': false,
          'error':
              "Unknown action '$action'. Use add, replace, remove, read, or operations.",
        };
        break;
    }

    return result;
  }
}
