import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

void main() {
  test('malformed Ollama capability evidence stays unknown', () {
    for (final value in [
      <Object?>[42],
      <Object?>[null],
      <Object?>['vision', 42],
      <Object?>[' '],
    ]) {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'ollama_capabilities': value,
        }),
        isNull,
        reason: 'Malformed lists cannot establish either image-support state.',
      );
    }
  });

  test(
    'generic non-image capability list does not veto explicit modalities',
    () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'capabilities': ['tools'],
          'input_modalities': ['text', 'image'],
        }),
        isTrue,
      );
    },
  );

  for (final stream in [false, true]) {
    test(
      'incomplete image tool batch blocks lossy ${stream ? 'stream' : 'sync'} HTTP',
      () async {
        var requests = 0;
        final adapter = OllamaAdapter(
          Config(environment: const {}),
          ProviderRegistry.findByNameOrAlias('ollama')!,
          client: MockClient((request) async {
            requests++;
            return http.Response(
              jsonEncode({
                'message': {'content': 'text only'},
                'done': true,
              }),
              200,
            );
          }),
        );
        final result = ToolExecutionResult(
          blocks: [
            ToolTextBlock(text: 'Image loaded'),
            ToolImageBlock(
              dataBase64: base64Encode([137, 80, 78, 71, 13, 10, 26, 10]),
              mimeType: 'image/png',
              width: 1,
              height: 1,
              detail: ToolImageDetail.original,
            ),
          ],
        );
        final history = [
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'one', name: 'view_image', arguments: const {}),
              ToolCall(id: 'two', name: 'other_tool', arguments: const {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'one',
            content: result.displayText,
            toolResult: result,
          ),
        ];
        final before = jsonEncode(
          history.map((message) => message.toJson()).toList(),
        );
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'isolated-review',
            modelId: 'isolated-vision-model',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'test',
          ),
        );
        await expectLater(
          stream
              ? adapter.generateStream(history, options: options).toList()
              : adapter.generateResponse(history, options: options),
          throwsA(isA<FormatException>()),
        );
        expect(requests, 0);
        expect(
          jsonEncode(history.map((message) => message.toJson()).toList()),
          before,
        );
      },
    );
  }
}
