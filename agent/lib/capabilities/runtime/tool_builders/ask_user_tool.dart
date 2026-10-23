import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';

import '../interactive_user_input.dart';

/// `system_ask_user` builder for `LocalRuntimeCatalog`.
///
/// The suspension checkpoint is the host's one `InteractiveUserInput` owner, so
/// the builder receives it instead of constructing a second checkpoint path.
BaseTool buildAskUserTool({required InteractiveUserInput userInput}) {
  return CallbackTool(
    toolSpec: const LocalToolSpec(
      name: 'system_ask_user',
      displayName: 'Ask Clarifying Questions',
      description:
          'Ask the user one or more clarifying questions (up to 5) to resolve design ambiguity, missing details, or decision-making. Halts session execution until the user responds. Each question must have exactly 3 options.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'questions': {
            'type': 'array',
            'minItems': 1,
            'maxItems': 5,
            'items': {
              'type': 'object',
              'properties': {
                'question': {
                  'type': 'string',
                  'description': 'The clarifying question text.',
                },
                'options': {
                  'type': 'array',
                  'minItems': 3,
                  'maxItems': 3,
                  'items': {'type': 'string'},
                  'description':
                      'Exactly 3 predefined options for the user to choose from.',
                },
              },
              'required': ['question', 'options'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['questions'],
        'additionalProperties': false,
      },
      source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
      category: 'system',
      workspaceRequired: false,
      approval: {'mode': 'default', 'sensitive': false},
      execution: {'target': 'local_runtime', 'timeout_ms': 3600000},
      serverName: 'system',
    ),
    onExecute: (args, {context}) async {
      final rawQuestions = args['questions'];
      final List<Map<String, dynamic>> questionsList = [];

      if (rawQuestions is List) {
        for (final q in rawQuestions) {
          if (q is Map) {
            questionsList.add({
              'question': q['question']?.toString() ?? '',
              'options': List<String>.from(
                (q['options'] as List? ?? []).map((o) => o.toString()),
              ),
            });
          }
        }
      } else {
        // Backward compatibility for single 'question' parameter
        final singleQuestion =
            args['question']?.toString() ??
            args['questions']?.toString() ??
            '';
        if (singleQuestion.isNotEmpty) {
          questionsList.add({
            'question': singleQuestion,
            'options': <String>[],
          });
        }
      }

      final decision = await userInput.request(
        toolName: 'system_ask_user',
        checkpointPrefix: 'ask',
        context: context,
        args: args,
        fields: {'questions': questionsList},
      );
      final answer = decision['answer']?.toString().trim();
      if (answer == null || answer.isEmpty) {
        throw Exception(
          'User clarification question was resolved without an answer.',
        );
      }
      return answer;
    },
  );
}
